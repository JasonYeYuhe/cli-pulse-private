"""Entry point for the remote-approval hook.

Wired up to a provider's PermissionRequest hook. Reads the hook input from
stdin, uploads a redacted permission request to Supabase via the helper RPCs,
polls for the user's decision, and writes the provider-specific hook output
to stdout.

Behaviour:
  * If the helper isn't paired or the network is unreachable → fail closed by
    asking the local CLI to handle the prompt itself (`emit_local_fallback`).
  * If the user doesn't decide before the configured timeout → same fallback.
  * If the user approves → emit allow.
  * If the user denies → emit deny.
  * Always-Allow (alwaysSession scope) is silently downgraded to once because
    Phase 1 deliberately does not expose permissionUpdates remotely.

CLI:
  python3 cli_pulse_helper.py remote-approval-hook --provider claude
"""
from __future__ import annotations

import argparse
import hmac
import hashlib
import json
import logging
import os
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Any


# Env var the helper sets when spawning a managed Claude session. The
# hook prefers this over the raw `session_id` field in Claude's hook
# input so that an inline approve in the Sessions UI lands on the row
# matching the managed session, not the hook-internal session id.
#
# After UUID validation only — a mis-set env var that doesn't parse is
# silently dropped and we fall through to the hook's own session_id.
# If the env-var session_id doesn't belong to the calling user/device,
# the SQL `remote_helper_create_permission_request` zeroes it out (see
# v0.27 + v0.30) so the request still creates but is unbound.
REMOTE_SESSION_ID_ENV = "CLI_PULSE_REMOTE_SESSION_ID"

logger = logging.getLogger("cli_pulse.remote_hook")


@dataclass
class HookConfig:
    """Knobs for the hook loop. All have safe defaults."""

    poll_interval_s: float = 1.0
    timeout_s: float = 10.0
    ttl_seconds: int = 60
    # If True, high-risk requests skip the remote round-trip and immediately
    # fall back to local prompt. Phase 1 default = True (fail closed).
    fail_closed_on_high_risk: bool = True


def _read_stdin_json() -> dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.warning("hook input was not JSON: %s", exc)
        return {}


def _hmac_path(secret: bytes | str, path: str) -> str | None:
    if not path or not secret:
        return None
    try:
        key = secret if isinstance(secret, bytes) else secret.encode("utf-8")
        digest = hmac.new(key, path.encode("utf-8"), hashlib.sha256)
        return digest.hexdigest()
    except (AttributeError, TypeError, ValueError):
        return None


def _emit(output: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(output))
    sys.stdout.write("\n")
    sys.stdout.flush()


# Hardcoded last-resort hook output. Used by the top-level except in run_hook
# when something has gone so wrong that we can't even build a normal fallback
# via the adapter (e.g. provider_adapters package is unimportable, or the
# provider adapter raised NotImplementedError). Format MUST stay valid Claude
# Code PermissionRequest output per the official docs:
# https://code.claude.com/docs/en/hooks
#
# `behavior` may only be "allow" or "deny" — there is no "ask" / abstain shape
# for PermissionRequest (that's PreToolUse's permissionDecision). Therefore
# the safe fail-closed path is deny + message that tells the user to retry
# locally, which lets Claude's own permission prompt run on the next attempt.
_RAW_DENY_FALLBACK = (
    '{"hookSpecificOutput":{"hookEventName":"PermissionRequest",'
    '"decision":{"behavior":"deny",'
    '"message":"CLI Pulse remote-approval-hook crashed. '
    'If this persists, open CLI Pulse \\u2192 Settings \\u2192 Privacy '
    'and turn off Remote Control so the local Claude permission prompt '
    'runs on your next attempt."}}}\n'
)


def _emit_raw_deny_fallback() -> None:
    """Write a hardcoded JSON deny to stdout, never raises.

    The hook's contract with Claude Code is that stdout MUST be a single line
    of valid JSON. If anything in run_hook crashes — including the adapter
    construction or the provider_adapters import itself — we still owe the
    caller a parseable response, otherwise Claude either hangs or fails
    opaquely. This bypasses every helper and writes a constant string.

    Per official docs, PermissionRequest decision.behavior only supports
    `allow` and `deny`, so a crash falls back to deny with an explanatory
    message rather than a non-existent "ask" value.
    """
    try:
        sys.stdout.write(_RAW_DENY_FALLBACK)
        sys.stdout.flush()
    except Exception:
        # If even the raw write fails (e.g. closed stdout), there is nothing
        # else we can do. Swallow so we don't escalate further.
        pass


