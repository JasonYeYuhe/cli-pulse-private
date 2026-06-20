"""Claude OAuth token resolution for managed sessions (v-next P0-A).

A managed `claude` session needs a *valid* OAuth access token at spawn
time. On this class of macOS install the keychain item
``Claude Code-credentials`` can hold an EXPIRED access token with an EMPTY
``refreshToken``, while ``~/.claude/.credentials.json`` (the file) holds
the real, refreshable credential. claude reads the keychain first and
cannot self-refresh from an empty refresh token, so a launchd-spawned
claude presents a stale bearer and 401s ("Please run /login").

This module resolves a fresh access token by:

  1. reading the credential **file-first** (the file holds the refresh
     token; keychain is the fallback source),
  2. **refreshing** via Anthropic's OAuth token endpoint when the access
     token is expired — the request REQUIRES the public Claude Code
     ``client_id`` and the endpoint ROTATES the refresh token,
  3. **persisting** the rotated credential back to the file atomically
     (temp + rename, 0600, preserving every other field), so the next
     spawn doesn't refresh again and the rotated refresh token survives,
  4. returning the fresh access token for FD/env injection into the
     spawned child (``RemoteAgentManager._inject_provider_auth``).

Request shape + FD-injection were proven on-device 2026-06-20 — see the
``feedback_managed_claude_agy_auth`` memory. This module NEVER logs the
raw token.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import tempfile
import time
import urllib.request
from typing import Any, Callable

logger = logging.getLogger("cli_pulse.claude_oauth")

# Well-known PUBLIC Claude Code OAuth client_id (PKCE installed-app client;
# documented + shipped in the claude binary, NOT a secret). The refresh
# endpoint rejects a body without it.
CLAUDE_CODE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

# console.anthropic.com is the live token endpoint (proven 2026-06-20);
# api.anthropic.com kept as a fallback in case the routing changes.
_REFRESH_ENDPOINTS = (
    "https://console.anthropic.com/v1/oauth/token",
    "https://api.anthropic.com/v1/oauth/token",
)

# Module-level (overridable by tests via monkeypatch).
_CREDENTIALS_FILE = os.path.expanduser("~/.claude/.credentials.json")
_KEYCHAIN_SERVICE = "Claude Code-credentials"

# Refresh if the access token expires within this many seconds (or is
# already past). Keeps a margin so a token doesn't expire mid-spawn.
_EXPIRY_SKEW_SECS = 300
# Per-endpoint network timeout. The refresh runs on the spawn path, so
# keep it tight — a token that's still valid never reaches the network.
_REFRESH_TIMEOUT_SECS = 10


def _now() -> float:
    return time.time()


# ── credential reading ───────────────────────────────────────────────


def _exp_to_secs(expires_at: Any) -> float | None:
    """Normalize an ``expiresAt`` value (ms or s) to epoch seconds."""
    if not isinstance(expires_at, (int, float)) or expires_at <= 0:
        return None
    return expires_at / 1000.0 if expires_at > 1e12 else float(expires_at)


def _oauth_of(doc: Any) -> dict | None:
    if not isinstance(doc, dict):
        return None
    o = doc.get("claudeAiOauth") or doc.get("claude_ai_oauth")
    return o if isinstance(o, dict) else None


def _access_of(o: dict) -> str | None:
    return o.get("accessToken") or o.get("access_token") or None


def _refresh_of(o: dict) -> str | None:
    return o.get("refreshToken") or o.get("refresh_token") or None


def _expiry_of(o: dict) -> float | None:
    return _exp_to_secs(o.get("expiresAt") or o.get("expires_at"))


def _read_file_doc() -> dict | None:
    try:
        with open(_CREDENTIALS_FILE, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def _read_keychain_oauth() -> dict | None:
    try:
        proc = subprocess.run(
            ["security", "find-generic-password", "-s", _KEYCHAIN_SERVICE, "-w"],
            capture_output=True, text=True, timeout=5,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        return _oauth_of(json.loads(proc.stdout.strip()))
    except ValueError:
        return None


def read_claude_oauth() -> tuple[dict | None, str | None]:
    """Return ``(oauth_dict, source)`` where source ∈ {'file','keychain'}.

    Prefers the source that actually holds a (non-empty) refresh token —
    the file on this class of install — so a refresh is possible. Falls
    back to whichever credential exists if neither has a refresh token.
    """
    file_oauth = _oauth_of(_read_file_doc())
    if file_oauth and _refresh_of(file_oauth):
        return file_oauth, "file"
    kc_oauth = _read_keychain_oauth()
    if kc_oauth and _refresh_of(kc_oauth):
        return kc_oauth, "keychain"
    if file_oauth:
        return file_oauth, "file"
    if kc_oauth:
        return kc_oauth, "keychain"
    return None, None


# ── refresh + persist ────────────────────────────────────────────────


def refresh_claude_token(
    refresh_token: str,
    *,
    client_id: str = CLAUDE_CODE_CLIENT_ID,
    urlopen: Callable | None = None,
) -> dict | None:
    """POST the refresh grant; return the parsed token response or None.

    The response we consume: ``access_token``, ``refresh_token`` (ROTATED
    — a new value each refresh), ``expires_in`` (seconds). ``client_id``
    is REQUIRED by the endpoint (a bare grant_type+refresh_token body is
    rejected). Tries each endpoint until one yields a usable token.
    """
    if not refresh_token:
        return None
    opener = urlopen or urllib.request.urlopen
    body = json.dumps({
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
        "client_id": client_id,
    }).encode()
    for endpoint in _REFRESH_ENDPOINTS:
        try:
            req = urllib.request.Request(
                endpoint, data=body,
                headers={
                    "Content-Type": "application/json",
                    "User-Agent": "CLI-Pulse-Helper/0.2",
                },
            )
            with opener(req, timeout=_REFRESH_TIMEOUT_SECS) as resp:
                data = json.loads(resp.read())
            at = data.get("access_token")
            if isinstance(at, str) and at.startswith("sk-ant-oat"):
                logger.debug("claude token refresh succeeded via %s", endpoint)
                return data
            logger.debug("claude refresh via %s returned no usable token", endpoint)
        except Exception as exc:  # noqa: BLE001 — try the next endpoint
            logger.debug("claude refresh via %s failed: %s", endpoint, exc)
    return None


def _persist_refreshed_to_file(token_response: dict) -> bool:
    """Atomically write the refreshed credential back to the file,
    preserving every other field (incl. ``mcpOAuth`` and unknown keys)
    and the rotated refresh token. 0600. Best-effort — returns False on
    any error (the in-memory token still drives the current spawn).
    """
    new_at = token_response.get("access_token")
    if not new_at:
        return False
    doc = _read_file_doc()
    if doc is None:
        # File missing/corrupt — don't fabricate one (we'd lose mcpOAuth
        # and could clobber a concurrent interactive-claude writeback).
        return False
    o = _oauth_of(doc)
    if o is None:
        return False
    o["accessToken"] = new_at
    new_rt = token_response.get("refresh_token")
    if new_rt:
        o["refreshToken"] = new_rt
    expires_in = token_response.get("expires_in")
    if isinstance(expires_in, (int, float)) and expires_in > 0:
        o["expiresAt"] = int((_now() + expires_in) * 1000)
    doc["claudeAiOauth"] = o
    try:
        d = os.path.dirname(_CREDENTIALS_FILE) or "."
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".cred", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(doc, f)
                f.write("\n")
            os.chmod(tmp, 0o600)
            os.replace(tmp, _CREDENTIALS_FILE)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True
    except OSError as exc:
        logger.warning("claude credential writeback failed: %s", exc)
        return False


def resolve_fresh_claude_access_token(*, urlopen: Callable | None = None) -> str | None:
    """Return a currently-valid claude access token, refreshing +
    persisting when the stored one is expired. None if no credential is
    found. On a refresh failure, returns the (stale) access token if one
    exists so the caller can still try — claude will 401 if it's truly
    dead, which is no worse than injecting nothing.
    """
    oauth, _source = read_claude_oauth()
    if oauth is None:
        logger.debug("no claude credential found for managed-session injection")
        return None
    access = _access_of(oauth)
    expiry = _expiry_of(oauth)
    # Provably valid (with skew)? Use as-is — preserves offline capability
    # and avoids needless token rotation.
    if access and expiry is not None and _now() + _EXPIRY_SKEW_SECS < expiry:
        return access
    refresh = _refresh_of(oauth)
    if not refresh:
        logger.debug("claude token not provably valid and no refresh token available")
        return access
    resp = refresh_claude_token(refresh, urlopen=urlopen)
    if not resp:
        return access  # refresh failed; fall back to stale (may 401)
    _persist_refreshed_to_file(resp)
    return resp.get("access_token") or access
