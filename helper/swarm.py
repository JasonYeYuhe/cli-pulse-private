"""
Swarm tagging — S1 (v1.22 P0 "Mission Control for the agent swarm").

Derives a stable, privacy-preserving `swarm_key` for the git worktree an
AI-coding-agent hook fired from, and maintains a small local
edge-aggregation state store that S1b's heartbeat rolls up.

Design constraints baked in from the Gemini 2-round review
(see PLAN_v1.22 §7/§8):

* **R1-A1 / Q1 — repo-root alone is wrong** (monorepo collapse). The
  grouping identity is the *canonical main repo* (`git-common-dir`
  parent, so every linked worktree of one repo groups into one swarm)
  combined with the per-worktree `branch` (the per-agent dimension).
  Repo-root-only is explicitly rejected.

* **R1-A3 / R2-1 / RK7 — P0 must not leak repo/branch names.** The only
  cross-device value uploaded is `HMAC(main_repo + branch,
  account_secret)`. The HMAC secret is the **account-scoped**
  `config.helper_secret` (identical across every device on one account
  — verified by the Explore of helper auth), so the same repo+branch
  produces the same key on every machine the user runs (R2-1
  cross-device grouping). No plaintext path/branch is ever uploaded.

* **R2-1 documented v1.22.0 fallback** — account-envelope label
  encryption (`encrypt_label`/`decrypt_label` below) is implemented and
  unit-tested as the v1.22.1-ready primitive, but v1.22.0 deliberately
  uploads ONLY the opaque key + a derived non-identifying
  `display_handle` (`swarm-3f9a1c`). The local Mac, which holds the
  secret AND sees the plaintext cwd, can show the real name from its
  own cache; the phone shows the stable handle. This is the exact
  fallback the plan signed off on — zero new crypto deps on the
  PyInstaller helper for the launch train.

* **RK1 — never crash a session over swarm tagging.** Every public
  function is failure-soft: bad cwd / non-git / detached HEAD / git
  missing / timeout / unreadable state file all degrade to "no swarm
  tag", logged at WARNING, never raised.

stdlib-only (the helper ships as a PyInstaller bundle; no `cryptography`
dependency — see feedback_v116_helper_pkg_shipped).
"""

from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import subprocess
import tempfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

logger = logging.getLogger(__name__)

# Domain-separation tag — bump if the key derivation ever changes so old
# and new keys can't silently collide across a helper upgrade.
_KEY_SCHEME = "clipulse-swarm-v1"

_DETACHED_BRANCH = "(detached)"

_STATE_DIR = Path.home() / ".cli_pulse"
_STATE_PATH = _STATE_DIR / "swarm_state.json"
# Bound the on-disk state so a long-lived helper that has seen thousands
# of worktrees over weeks can't grow unboundedly. Oldest-by-last-seen
# entries are pruned first.
_MAX_SWARMS = 64
_MAX_SESSIONS_PER_SWARM = 32
# Activity older than this is dead for rollup purposes. The backend has
# its own 90s heartbeat TTL (RK8); this local prune is intentionally
# looser so a swarm that goes quiet for a few minutes still reports
# (the agent may just be thinking) but truly stale rows are dropped.
_ACTIVITY_TTL_S = 600.0

_GIT_TIMEOUT_S = 2.0


# ── worktree resolution ─────────────────────────────────────


@dataclass(frozen=True)
class WorktreeInfo:
    """Resolved git identity for a hook's working directory.

    `main_repo` is the canonical repo (shared `.git` parent) so all
    linked worktrees group together; `branch` is the per-worktree /
    per-agent dimension. `is_linked_worktree` is True when the cwd is a
    `git worktree add`-ed sibling rather than the primary checkout.
    """

    main_repo: str
    branch: str
    is_linked_worktree: bool