def run_hook(
    provider: str,
    config: HookConfig | None = None,
    *,
    stdin_payload: dict[str, Any] | None = None,
    helper_config: Any | None = None,
    rpc_caller: Any | None = None,
    user_secret_loader: Any | None = None,
    sleep_fn: Any | None = None,
) -> int:
    """Execute one hook invocation. Returns process exit code (0 on success).

    Most arguments default to None so the caller can run it as a script. Tests
    inject stubs to avoid touching disk/network.

    Defence in depth: the entire body is wrapped so that ANY unhandled
    exception (NotImplementedError from the codex/shell stubs, missing
    provider_adapters package, KeyboardInterrupt, etc.) still emits a
    hardcoded "ask" JSON to stdout. Without this, Claude Code sees an empty
    stdout from the hook and either hangs or fails opaquely.
    """
    try:
        return _run_hook_inner(
            provider, config,
            stdin_payload=stdin_payload,
            helper_config=helper_config,
            rpc_caller=rpc_caller,
            user_secret_loader=user_secret_loader,
            sleep_fn=sleep_fn,
        )
    except Exception as exc:
        logger.error("remote-approval-hook crashed: %s", exc, exc_info=True)
        _emit_raw_deny_fallback()
        return 0


def _run_hook_inner(
    provider: str,
    config: HookConfig | None = None,
    *,
    stdin_payload: dict[str, Any] | None = None,
    helper_config: Any | None = None,
    rpc_caller: Any | None = None,
    user_secret_loader: Any | None = None,
    sleep_fn: Any | None = None,
) -> int:
    """Hook body. Wrapped by `run_hook` for last-resort fallback."""
    cfg = config or HookConfig()
    raw = stdin_payload if stdin_payload is not None else _read_stdin_json()

    # Lazy-import the heavy modules so unit tests can monkeypatch with a stub
    # rpc_caller without dragging in cli_pulse_helper / urllib at import time.
    if rpc_caller is None or helper_config is None:
        try:
            import cli_pulse_helper  # type: ignore
            import user_secret as _user_secret  # type: ignore
        except Exception as exc:  # pragma: no cover — only triggered at runtime
            logger.error("helper modules not importable: %s", exc)
            from provider_adapters import adapter_for
            adapter = adapter_for(provider)
            parsed = _safe_parse(adapter, raw, None)
            _emit(adapter.emit_local_fallback(parsed, "helper not available"))
            return 0
    else:
        cli_pulse_helper = None  # placeholder; injected callers don't need it
        _user_secret = None

    if helper_config is None:
        try:
            helper_config = cli_pulse_helper.load_config()  # type: ignore[union-attr]
        except Exception as exc:
            logger.warning("helper not paired or config invalid: %s", exc)
            from provider_adapters import adapter_for
            adapter = adapter_for(provider)
            parsed = _safe_parse(adapter, raw, None)
            _emit(adapter.emit_local_fallback(parsed, "helper not paired"))
            return 0

    if rpc_caller is None:
        rpc_caller = cli_pulse_helper.supabase_rpc  # type: ignore[union-attr]

    secret_loader = user_secret_loader or (_user_secret.load_or_create_secret if _user_secret else None)
    user_path_secret = secret_loader() if secret_loader else ""

    from provider_adapters import adapter_for, AdapterRisk
    adapter = adapter_for(provider)

    cwd = str(raw.get("cwd") or "")
    cwd_hmac = _hmac_path(user_path_secret or "", cwd) if cwd else None
    parsed = _safe_parse(adapter, raw, cwd_hmac)

    # High-risk fail-closed shortcut: do not even emit a remote request.
    if cfg.fail_closed_on_high_risk and parsed.risk == AdapterRisk.HIGH:
        logger.info("high-risk %s call — falling back to local prompt", parsed.tool_name)
        _emit(adapter.emit_local_fallback(parsed, "High-risk action requires local approval"))
        return 0

    request_id = str(uuid.uuid4())
    session_id_str = str(raw.get("session_id") or "")
    session_uuid = _resolve_managed_session_id(session_id_str)

    sleep = sleep_fn or time.sleep

    # Phase 3 Iter 2B local-first fast path. When the helper spawned this
    # Claude session, it set three env vars on the child:
    #
    #   CLI_PULSE_LOCAL_HELPER_SOCK  — UDS socket path
    #   CLI_PULSE_LOCAL_SESSION_ID   — managed session UUID
    #   CLI_PULSE_LOCAL_HOOK_TOKEN   — per-session capability token
    #
    # If all three are set we try the local UDS approval path before
    # touching Supabase. On any failure (helper down, gate off, the
    # user has multiple managed sessions and this Claude isn't one of
    # them) we fall through to the existing Supabase flow — same
    # remote-approval UX users already have.
    #
    # The local path is faster, doesn't need internet, and lets the
    # hook continue to work while Remote Control is off (the user
    # opted in by enabling Local Session Control on this Mac).
    local_decision = _try_local_uds_hook(parsed, adapter)
    if local_decision is not None:
        _emit(adapter.emit_hook_output(local_decision, parsed))
        return 0

    try:
        rpc_caller(
            "remote_helper_create_permission_request",
            {
                "p_device_id": helper_config.device_id,
                "p_helper_secret": helper_config.helper_secret,
                "p_request_id": request_id,
                "p_session_id": session_uuid,
                "p_provider": parsed.provider,
                "p_tool_name": parsed.tool_name,
                "p_summary": parsed.summary,
                "p_payload": parsed.payload,
                "p_risk": parsed.risk,
                "p_ttl_seconds": int(cfg.ttl_seconds),
            },
        )
    except Exception as exc:
        logger.warning("create_permission_request failed: %s", exc)
        _emit(adapter.emit_local_fallback(parsed, "Remote approval channel unavailable"))
        return 0

    deadline = time.monotonic() + cfg.timeout_s
    decision_obj: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        try:
            result = rpc_caller(
                "remote_helper_poll_permission_decision",
                {
                    "p_device_id": helper_config.device_id,
                    "p_helper_secret": helper_config.helper_secret,
                    "p_request_id": request_id,
                },
            )
        except Exception as exc:
            logger.warning("poll_permission_decision failed: %s", exc)
            _emit(adapter.emit_local_fallback(parsed, "Remote approval channel unavailable"))
            return 0

        if isinstance(result, dict):
            status = result.get("status")
            if status in ("approved", "denied"):
                decision_obj = result
                break
            if status in ("expired", "not_found"):
                logger.info("remote request %s ended early: %s", request_id, status)
                break
        sleep(cfg.poll_interval_s)

    if decision_obj is None:
        _emit(adapter.emit_local_fallback(parsed, "Remote approval timed out"))
        return 0

    from provider_adapters.base import AdapterDecision
    raw_decision = "approve" if decision_obj.get("status") == "approved" else "deny"
    raw_scope = str(decision_obj.get("scope") or "once")
    if raw_scope not in ("once", "alwaysSession"):
        raw_scope = "once"
    # Phase 1: silently downgrade alwaysSession (we don't emit permissionUpdates).
    scope = "once"
    decision = AdapterDecision(decision=raw_decision, scope=scope, reason="")
    _emit(adapter.emit_hook_output(decision, parsed))
    return 0


