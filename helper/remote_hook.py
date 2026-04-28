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
import sys
import time
import uuid
from dataclasses import dataclass
from typing import Any

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
    '"message":"CLI Pulse remote-approval-hook crashed; please retry to '
    'invoke the local Claude permission prompt."}}}\n'
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
    session_uuid = _coerce_uuid(session_id_str)

    sleep = sleep_fn or time.sleep

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
