"""Local approval registry for Phase 3 Iter 2B.

A managed Claude session can ask the user for permission before running a
tool (Read, Bash, etc.). When the helper spawned that Claude process, we
own a same-Mac fast path and want the macOS app to show those requests
inline rather than round-tripping through Supabase. This registry is the
helper-side state that backs that surface.

Two security checks gate every hook ingress:

  1. **Per-session capability token** — generated per managed session,
     passed to the Claude child via the env vars
     `CLI_PULSE_LOCAL_SESSION_ID` and `CLI_PULSE_LOCAL_HOOK_TOKEN`. The
     hook reads them at request time and presents them to the helper.
     Prevents cross-session forgery (Claude session A's hook cannot
     create a pending approval bound to session B because its env
     doesn't carry B's token).

  2. **Process-descent verification** — the UDS server pulls the peer
     PID off the connection (macOS `LOCAL_PEERPID`, Linux
     `SO_PEERCRED`) and walks the parent chain to confirm the
     connecting hook is a descendant of the Claude PID this helper
     recorded for the session. Defeats any-other-process forgery
     even if the capability token leaks (e.g. via env-var inspection
     by an unrelated process on the same Mac).

The two checks are belt-and-suspenders: each one closes a hole the
other doesn't. Same-session Claude tools necessarily inherit the env
and live in the descent tree, so they pass both — but that's intrinsic
to the trust model the user accepts when they type `claude` (already
true today for the existing `helper_secret`-based remote-approval
hook). The token is *session-scoped*, not *Claude-secret*, and the
PR description spells that boundary out in the security model.

The registry is **in-memory only**. A helper restart drops every
capability token AND every pending approval; the hook fails closed
(the catch-all fallback in `remote_hook.py` emits a local prompt).
This is the right durability story for a security-sensitive surface:
nothing on disk to leak, and the user sees the local prompt instead
of an unbounded silent retry.

Approval data the registry stores per pending row is intentionally
minimal:

    - approval_id (helper-generated UUIDv4, unguessable)
    - session_id (UUID of the managed session)
    - kind / type (e.g. "PermissionRequest" — string label only)
    - title + summary (single short lines, redacted by the caller)
    - tool_metadata (already-redacted dict; raw payloads must NOT be
      passed in — see `provider_adapters.claude` for the redaction
      that lives upstream)
    - status (pending → approved | rejected | expired | cancelled)
    - created_at + optional expires_at (monotonic + wall-clock)

The registry never logs the capability token, never embeds it in
events, and never returns it to the macOS app.
"""
from __future__ import annotations

import logging
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

logger = logging.getLogger("cli_pulse.local_approvals")

# Per-session capability token: 32 raw bytes → 44-char base64. Same width
# as the helper-auth-token so reviewers don't have to remember different
# entropy budgets per token type.
_TOKEN_BYTES = 32

# Default approval timeout when the hook doesn't override.
DEFAULT_APPROVAL_TIMEOUT_S = 60.0

# Hard cap on simultaneously-pending approvals per session. Practical
# Claude usage produces at most one outstanding PermissionRequest per
# session at a time; we set a small cap so a malfunctioning hook can't
# balloon helper memory by spamming `hook_create_approval`.
MAX_PENDING_PER_SESSION = 8

# Cap on parents to walk when verifying descent. Real Claude → hook
# trees are 1–2 hops; 20 is generous and bounds the cost of any
# bogus request that loops on `getppid` chains forever.
_PPID_WALK_LIMIT = 20