def _safe_parse(adapter: Any, raw: dict[str, Any], cwd_hmac: str | None) -> Any:
    """Run adapter.parse_hook_input with a defensive fallback on errors."""
    from provider_adapters.base import ParsedHookInput, AdapterRisk
    try:
        return adapter.parse_hook_input(raw, cwd_hmac)
    except NotImplementedError:
        raise
    except Exception as exc:  # pragma: no cover — last-resort safety net
        logger.warning("adapter.parse_hook_input failed: %s", exc)
        return ParsedHookInput(
            provider=getattr(adapter, "provider", ""),
            tool_name="Unknown",
            summary="(unparseable hook input)",
            payload={},
            risk=AdapterRisk.HIGH,
            cwd_basename="",
            cwd_hmac=cwd_hmac,
        )


def _coerce_uuid(value: str) -> str | None:
    """Return value if it parses as a uuid, else None.

    Claude's session_id IS already a uuid in the official hook contract, but we
    don't crash if a future provider emits something else.
    """
    if not value:
        return None
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError, TypeError):
        return None


def _resolve_managed_session_id(raw_session_id: str) -> str | None:
    """Pick the session_id we should attach to a permission request.

    iter 1 of Sessions Input introduced managed sessions: when the helper
    spawns the provider CLI itself, it sets `CLI_PULSE_REMOTE_SESSION_ID`
    on the child env so the hook can bind permission requests to the
    managed session instead of Claude's internal hook session_id. That
    binding is what lets the iOS/Mac Sessions UI inline-approve a
    pending request — the request's `session_id` is exactly the one
    the user has selected in the UI.

    Order of precedence:
      1. `CLI_PULSE_REMOTE_SESSION_ID` env var, if set AND a valid UUID.
      2. Hook input's `session_id` field, if a valid UUID.
      3. None — request is created unbound.

    SQL safety: even if a malformed env var somehow points at a session
    not owned by this device, `remote_helper_create_permission_request`
    in v0.27 / v0.30 zeroes out a mismatched session_id rather than
    raising, so the request is still produced (just unbound) and the
    user's hand-opened Terminal Claude flow still falls through to the
    standard pending-approvals sheet.
    """
    env_id = os.environ.get(REMOTE_SESSION_ID_ENV, "").strip()
    if env_id:
        validated = _coerce_uuid(env_id)
        if validated:
            return validated
    return _coerce_uuid(raw_session_id)