def resolve_worktree(cwd: str, *, timeout: float = _GIT_TIMEOUT_S) -> WorktreeInfo | None:
    """Resolve `cwd` to its canonical repo + branch, or None.

    Returns None (never raises) for: empty cwd, path missing, not a git
    repo, git binary absent, timeout, or any OSError — caller treats
    None as "this event gets no swarm tag" (RK1).
    """
    if not cwd:
        return None
    try:
        if not os.path.isdir(cwd):
            return None
    except OSError:
        return None

    try:
        # One round-trip. `rev-parse` prints the requested values in
        # order, one per line:
        #   1) --git-common-dir   → the SHARED .git dir; its parent is
        #      the canonical main repo, identical for every linked
        #      worktree of that repo (this is what makes siblings group).
        #   2) --abbrev-ref HEAD  → branch, or literally "HEAD" when
        #      detached.
        #   3) --is-inside-work-tree (sanity; "true"/"false")
        proc = subprocess.run(
            [
                "git", "-C", cwd, "rev-parse",
                "--path-format=absolute",
                "--git-common-dir",
                "--abbrev-ref", "HEAD",
                "--is-inside-work-tree",
            ],
            capture_output=True, text=True, timeout=timeout,
        )
    except FileNotFoundError:
        logger.warning("swarm: git not found; skipping swarm tag for %s", _short(cwd))
        return None
    except subprocess.TimeoutExpired:
        logger.warning("swarm: git rev-parse timed out for %s", _short(cwd))
        return None
    except OSError as exc:
        logger.warning("swarm: git rev-parse failed for %s: %s", _short(cwd), exc)
        return None

    if proc.returncode != 0:
        # Not a git work tree (bare repo, plain dir, $GIT_DIR weirdness,
        # devcontainer mount miss). Soft-skip.
        return None

    lines = [ln.strip() for ln in proc.stdout.splitlines() if ln.strip()]
    if len(lines) < 3:
        return None
    common_dir, branch_raw, inside = lines[0], lines[1], lines[2].lower()
    if inside != "true":
        return None

    # `--git-common-dir` is `<main>/.git` for the primary checkout and
    # for linked worktrees alike (linked worktrees resolve it to the
    # main repo's .git, NOT their own .git/worktrees/<name>). The
    # canonical main-repo identity is that .git's parent dir.
    common_path = Path(common_dir)
    if common_path.name == ".git":
        main_repo = str(common_path.parent)
    else:
        # Bare repo or unusual layout: use the common dir itself as the
        # stable identity rather than guessing a parent.
        main_repo = str(common_path)

    branch = branch_raw if branch_raw and branch_raw != "HEAD" else _DETACHED_BRANCH

    # Detect a linked worktree: its own --git-dir differs from the
    # common dir. Best-effort; failure just means is_linked_worktree
    # stays False (it's display-only metadata, never part of the key).
    is_linked = False
    try:
        gd = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-dir"],
            capture_output=True, text=True, timeout=timeout,
        )
        if gd.returncode == 0:
            git_dir = gd.stdout.strip()
            is_linked = bool(git_dir) and os.path.normpath(git_dir) != os.path.normpath(common_dir)
    except (OSError, subprocess.SubprocessError):
        pass

    return WorktreeInfo(main_repo=main_repo, branch=branch, is_linked_worktree=is_linked)


def _short(path: str) -> str:
    """A non-identifying tag for logs — never log the full project path."""
    try:
        return f"<{len(path)}-char path>"
    except Exception:  # noqa: BLE001
        return "<path>"


# ── key derivation (account-scoped, no plaintext leaves device) ──


def compute_swarm_key(main_repo: str, branch: str, account_secret: str) -> str:
    """HMAC-SHA256(account_secret, scheme | main_repo | branch) hex.

    Account-scoped secret ⇒ stable & identical across the user's
    machines for the same repo+branch (R2-1). Domain-separated by
    `_KEY_SCHEME`. NUL-joined so `("a","bc")` ≠ `("ab","c")`.
    """
    if not account_secret:
        # No paired account → cannot make a cross-device-stable key.
        # Caller treats "" as "no swarm tag" (fail-soft, not a crash).
        return ""
    msg = "\0".join((_KEY_SCHEME, main_repo, branch)).encode("utf-8")
    return hmac.new(account_secret.encode("utf-8"), msg, hashlib.sha256).hexdigest()


def display_handle(swarm_key: str) -> str:
    """Stable, non-identifying handle for cross-device UI in v1.22.0.

    `swarm-<first 6 hex of the key>`. Leaks nothing about the repo or
    branch; the local Mac resolves the real name from its own cache.
    """
    if not swarm_key:
        return "swarm-?"
    return f"swarm-{swarm_key[:6]}"


# ── account-envelope label crypto (v1.22.1-ready; NOT wired in 1.22.0) ──
#
# Encrypt-then-MAC over an HMAC-SHA256 keystream. stdlib-only authenticated
# encryption keyed by the account secret, so only the user's own clients
# (which hold the same account secret) can recover the plaintext repo/
# branch label. v1.22.0 does NOT upload encrypted labels (R2-1 fallback);
# this is implemented + tested now so v1.22.1 can enable cross-device
# real-name sync by flipping one config flag, with the crypto already
# reviewed.