class ApprovalError(Exception):
    """Typed error surface for the approval registry. The UDS server
    maps the `code` field to wire-level error codes the Swift client
    decodes into `SessionControlError` cases.
    """

    __slots__ = ("code", "message")

    # Wire-level codes — kept stable; a Swift mapping pins these via
    # `SessionControlErrorMapping.error(forWireCode:)`.
    APPROVAL_NOT_FOUND = "approval_not_found"
    APPROVAL_EXPIRED = "approval_expired"
    APPROVAL_ALREADY_RESOLVED = "approval_already_resolved"
    APPROVAL_NOT_ALLOWED = "approval_not_allowed"   # decision-side wrong session
    APPROVAL_LIMIT = "approval_limit_reached"
    SESSION_NOT_FOUND = "session_not_found"
    CAPABILITY_INVALID = "approval_capability_invalid"

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class PendingApproval:
    """One outstanding hook approval. Fields documented in the module
    docstring. Stored verbatim under `ApprovalRegistry._pending`; the
    `to_dict_safe` method strips internal-only fields before any serialised
    output (event payload / status / list reply).
    """

    approval_id: str
    session_id: str
    kind: str
    title: str
    summary: str
    tool_metadata: dict[str, Any]
    status: str = "pending"     # pending | approved | rejected | expired | cancelled
    created_at_wall: float = field(default_factory=time.time)
    created_at_mono: float = field(default_factory=time.monotonic)
    expires_at_wall: float | None = None
    decided_decision: str | None = None
    decided_comment: str | None = None
    decided_at_wall: float | None = None
    # Condition variable that hook_wait_decision blocks on. Created
    # lazily so a snapshot list_pending doesn't allocate one per row.
    _cond: threading.Condition | None = field(default=None, repr=False, compare=False)

    def to_dict_safe(self) -> dict[str, Any]:
        """Serialised form sent over the wire. Excludes the Condition
        var and any future internal state — the dict is what the macOS
        app sees in `pending_approvals`, `subscribe_events` payloads,
        and snapshot replies.
        """
        d: dict[str, Any] = {
            "approval_id": self.approval_id,
            "session_id": self.session_id,
            "type": self.kind,
            "title": self.title,
            "summary": self.summary,
            "tool_metadata": self.tool_metadata,
            "status": self.status,
            "created_at": self.created_at_wall,
        }
        if self.expires_at_wall is not None:
            d["expires_at"] = self.expires_at_wall
        if self.decided_decision is not None:
            d["decision"] = self.decided_decision
            d["decided_at"] = self.decided_at_wall
            if self.decided_comment is not None:
                d["comment"] = self.decided_comment
        return d


@dataclass
class _ManagedSessionRecord:
    """What the registry remembers about each managed session."""

    session_id: str
    capability_token: str        # base64; never logged / never returned to app
    claude_pid: int | None       # None during tests with no real PTY
    started_at_mono: float = field(default_factory=time.monotonic)