# ── local UDS fast path ──────────────────────────────────


# Env var names that wire the local approval surface. Mirrors the
# constants RemoteAgentManager._build_env emits — keep in sync. Read
# at request time so tests can monkeypatch via os.environ.
_LOCAL_SOCK_ENV = "CLI_PULSE_LOCAL_HELPER_SOCK"
_LOCAL_SESSION_ENV = "CLI_PULSE_LOCAL_SESSION_ID"
_LOCAL_TOKEN_ENV = "CLI_PULSE_LOCAL_HOOK_TOKEN"

# Hard caps mirroring local_session_server.MAX_PAYLOAD / framing.
_UDS_LENGTH_PREFIX = 4
_UDS_MAX_PAYLOAD = 1 << 20

# Connect / wait timeouts. Connect is short (helper is local); wait
# matches the hook's overall budget plus a small slack.
_UDS_CONNECT_TIMEOUT_S = 1.5
_UDS_REPLY_TIMEOUT_S = 5.0


def _try_local_uds_hook(parsed: Any, adapter: Any) -> Any | None:
    """Attempt to resolve this hook invocation through the same-Mac
    UDS approval surface. Returns an `AdapterDecision` if the local
    path resolved, None otherwise (caller falls through to Supabase).

    Failure modes that return None (caller falls through):
      - any of the env vars missing / empty
      - socket file missing (helper not running)
      - connect / read / write OSError
      - JSON decode error
      - helper rejected with `local_control_off` / `not_implemented` /
        `session_not_found` / `approval_capability_invalid`
      - decision was `expired` / `cancelled` / timed out

    Failure modes that DO resolve here:
      - decision was `approved` → AdapterDecision(approve, once)
      - decision was `rejected` → AdapterDecision(deny, once)
    """
    sock_path = os.environ.get(_LOCAL_SOCK_ENV) or ""
    session_id = os.environ.get(_LOCAL_SESSION_ENV) or ""
    session_token = os.environ.get(_LOCAL_TOKEN_ENV) or ""
    if not sock_path or not session_id or not session_token:
        return None

    # Lazy imports — keep run_hook's existing import-time surface tiny
    # so a corrupt local module doesn't break Supabase fallback.
    import socket
    import struct

    from provider_adapters.base import AdapterDecision

    if not os.path.exists(sock_path):
        logger.debug("local UDS hook: socket %s missing", sock_path)
        return None
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError as exc:
        logger.debug("local UDS hook: socket() failed: %s", exc)
        return None
    s.settimeout(_UDS_CONNECT_TIMEOUT_S)
    try:
        try:
            s.connect(sock_path)
        except OSError as exc:
            logger.debug("local UDS hook: connect failed: %s", exc)
            return None
        s.settimeout(_UDS_REPLY_TIMEOUT_S)

        def send_recv(envelope: dict[str, Any], timeout: float) -> dict[str, Any] | None:
            body = json.dumps(envelope).encode("utf-8")
            if len(body) > _UDS_MAX_PAYLOAD:
                return None
            try:
                s.sendall(struct.pack("!I", len(body)) + body)
            except OSError as exc:
                logger.debug("local UDS hook: send failed: %s", exc)
                return None
            s.settimeout(timeout)
            header = _recv_exact(s, _UDS_LENGTH_PREFIX)
            if header is None:
                return None
            (length,) = struct.unpack("!I", header)
            if length == 0 or length > _UDS_MAX_PAYLOAD:
                return None
            payload = _recv_exact(s, length)
            if payload is None:
                return None
            try:
                return json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                logger.debug("local UDS hook: bad reply json: %s", exc)
                return None

        # 1. hook_create_approval — registers the request and returns
        #    the helper-issued approval_id. Tool metadata reuses the
        #    redacted payload the parser already produced; no raw
        #    inputs ever cross this boundary.
        meta = dict(getattr(parsed, "payload", {}) or {})
        meta.setdefault("provider", getattr(parsed, "provider", "claude"))
        meta.setdefault("risk", getattr(parsed, "risk", "low"))
        if getattr(parsed, "cwd_basename", ""):
            meta.setdefault("cwd_basename", parsed.cwd_basename)
        create_envelope = {
            "id": str(uuid.uuid4()),
            "method": "hook_create_approval",
            "params": {
                "session_id": session_id,
                "session_token": session_token,
                "type": getattr(parsed, "tool_name", None) or "PermissionRequest",
                "title": getattr(parsed, "tool_name", None) or "PermissionRequest",
                "summary": getattr(parsed, "summary", "") or "",
                "tool_metadata": meta,
                "timeout_s": 60.0,
            },
        }
        create_reply = send_recv(create_envelope, _UDS_REPLY_TIMEOUT_S)
        if not isinstance(create_reply, dict) or not create_reply.get("ok"):
            if isinstance(create_reply, dict):
                err = create_reply.get("error") or {}
                logger.info(
                    "local UDS hook: create rejected code=%s",
                    (err.get("code") if isinstance(err, dict) else None),
                )
            return None
        approval_id = (
            (create_reply.get("result") or {}).get("approval_id")
            if isinstance(create_reply.get("result"), dict)
            else None
        )
        if not isinstance(approval_id, str) or not approval_id:
            return None

        # 2. hook_wait_decision — blocks until the user (or a TTL)
        #    resolves the approval. timeout aligns with the typical
        #    Claude tool-call grace (60 s) plus a connection slack.
        wait_envelope = {
            "id": str(uuid.uuid4()),
            "method": "hook_wait_decision",
            "params": {
                "session_id": session_id,
                "session_token": session_token,
                "approval_id": approval_id,
                "timeout_s": 60.0,
            },
        }
        wait_reply = send_recv(wait_envelope, 70.0)
        if not isinstance(wait_reply, dict) or not wait_reply.get("ok"):
            return None
        result = wait_reply.get("result")
        if not isinstance(result, dict):
            return None
        if result.get("timed_out"):
            return None
        status = result.get("status")
        if status == "approved":
            return AdapterDecision(decision="approve", scope="once", reason="")
        if status == "rejected":
            return AdapterDecision(decision="deny", scope="once", reason="")
        return None
    finally:
        try:
            s.close()
        except OSError:
            pass