def _derive(account_secret: str, salt: bytes, info: bytes, n: int) -> bytes:
    """HKDF-Expand-style stream from the account secret (stdlib)."""
    prk = hmac.new(b"clipulse-swarm-hkdf", account_secret.encode("utf-8") + salt,
                    hashlib.sha256).digest()
    out = b""
    counter = 1
    while len(out) < n:
        out += hmac.new(prk, info + counter.to_bytes(2, "big"), hashlib.sha256).digest()
        counter += 1
    return out[:n]


def encrypt_label(plaintext: str, account_secret: str) -> str:
    """Authenticated envelope: `v1.<salt>.<ct>.<tag>` (all urlsafe-b64).

    Not used by any v1.22.0 upload path — see module docstring / R2-1.
    """
    import base64
    import secrets as _secrets

    if not account_secret:
        raise ValueError("encrypt_label requires a paired account secret")
    pt = plaintext.encode("utf-8")
    salt = _secrets.token_bytes(16)
    keystream = _derive(account_secret, salt, b"enc", len(pt))
    ct = bytes(a ^ b for a, b in zip(pt, keystream))
    mac_key = _derive(account_secret, salt, b"mac", 32)
    tag = hmac.new(mac_key, salt + ct, hashlib.sha256).digest()
    b = lambda x: base64.urlsafe_b64encode(x).decode("ascii").rstrip("=")  # noqa: E731
    return f"v1.{b(salt)}.{b(ct)}.{b(tag)}"


def decrypt_label(envelope: str, account_secret: str) -> str | None:
    """Inverse of `encrypt_label`. Returns None on any tamper/format error."""
    import base64

    try:
        ver, s_b, c_b, t_b = envelope.split(".")
        if ver != "v1" or not account_secret:
            return None

        def _ub(x: str) -> bytes:
            return base64.urlsafe_b64decode(x + "=" * (-len(x) % 4))

        salt, ct, tag = _ub(s_b), _ub(c_b), _ub(t_b)
        mac_key = _derive(account_secret, salt, b"mac", 32)
        expect = hmac.new(mac_key, salt + ct, hashlib.sha256).digest()
        if not hmac.compare_digest(expect, tag):
            return None
        keystream = _derive(account_secret, salt, b"enc", len(ct))
        return bytes(a ^ b for a, b in zip(ct, keystream)).decode("utf-8")
    except (ValueError, TypeError):
        return None


# ── local edge-aggregation state store (S1 writes, S1b reads) ──


@dataclass
class _SwarmState:
    handle: str
    branch: str
    is_linked_worktree: bool = False
    providers: list[str] = field(default_factory=list)
    # session_id -> {"status": str, "last_seen": float}
    sessions: dict[str, dict[str, Any]] = field(default_factory=dict)
    last_seen: float = 0.0