class ApprovalRegistry:
    """In-memory store for per-session capability tokens and pending
    approvals. Thread-safe — every public method holds the registry's
    single lock for as briefly as possible. Long blocks (hook waits)
    hand off to a per-approval Condition variable so other registry
    operations (e.g. a parallel approve from the app) aren't blocked.

    Hook waits run on the UDS server's per-connection thread, NOT on
    the single-writer executor — `wait_for_decision` is allowed to
    block for tens of seconds without blocking session lifecycle work.
    """

    def __init__(
        self,
        *,
        on_event: Callable[[dict[str, Any]], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
        wall_clock: Callable[[], float] = time.time,
    ) -> None:
        self._lock = threading.Lock()
        self._sessions: dict[str, _ManagedSessionRecord] = {}
        # session_id -> approval_id -> PendingApproval. We index by
        # session first so cancel-on-stop can iterate one bucket
        # without scanning the whole pending set.
        self._pending: dict[str, dict[str, PendingApproval]] = {}
        # Reverse index for O(1) approve_action lookup.
        self._approval_to_session: dict[str, str] = {}
        # Optional event-broker tap. The registry doesn't import the
        # broker module directly so unit tests can wire just this
        # callable without dragging in the streaming surface.
        self._on_event = on_event
        self._clock = clock
        self._wall = wall_clock
        # Test seam: pluggable peer-pid + ppid-walk so unit tests can
        # simulate descent verification without spawning real Claude.
        self.peer_pid_resolver: Callable[[socket.socket], int | None] | None = (
            _peer_pid_from_socket
        )
        self.ppid_resolver: Callable[[int], int | None] | None = _read_ppid

    # ── session lifecycle ───────────────────────────────────

    def register_session(
        self, session_id: str, *, claude_pid: int | None
    ) -> str:
        """Generate a fresh capability token for `session_id` and
        return it. Caller MUST set the returned token in the env
        passed to the spawned Claude (`CLI_PULSE_LOCAL_HOOK_TOKEN`)
        and never log it anywhere else.
        """
        token = _generate_token()
        with self._lock:
            if session_id in self._sessions:
                # Re-spawn of the same id — overwrite, invalidate the
                # old token. Pending approvals from the old generation
                # are cancelled so a stale wait can't ever resolve.
                self._cancel_session_locked(session_id, reason="resession")
            self._sessions[session_id] = _ManagedSessionRecord(
                session_id=session_id,
                capability_token=token,
                claude_pid=claude_pid,
            )
        logger.info(
            "approvals: registered session=%s claude_pid=%s",
            session_id, claude_pid if claude_pid is not None else "n/a",
        )
        return token

    def update_session_pid(self, session_id: str, claude_pid: int) -> None:
        """Set the Claude PID for a session that was registered before
        spawn (when the PID wasn't known yet). No-op if the session is
        absent. Idempotent for repeated calls with the same PID.
        """
        if claude_pid <= 0:
            return
        with self._lock:
            rec = self._sessions.get(session_id)
            if rec is None:
                return
            rec.claude_pid = claude_pid

    def unregister_session(self, session_id: str) -> None:
        """Drop the session and cancel any pending approvals for it.
        Safe to call multiple times.
        """
        with self._lock:
            existed = self._sessions.pop(session_id, None) is not None
            cancelled = self._cancel_session_locked(session_id, reason="stop")
        if existed:
            logger.info(
                "approvals: unregistered session=%s cancelled=%d",
                session_id, cancelled,
            )

    def has_session(self, session_id: str) -> bool:
        with self._lock:
            return session_id in self._sessions

    # ── hook ingress (capability + descent gates) ──────────────

    def authenticate_hook(
        self,
        session_id: str,
        capability_token: str,
        *,
        peer_socket: socket.socket | None = None,
        peer_pid: int | None = None,
    ) -> None:
        """Verify the hook is allowed to interact on behalf of
        `session_id`. Raises `ApprovalError` on any mismatch.

        Two checks, both must pass:
          1. capability token equals the one stored at register time
          2. the connecting process descends from the recorded
             claude_pid (kernel-level proof; cannot be faked by a
             token leak from an unrelated process)

        Either check failing → raise. Logging of failures is intentionally
        sparse: we log the session_id and the failure category, never
        the token itself or any peer-process command line.
        """
        with self._lock:
            rec = self._sessions.get(session_id)
        if rec is None:
            raise ApprovalError(
                ApprovalError.SESSION_NOT_FOUND,
                f"no managed session with id {session_id!r}",
            )
        if not _const_eq(rec.capability_token, capability_token):
            logger.warning(
                "approvals: capability mismatch session=%s", session_id,
            )
            raise ApprovalError(
                ApprovalError.CAPABILITY_INVALID,
                "session capability token mismatch",
            )
        # Descent check — best-effort: if we have neither a recorded
        # claude_pid (test stub) nor a peer-pid resolver (unsupported
        # platform) we skip with a logged warning. Production helper
        # always supplies both.
        if rec.claude_pid is None:
            return
        actual_pid = peer_pid
        if actual_pid is None and peer_socket is not None and self.peer_pid_resolver is not None:
            try:
                actual_pid = self.peer_pid_resolver(peer_socket)
            except Exception as exc:  # noqa: BLE001 — defensive
                logger.warning("approvals: peer_pid resolve raised: %s", exc)
                actual_pid = None
        if actual_pid is None:
            logger.warning(
                "approvals: descent check skipped (no peer pid) session=%s",
                session_id,
            )
            # Don't fail closed here — environments where peer-pid
            # extraction isn't available (older OS releases, exotic
            # FS layouts) still benefit from the capability check.
            # The PR description calls this gap out explicitly.
            return
        if not self._verify_descent(actual_pid, rec.claude_pid):
            logger.warning(
                "approvals: descent rejected peer_pid=%s session=%s expected_root=%s",
                actual_pid, session_id, rec.claude_pid,
            )
            raise ApprovalError(
                ApprovalError.CAPABILITY_INVALID,
                "hook process is not a descendant of the managed session",
            )

    def _verify_descent(self, peer_pid: int, root_pid: int) -> bool:
        """Walk parent PIDs starting from `peer_pid` and return True if
        any ancestor matches `root_pid`. Bounds the walk at
        `_PPID_WALK_LIMIT` so a kernel oddity can't loop us forever.
        """
        if peer_pid <= 0 or root_pid <= 0:
            return False
        if self.ppid_resolver is None:
            return False
        current = peer_pid
        for _ in range(_PPID_WALK_LIMIT):
            if current == root_pid:
                return True
            if current in (0, 1):
                return False
            try:
                parent = self.ppid_resolver(current)
            except Exception as exc:  # noqa: BLE001
                logger.debug("approvals: ppid_resolver raised at %s: %s", current, exc)
                return False
            if parent is None or parent == current:
                return False
            current = parent
        return False

    # ── approval lifecycle ──────────────────────────────────

    def create_pending(
        self,
        session_id: str,
        *,
        kind: str,
        title: str,
        summary: str,
        tool_metadata: dict[str, Any],
        timeout_s: float = DEFAULT_APPROVAL_TIMEOUT_S,
    ) -> str:
        """Create a new pending approval and return the helper-generated
        approval_id. The caller MUST have already passed
        `authenticate_hook`. Raises `ApprovalError` if the session
        already has too many pending approvals.

        `tool_metadata` is stored as-is. Callers (e.g. `remote_hook.py`)
        are responsible for redacting it before passing in.
        """
        approval_id = str(uuid.uuid4())
        wall_now = self._wall()
        # Wire-level UDS dispatch already clamps client-supplied
        # timeouts to a sane [1, 300] range; the registry trusts its
        # caller, which lets unit tests use short TTLs without a
        # baked-in floor.
        expires_wall = wall_now + timeout_s if timeout_s and timeout_s > 0 else None
        approval = PendingApproval(
            approval_id=approval_id,
            session_id=session_id,
            kind=str(kind)[:64],
            title=str(title)[:200],
            summary=str(summary)[:512],
            tool_metadata=_safe_metadata(tool_metadata),
            created_at_wall=wall_now,
            created_at_mono=self._clock(),
            expires_at_wall=expires_wall,
        )
        approval._cond = threading.Condition()
        with self._lock:
            if session_id not in self._sessions:
                raise ApprovalError(
                    ApprovalError.SESSION_NOT_FOUND,
                    f"no managed session with id {session_id!r}",
                )
            bucket = self._pending.setdefault(session_id, {})
            if len(bucket) >= MAX_PENDING_PER_SESSION:
                raise ApprovalError(
                    ApprovalError.APPROVAL_LIMIT,
                    f"too many pending approvals for session {session_id}",
                )
            bucket[approval_id] = approval
            self._approval_to_session[approval_id] = session_id
        self._emit_event({
            "event": "approval_requested",
            "session_id": session_id,
            "approval_id": approval_id,
            "approval": approval.to_dict_safe(),
        })
        return approval_id

    def wait_for_decision(
        self,
        session_id: str,
        approval_id: str,
        *,
        timeout_s: float | None = None,
    ) -> dict[str, Any]:
        """Block until the approval resolves (approve / reject /
        expire / cancel) or `timeout_s` elapses. Returns the
        approval's serialised dict on resolution; raises
        `ApprovalError(APPROVAL_NOT_FOUND)` if the id is unknown.

        Hook flow uses this from the UDS server's per-connection
        thread, NOT from the single-writer executor, so the wait is
        free to block. App-side `approve_action` resolves the
        approval and notifies the Condition.
        """
        # Resolve the approval row + cond once, then wait outside the
        # registry lock.
        with self._lock:
            bucket = self._pending.get(session_id) or {}
            approval = bucket.get(approval_id)
        if approval is None or approval._cond is None:
            raise ApprovalError(
                ApprovalError.APPROVAL_NOT_FOUND,
                f"no pending approval {approval_id!r}",
            )
        deadline_mono: float | None
        if timeout_s is not None and timeout_s > 0:
            deadline_mono = self._clock() + timeout_s
        else:
            deadline_mono = None

        with approval._cond:
            while approval.status == "pending":
                # Auto-expire if the wall-clock TTL elapsed before
                # caller-supplied timeout.
                if approval.expires_at_wall is not None and self._wall() >= approval.expires_at_wall:
                    self._resolve_locked(approval, "expired", None)
                    break
                wait_s: float | None
                if deadline_mono is not None:
                    wait_s = max(0.0, deadline_mono - self._clock())
                    if wait_s == 0.0:
                        # Timed out, but don't mark expired — the hook's
                        # own deadline is its concern; the approval is
                        # still pending until the user decides or TTL
                        # expires. Caller treats this as a timeout.
                        return {**approval.to_dict_safe(), "timed_out": True}
                else:
                    # If a wall-clock TTL exists, sleep until then; else
                    # an unbounded wait is the caller's responsibility
                    # to enforce — we cap at 1 s so registry shutdown
                    # can yank us out cleanly.
                    if approval.expires_at_wall is not None:
                        wait_s = max(0.5, approval.expires_at_wall - self._wall())
                    else:
                        wait_s = 1.0
                approval._cond.wait(timeout=wait_s)
        return approval.to_dict_safe()

    def decide(
        self,
        approval_id: str,
        decision: str,
        *,
        comment: str | None = None,
        session_id_hint: str | None = None,
    ) -> dict[str, Any]:
        """Resolve a pending approval. Used by `approve_action` from
        the app surface. Raises:

          - APPROVAL_NOT_FOUND if the id is unknown
          - APPROVAL_EXPIRED if the TTL elapsed before this call
          - APPROVAL_ALREADY_RESOLVED if a prior decision landed first
          - APPROVAL_NOT_ALLOWED if the caller-supplied
            `session_id_hint` doesn't match the approval's session
        """
        if decision not in ("approve", "reject"):
            raise ApprovalError(
                ApprovalError.APPROVAL_NOT_FOUND,
                f"unknown decision {decision!r}",
            )
        with self._lock:
            sid = self._approval_to_session.get(approval_id)
            if sid is None:
                raise ApprovalError(
                    ApprovalError.APPROVAL_NOT_FOUND,
                    f"no approval {approval_id!r}",
                )
            if session_id_hint is not None and session_id_hint != sid:
                raise ApprovalError(
                    ApprovalError.APPROVAL_NOT_ALLOWED,
                    "approval id does not belong to the supplied session",
                )
            approval = (self._pending.get(sid) or {}).get(approval_id)
            if approval is None or approval._cond is None:
                raise ApprovalError(
                    ApprovalError.APPROVAL_NOT_FOUND,
                    f"no approval {approval_id!r}",
                )
        # Resolve under the approval's own cond.
        with approval._cond:
            if approval.status == "expired":
                raise ApprovalError(
                    ApprovalError.APPROVAL_EXPIRED,
                    "approval already expired",
                )
            if approval.status != "pending":
                raise ApprovalError(
                    ApprovalError.APPROVAL_ALREADY_RESOLVED,
                    f"approval already {approval.status}",
                )
            # Re-check expiry under the cond — TTL could have elapsed
            # in the gap between lookup and lock acquisition.
            if approval.expires_at_wall is not None and self._wall() >= approval.expires_at_wall:
                self._resolve_locked(approval, "expired", None)
                raise ApprovalError(
                    ApprovalError.APPROVAL_EXPIRED,
                    "approval expired before decision",
                )
            self._resolve_locked(
                approval,
                "approved" if decision == "approve" else "rejected",
                comment,
            )
            return approval.to_dict_safe()

    def list_pending(self, session_id: str | None = None) -> list[dict[str, Any]]:
        """Snapshot of pending approvals. Optionally scoped to one
        session; without scope, returns all sessions' pending rows.

        Sweeps expired rows in passing — a long-idle approval should
        not show as pending forever.
        """
        results: list[dict[str, Any]] = []
        wall_now = self._wall()
        with self._lock:
            sessions_to_scan: Iterable[str]
            if session_id is None:
                sessions_to_scan = list(self._pending.keys())
            else:
                sessions_to_scan = [session_id] if session_id in self._pending else []
            for sid in sessions_to_scan:
                bucket = self._pending.get(sid) or {}
                for approval in list(bucket.values()):
                    if approval.status == "pending":
                        if approval.expires_at_wall is not None and wall_now >= approval.expires_at_wall:
                            # Sweep: mark expired so a follow-up wait
                            # observes the right state. Do this under
                            # the cond so a concurrent wait sees it.
                            cond = approval._cond
                            assert cond is not None
                            with cond:
                                if approval.status == "pending":
                                    self._resolve_locked(approval, "expired", None)
                            continue
                        results.append(approval.to_dict_safe())
        return results

    # ── internal helpers ────────────────────────────────────

    def _cancel_session_locked(self, session_id: str, *, reason: str) -> int:
        """Cancel every pending approval for `session_id`. Caller
        holds `self._lock`. Returns the count cancelled.
        """
        bucket = self._pending.pop(session_id, None)
        if not bucket:
            return 0
        cancelled = 0
        for approval in bucket.values():
            self._approval_to_session.pop(approval.approval_id, None)
            cond = approval._cond
            if cond is None:
                continue
            with cond:
                if approval.status == "pending":
                    self._resolve_locked(approval, "cancelled", reason)
                    cancelled += 1
        return cancelled

    def _resolve_locked(
        self, approval: PendingApproval, status: str, comment: str | None
    ) -> None:
        """Caller holds `approval._cond`. Mutates the approval, notifies
        waiters, and emits an `approval_resolved` event.
        """
        approval.status = status
        approval.decided_decision = (
            "approved" if status == "approved"
            else "rejected" if status == "rejected"
            else status  # expired / cancelled — same string in payload
        )
        approval.decided_comment = comment
        approval.decided_at_wall = self._wall()
        if approval._cond is not None:
            approval._cond.notify_all()
        # Best-effort event emission — failures don't cascade. The
        # registry doesn't catch the broker's exceptions because the
        # broker contract is "non-blocking, swallow its own errors."
        self._emit_event({
            "event": "approval_resolved",
            "session_id": approval.session_id,
            "approval_id": approval.approval_id,
            "decision": approval.decided_decision,
            "status": approval.status,
        })

    def _emit_event(self, event: dict[str, Any]) -> None:
        if self._on_event is None:
            return
        try:
            self._on_event(event)
        except Exception as exc:  # noqa: BLE001
            logger.debug("approvals: on_event raised: %s", exc)


# ── helpers ──────────────────────────────────────────────


def _generate_token() -> str:
    """Generate a fresh capability token. base64 of 32 random bytes."""
    import base64
    return base64.b64encode(secrets.token_bytes(_TOKEN_BYTES)).decode("ascii")


def _const_eq(a: str, b: str) -> bool:
    """Constant-time string equality (HMAC-style). Empty inputs always
    return False — defenders in depth.
    """
    if not a or not b:
        return False
    import hmac
    return hmac.compare_digest(a, b)


def _safe_metadata(meta: dict[str, Any]) -> dict[str, Any]:
    """Strip / cap fields the registry will store + emit. Any value
    longer than 512 chars is truncated; nested dicts get one level of
    pass-through (Claude's hookSpecificOutput.tool_input is one-level
    nested in practice). Keys longer than 64 chars are dropped.
    """
    if not isinstance(meta, dict):
        return {}
    out: dict[str, Any] = {}
    for k, v in meta.items():
        if not isinstance(k, str) or not k or len(k) > 64:
            continue
        if isinstance(v, str):
            out[k] = v[:512]
        elif isinstance(v, (int, float, bool)) or v is None:
            out[k] = v
        elif isinstance(v, dict):
            inner: dict[str, Any] = {}
            for ik, iv in v.items():
                if not isinstance(ik, str) or not ik or len(ik) > 64:
                    continue
                if isinstance(iv, str):
                    inner[ik] = iv[:256]
                elif isinstance(iv, (int, float, bool)) or iv is None:
                    inner[ik] = iv
            out[k] = inner
        elif isinstance(v, list):
            inner_list: list[Any] = []
            for item in v[:32]:
                if isinstance(item, str):
                    inner_list.append(item[:256])
                elif isinstance(item, (int, float, bool)) or item is None:
                    inner_list.append(item)
            out[k] = inner_list
        # Drop everything else (objects, complex types).
    return out


# ── platform-specific peer + ppid resolution ──────────────


def _peer_pid_from_socket(sock: socket.socket) -> int | None:
    """Return the connected peer's PID via the OS-native UDS facility.

    macOS: getsockopt(SOL_LOCAL, LOCAL_PEERPID) → 4-byte int.
    Linux: getsockopt(SOL_SOCKET, SO_PEERCRED) → struct ucred {pid,uid,gid}.
    Other platforms: returns None (no descent verification possible —
    the registry caller logs a warning + falls back to token-only auth).
    """
    if sys.platform == "darwin":
        # SOL_LOCAL = 0; LOCAL_PEERPID = 2. These are stable in
        # `<sys/un.h>` on every shipping macOS version.
        try:
            buf = sock.getsockopt(0, 2, struct.calcsize("i"))
            (pid,) = struct.unpack("i", buf)
            return pid if pid > 0 else None
        except OSError as exc:
            logger.debug("LOCAL_PEERPID failed: %s", exc)
            return None
    if sys.platform.startswith("linux"):
        SO_PEERCRED = 17
        try:
            buf = sock.getsockopt(socket.SOL_SOCKET, SO_PEERCRED, struct.calcsize("3i"))
            pid, _uid, _gid = struct.unpack("3i", buf)
            return pid if pid > 0 else None
        except OSError as exc:
            logger.debug("SO_PEERCRED failed: %s", exc)
            return None
    return None


def _read_ppid(pid: int) -> int | None:
    """Return the parent PID of `pid`, or None if the lookup fails.

    Linux: read /proc/<pid>/status, parse the "PPid:" line.
    macOS / other: fall back to `ps -o ppid= -p <pid>`. Slightly slower
    but only invoked once per hook ingress, which happens at most a few
    times per second under realistic Claude load.
    """
    if pid <= 0:
        return None
    if sys.platform.startswith("linux"):
        try:
            with open(f"/proc/{pid}/status", "rb") as fh:
                for line in fh:
                    if line.startswith(b"PPid:"):
                        parts = line.split()
                        if len(parts) >= 2:
                            try:
                                return int(parts[1])
                            except ValueError:
                                return None
        except OSError:
            return None
        return None
    # macOS path (also a portable fallback).
    try:
        proc = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            check=False,
            capture_output=True,
            text=True,
            timeout=1.0,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    out = proc.stdout.strip()
    if not out:
        return None
    try:
        return int(out)
    except ValueError:
        return None