def _recv_exact(s: Any, n: int) -> bytes | None:
    """Read exactly n bytes from the UDS socket. Returns the bytes or
    None on EOF / short read. Used by the local-UDS fast path; same
    semantics as `local_session_server._recv_exact` but inlined here
    so the hook doesn't import the server module.
    """
    if n <= 0:
        return b""
    buf = bytearray()
    while len(buf) < n:
        try:
            chunk = s.recv(n - len(buf))
        except OSError:
            return None
        if not chunk:
            return None
        buf.extend(chunk)
    return bytes(buf)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="CLI Pulse remote approval hook")
    parser.add_argument("--provider", required=True, choices=("claude", "codex", "shell"))
    parser.add_argument("--timeout", type=float, default=10.0,
                        help="Max seconds to wait for a remote decision (default 10)")
    parser.add_argument("--poll-interval", type=float, default=1.0,
                        help="Seconds between poll attempts (default 1)")
    parser.add_argument("--allow-high-risk", action="store_true",
                        help="Allow high-risk requests to round-trip remotely (default: fail closed)")
    args = parser.parse_args(argv)

    config = HookConfig(
        poll_interval_s=args.poll_interval,
        timeout_s=args.timeout,
        ttl_seconds=max(int(args.timeout) + 30, 60),
        fail_closed_on_high_risk=not args.allow_high_risk,
    )

    return run_hook(args.provider, config)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