class SwarmStore:
    """Tiny JSON-backed store of currently-active swarms.

    S1's hook path calls `record_activity` on every hook ingress; S1b's
    heartbeat calls `rollup` every ~30s. Atomic tmp+rename writes, 0600,
    bounded. Every method is failure-soft (a corrupt/locked state file
    must never break the approval hook — RK1).
    """

    def __init__(self, path: Path = _STATE_PATH, *, now: Any = time.time) -> None:
        self._path = path
        self._now = now

    # -- load / save (defensive) --

    def _load(self) -> dict[str, _SwarmState]:
        try:
            raw = json.loads(self._path.read_text("utf-8"))
        except (OSError, ValueError):
            return {}
        out: dict[str, _SwarmState] = {}
        if not isinstance(raw, dict):
            return {}
        for key, v in raw.items():
            if not isinstance(v, dict):
                continue
            try:
                out[key] = _SwarmState(
                    handle=str(v.get("handle") or display_handle(key)),
                    branch=str(v.get("branch") or ""),
                    is_linked_worktree=bool(v.get("is_linked_worktree", False)),
                    providers=[str(p) for p in (v.get("providers") or [])][:8],
                    sessions={
                        str(sid): {
                            "status": str(sv.get("status") or "running"),
                            "last_seen": float(sv.get("last_seen") or 0.0),
                        }
                        for sid, sv in list((v.get("sessions") or {}).items())[
                            :_MAX_SESSIONS_PER_SWARM
                        ]
                        if isinstance(sv, dict)
                    },
                    last_seen=float(v.get("last_seen") or 0.0),
                )
            except (TypeError, ValueError):
                continue
        return out

    def _save(self, data: dict[str, _SwarmState]) -> None:
        try:
            _STATE_DIR.mkdir(parents=True, exist_ok=True)
            try:
                os.chmod(_STATE_DIR, 0o700)
            except OSError:
                pass
            payload = {
                k: {
                    "handle": s.handle,
                    "branch": s.branch,
                    "is_linked_worktree": s.is_linked_worktree,
                    "providers": s.providers[:8],
                    "sessions": s.sessions,
                    "last_seen": s.last_seen,
                }
                for k, s in data.items()
            }
            fd, tmp = tempfile.mkstemp(prefix=".swarm_", dir=str(self._path.parent))
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    json.dump(payload, fh, separators=(",", ":"))
                try:
                    os.chmod(tmp, 0o600)
                except OSError:
                    pass
                os.replace(tmp, self._path)
            finally:
                if os.path.exists(tmp):
                    try:
                        os.unlink(tmp)
                    except OSError:
                        pass
        except OSError as exc:
            logger.warning("swarm: could not persist state: %s", exc)

    def _prune(self, data: dict[str, _SwarmState]) -> dict[str, _SwarmState]:
        now = self._now()
        for s in data.values():
            s.sessions = {
                sid: sv
                for sid, sv in s.sessions.items()
                if now - float(sv.get("last_seen", 0.0)) <= _ACTIVITY_TTL_S
            }
        live = {
            k: s
            for k, s in data.items()
            if now - s.last_seen <= _ACTIVITY_TTL_S and s.sessions
        }
        if len(live) > _MAX_SWARMS:
            keep = sorted(live.items(), key=lambda kv: kv[1].last_seen, reverse=True)
            live = dict(keep[:_MAX_SWARMS])
        return live

    # -- public API --

    def record_activity(
        self,
        swarm_key: str,
        *,
        handle: str,
        branch: str,
        provider: str,
        session_id: str,
        status: str = "running",
        is_linked_worktree: bool = False,
    ) -> None:
        """Mark a swarm/session active right now. Failure-soft (RK1)."""
        if not swarm_key or not session_id:
            return
        try:
            now = self._now()
            data = self._load()
            st = data.get(swarm_key) or _SwarmState(handle=handle, branch=branch)
            st.handle = handle or st.handle
            st.branch = branch or st.branch
            st.is_linked_worktree = is_linked_worktree or st.is_linked_worktree
            if provider and provider not in st.providers:
                st.providers = (st.providers + [provider])[:8]
            sess = st.sessions.get(session_id, {})
            sess["status"] = status
            sess["last_seen"] = now
            st.sessions[session_id] = sess
            if len(st.sessions) > _MAX_SESSIONS_PER_SWARM:
                newest = sorted(
                    st.sessions.items(),
                    key=lambda kv: kv[1].get("last_seen", 0.0),
                    reverse=True,
                )
                st.sessions = dict(newest[:_MAX_SESSIONS_PER_SWARM])
            st.last_seen = now
            data[swarm_key] = st
            self._save(self._prune(data))
        except Exception as exc:  # noqa: BLE001 — state must never crash the hook
            logger.warning("swarm: record_activity soft-failed: %s", exc)

    def rollup(self) -> list[dict[str, Any]]:
        """Pruned per-swarm summary for the S1b heartbeat. Never raises."""
        try:
            data = self._prune(self._load())
            now = self._now()
            out: list[dict[str, Any]] = []
            for key, s in data.items():
                statuses = [sv.get("status", "running") for sv in s.sessions.values()]
                blocked = sum(1 for st in statuses if st == "awaiting-approval")
                oldest_blocked_age = 0.0
                for sv in s.sessions.values():
                    if sv.get("status") == "awaiting-approval":
                        oldest_blocked_age = max(
                            oldest_blocked_age, now - float(sv.get("last_seen", now))
                        )
                out.append({
                    "swarm_key": key,
                    "handle": s.handle,
                    "is_linked_worktree": s.is_linked_worktree,
                    "providers": sorted(s.providers),
                    "agents": len(s.sessions),
                    "blocked": blocked,
                    "oldest_blocked_age_s": round(oldest_blocked_age, 1),
                    "last_seen_s_ago": round(now - s.last_seen, 1),
                })
            return out
        except Exception as exc:  # noqa: BLE001
            logger.warning("swarm: rollup soft-failed: %s", exc)
            return []
