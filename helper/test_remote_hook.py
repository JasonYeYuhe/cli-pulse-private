"""Tests for the remote-approval hook and Claude adapter.

These tests exercise:
  - Claude adapter parses tool inputs into a redacted, length-bounded payload
  - Risk classifier flags rm -rf and sudo, leaves Read alone
  - Secrets in tool_input get «REDACTED»
  - run_hook timing-out emits a local-fallback `ask`
  - run_hook approve/deny round-trip emits the right Claude hook output
  - run_hook fail-closed shortcut on high-risk shell commands

No network, no real helper config — everything is injected through the
keyword arguments to run_hook.
"""
from __future__ import annotations

import io
import json
import sys
from pathlib import Path

import pytest

# Make `helper/` importable even when pytest is invoked from the repo root.
HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from provider_adapters import ClaudeAdapter, AdapterRisk, adapter_for  # noqa: E402
from provider_adapters.base import AdapterDecision  # noqa: E402
import remote_hook  # noqa: E402


class _StubHelperConfig:
    device_id = "11111111-1111-1111-1111-111111111111"
    helper_secret = "test-secret"


# ── Adapter unit tests ────────────────────────────────────────


def test_claude_parses_bash_command_with_summary_and_redaction():
    adapter = ClaudeAdapter()
    raw = {
        "tool_name": "Bash",
        "tool_input": {"command": "curl -H 'Authorization: Bearer sk-ant-abcd1234567890' https://example.com"},
        "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "cwd": "/Users/dev/projects/cool-app",
    }
    parsed = adapter.parse_hook_input(raw, cwd_hmac="abc123")
    assert parsed.tool_name == "Bash"
    assert parsed.summary.startswith("$ ")
    assert "sk-ant-abcd1234567890" not in parsed.summary
    assert "«REDACTED»" in parsed.summary
    assert "sk-ant-abcd1234567890" not in json.dumps(parsed.payload)
    # cwd is reduced to basename
    assert parsed.cwd_basename == "cool-app"
    assert parsed.cwd_hmac == "abc123"


def test_claude_classifies_rm_rf_as_high_risk():
    adapter = ClaudeAdapter()
    parsed = adapter.parse_hook_input(
        {"tool_name": "Bash", "tool_input": {"command": "rm -rf /tmp/foo && touch bar"}},
        cwd_hmac=None,
    )
    assert parsed.risk == AdapterRisk.HIGH


def test_claude_classifies_read_as_low_risk():
    adapter = ClaudeAdapter()
    parsed = adapter.parse_hook_input(
        {"tool_name": "Read", "tool_input": {"file_path": "/etc/hosts"}},
        cwd_hmac=None,
    )
    assert parsed.risk == AdapterRisk.LOW
    # File path becomes basename in the summary, never the full path.
    assert "hosts" in parsed.summary
    assert "/etc" not in parsed.summary


def test_claude_payload_truncates_long_string_inputs():
    adapter = ClaudeAdapter()
    big = "x" * 5000
    parsed = adapter.parse_hook_input(
        {"tool_name": "Bash", "tool_input": {"command": big}},
        cwd_hmac=None,
    )
    serialised = json.dumps(parsed.payload)
    # Sanity: original 5000-char string becomes ≤ 1024 in the payload.
    assert len(serialised) < 2000


def test_claude_emit_hook_output_shapes():
    # Per official Claude Code docs (verified 2026-04-28), PermissionRequest
    # only supports decision.behavior in {"allow", "deny"}. The `message`
    # field is "For deny only", so allow responses must NOT include it.
    # Fallback paths deny with an explanatory message — never emit "ask"
    # or any other undocumented value.
    adapter = ClaudeAdapter()
    parsed = adapter.parse_hook_input(
        {"tool_name": "Read", "tool_input": {"file_path": "/etc/hosts"}},
        cwd_hmac=None,
    )
    allow_out = adapter.emit_hook_output(AdapterDecision(decision="approve"), parsed)
    deny_out = adapter.emit_hook_output(AdapterDecision(decision="deny"), parsed)
    fallback_out = adapter.emit_hook_output(AdapterDecision(decision="fallback"), parsed)

    for out in (allow_out, deny_out, fallback_out):
        assert "hookSpecificOutput" in out
        # We never emit permissionUpdates in Phase 1.
        assert "permissionUpdates" not in out["hookSpecificOutput"]
        # behavior must be one of the two officially documented values.
        assert out["hookSpecificOutput"]["decision"]["behavior"] in ("allow", "deny")

    # Allow shape: behavior only, no message field (docs: "For deny only").
    allow_decision = allow_out["hookSpecificOutput"]["decision"]
    assert allow_decision == {"behavior": "allow"}, (
        f"allow output must contain only behavior; got {allow_decision!r}"
    )

    # Deny shape: behavior + non-empty message.
    deny_decision = deny_out["hookSpecificOutput"]["decision"]
    assert deny_decision["behavior"] == "deny"
    assert isinstance(deny_decision.get("message"), str) and len(deny_decision["message"]) > 0

    # Fallback shape: same as deny — non-empty message pointing the user at
    # the local prompt. Pinning the dict shape catches any regression that
    # adds undocumented keys.
    fallback_decision = fallback_out["hookSpecificOutput"]["decision"]
    assert fallback_decision["behavior"] == "deny"
    assert isinstance(fallback_decision.get("message"), str) and len(fallback_decision["message"]) > 0
    # Only behavior + message in the dict — nothing else (no "ask", no
    # permissionUpdates, no scope, no permissionDecision).
    assert set(fallback_decision.keys()) == {"behavior", "message"}


def test_hmac_path_accepts_user_secret_bytes():
    digest = remote_hook._hmac_path(b"\x42" * 32, "/Users/dev/projects/cool-app")
    assert isinstance(digest, str)
    assert len(digest) == 64


def test_adapter_for_unknown_provider_raises():
    with pytest.raises(ValueError):
        adapter_for("definitely-not-a-provider")


# ── run_hook integration (with fake RPC) ──────────────────────


def _capture_stdout(monkeypatch):
    buf = io.StringIO()
    monkeypatch.setattr(sys, "stdout", buf)
    return buf


def test_run_hook_high_risk_short_circuits_to_local_fallback(monkeypatch):
    buf = _capture_stdout(monkeypatch)
    rpc_called = []

    def fake_rpc(name, params, **_kwargs):
        rpc_called.append(name)
        return {}

    payload = {
        "tool_name": "Bash",
        "tool_input": {"command": "sudo rm -rf /"},
        "cwd": "/Users/dev/x",
    }
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.1, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    # No RPC calls made because we short-circuited before the network round-trip.
    assert rpc_called == []
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert out["hookSpecificOutput"]["decision"]["message"]


def test_run_hook_timeout_emits_fallback(monkeypatch):
    buf = _capture_stdout(monkeypatch)
    rpc_calls = []

    def fake_rpc(name, params, **_kwargs):
        rpc_calls.append(name)
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "pending"}
        return {}

    payload = {
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
        "cwd": "/Users/dev/x",
    }
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert "remote_helper_create_permission_request" in rpc_calls
    assert "remote_helper_poll_permission_decision" in rpc_calls
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert out["hookSpecificOutput"]["decision"]["message"]


def test_run_hook_approve_round_trip(monkeypatch):
    buf = _capture_stdout(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "approved", "decision": "approve", "scope": "once"}
        return {}

    payload = {
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
        "cwd": "/Users/dev/x",
    }
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    decision = out["hookSpecificOutput"]["decision"]
    assert decision["behavior"] == "allow"
    # Allow responses must not carry a `message` (docs: "For deny only").
    assert "message" not in decision, (
        f"allow output leaked a message field: {decision!r}"
    )


def test_run_hook_deny_round_trip(monkeypatch):
    buf = _capture_stdout(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "denied", "decision": "deny", "scope": "once"}
        return {}

    payload = {
        "tool_name": "Edit",
        "tool_input": {"file_path": "/Users/dev/x/foo.py", "old_string": "a", "new_string": "b"},
        "cwd": "/Users/dev/x",
    }
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    decision = out["hookSpecificOutput"]["decision"]
    assert decision["behavior"] == "deny"
    # Deny responses include a non-empty message.
    assert isinstance(decision.get("message"), str) and len(decision["message"]) > 0


def test_run_hook_create_failure_falls_back(monkeypatch):
    buf = _capture_stdout(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            raise RuntimeError("network down")
        return {}

    payload = {
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
        "cwd": "/Users/dev/x",
    }
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert out["hookSpecificOutput"]["decision"]["message"]


def test_run_hook_codex_provider_emits_raw_deny_fallback(monkeypatch):
    # Codex adapter is a Phase 2 stub: parse_hook_input raises
    # NotImplementedError. The TOP-LEVEL run_hook wrapper must catch that and
    # emit a hardcoded JSON deny to stdout — leaving stdout empty would let
    # Claude/Codex hang opaquely (Gemini 3.1 Pro review P0 #2).
    # Per official docs, PermissionRequest only supports "allow" / "deny" so
    # the raw fallback is deny+message, not "ask".
    buf = _capture_stdout(monkeypatch)
    rc = remote_hook.run_hook(
        "codex",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload={"tool_name": "Bash", "tool_input": {"command": "ls"}},
        helper_config=_StubHelperConfig(),
        rpc_caller=lambda _n, _p: {},
        user_secret_loader=lambda: "x",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert out["hookSpecificOutput"]["decision"]["message"]


def test_run_hook_unexpected_crash_emits_raw_deny_fallback(monkeypatch):
    # If anything unrelated to the adapter crashes mid-run (e.g. RPC layer
    # raises a non-Exception subclass, helper config attr missing, etc.) the
    # top-level wrapper should still leave stdout in a parseable state so
    # Claude doesn't hang. Simulate by passing a helper_config that crashes
    # on attribute access — that path runs after the high-risk shortcut.
    buf = _capture_stdout(monkeypatch)

    class _BoomConfig:
        @property
        def device_id(self):
            raise RuntimeError("device_id property exploded")
        helper_secret = "x"

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload={
            "tool_name": "Read",
            "tool_input": {"file_path": "/etc/hosts"},
            "cwd": "/Users/dev/x",
        },
        helper_config=_BoomConfig(),
        rpc_caller=lambda _n, _p: {},
        user_secret_loader=lambda: "x",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    payload = buf.getvalue()
    assert payload, "stdout must not be empty even on crash"
    out = json.loads(payload)
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert out["hookSpecificOutput"]["decision"]["message"]


def test_claude_redacts_jwt_token():
    # Gemini review P1 #4: a Supabase / Auth0 / GCP JWT pasted into a Bash
    # tool_input must be «REDACTED» in BOTH summary and payload, not uploaded
    # raw. Verifies neither rendering path (UI string and JSON-encoded payload)
    # leaks the token.
    adapter = ClaudeAdapter()
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJqYXNvbiJ9.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9FYR50DAHKxBg"
    parsed = adapter.parse_hook_input(
        {"tool_name": "Bash", "tool_input": {"command": f"curl -H 'Authorization: Bearer {jwt}' https://x"}},
        cwd_hmac=None,
    )
    # Surfaces:
    #   1. summary: a plain string shown directly in the UI.
    #   2. payload: a Python dict that the helper RPC layer json.dumps()'es.
    # Both must be free of the raw token. We check the payload via its raw
    # string values rather than json.dumps() output because the latter
    # escapes the «» characters of the redaction marker into «/»,
    # which would falsely look like a missing redaction.
    assert jwt not in parsed.summary, "JWT leaked into summary"
    raw_payload_string = json.dumps(parsed.payload, ensure_ascii=False)
    assert jwt not in raw_payload_string, "JWT leaked into payload"
    # And we must visibly redact rather than silently drop, so a reviewer
    # can tell from the upload that something was scrubbed.
    assert "«REDACTED»" in parsed.summary
    # Walk the payload values directly so the marker is checked in raw
    # Python strings, not JSON-encoded ones.
    flat_values = " ".join(
        str(v) for v in parsed.payload.get("tool_input", {}).values()
    )
    assert "«REDACTED»" in flat_values


def test_resolve_managed_session_prefers_env_var_when_valid_uuid(monkeypatch):
    # iter 1 of Sessions Input: helper-spawned managed Claude sessions
    # set CLI_PULSE_REMOTE_SESSION_ID on the child env so the hook can
    # bind permission requests to the managed session id (visible in the
    # iOS / Mac Sessions UI) instead of Claude's internal hook session_id.
    env_id = "12345678-1234-1234-1234-123456789abc"
    raw_id = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    monkeypatch.setenv(remote_hook.REMOTE_SESSION_ID_ENV, env_id)
    resolved = remote_hook._resolve_managed_session_id(raw_id)
    assert resolved == str(__import__("uuid").UUID(env_id))


def test_resolve_managed_session_falls_back_when_env_var_invalid(monkeypatch):
    # A malformed env var must not corrupt the binding — fall through to
    # the hook's own session_id rather than dropping the request.
    raw_id = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    monkeypatch.setenv(remote_hook.REMOTE_SESSION_ID_ENV, "not-a-uuid")
    resolved = remote_hook._resolve_managed_session_id(raw_id)
    assert resolved == str(__import__("uuid").UUID(raw_id))


def test_resolve_managed_session_uses_raw_when_env_unset(monkeypatch):
    raw_id = "f47ac10b-58cc-4372-a567-0e02b2c3d479"
    monkeypatch.delenv(remote_hook.REMOTE_SESSION_ID_ENV, raising=False)
    resolved = remote_hook._resolve_managed_session_id(raw_id)
    assert resolved == str(__import__("uuid").UUID(raw_id))


def test_resolve_managed_session_returns_none_when_both_invalid(monkeypatch):
    monkeypatch.setenv(remote_hook.REMOTE_SESSION_ID_ENV, "")
    resolved = remote_hook._resolve_managed_session_id("")
    assert resolved is None


def test_run_hook_uses_env_session_id_in_create_request(monkeypatch):
    # Integration check: when CLI_PULSE_REMOTE_SESSION_ID is set, the
    # hook must pass that uuid as p_session_id to the create request,
    # not the raw session_id from Claude's input. This is what actually
    # binds an inline approve to the selected managed session.
    monkeypatch.setattr(sys, "stdout", io.StringIO())
    env_id = "abcdef01-2345-6789-abcd-ef0123456789"
    monkeypatch.setenv(remote_hook.REMOTE_SESSION_ID_ENV, env_id)
    captured: dict[str, object] = {}

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            captured.update(params)
            return {"request_id": params["p_request_id"], "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "approved", "decision": "approve", "scope": "once"}
        return {}

    payload = {
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
        "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
        "cwd": "/Users/dev/x",
    }
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "x",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert captured.get("p_session_id") == str(__import__("uuid").UUID(env_id)), (
        f"expected p_session_id={env_id}, got {captured.get('p_session_id')!r}"
    )


def test_claude_redaction_does_not_corrupt_ordinary_short_commands():
    # Belt-and-braces: regression-guard against an over-eager redactor
    # eating ordinary short / non-secret commands. We've previously
    # considered (and rejected) a generic \b[A-Za-z0-9+/=]{40,}\b base64
    # rule that would mangle long file paths.
    adapter = ClaudeAdapter()
    cases = [
        "ls -la",
        "echo hello world",
        "git status",
        "python3 helper/cli_pulse_helper.py inspect",
        "cd /Users/dev/projects/cool-app && npm test",
    ]
    for cmd in cases:
        parsed = adapter.parse_hook_input(
            {"tool_name": "Bash", "tool_input": {"command": cmd}},
            cwd_hmac=None,
        )
        assert "«REDACTED»" not in parsed.summary, f"false-positive redaction: {cmd!r}"
        assert "«REDACTED»" not in json.dumps(parsed.payload), f"false-positive redaction: {cmd!r}"


# ── M2: per-request HTTP timeout (cross-team backport, 2026-05-07) ──
#
# `helper/cli_pulse_helper.py::supabase_rpc` accepts a `timeout` kwarg
# and forwards it to `urllib.request.urlopen`. The remote-approval hook
# passes `cfg.request_timeout_s` (default 2.5s) on every Supabase call so
# a single hung RPC can't burn the whole `cfg.timeout_s` (10s) budget.
# Mirrors cli-pulse-desktop v0.7.0's `tokio::time::timeout(2.5s)` per-call
# ceiling; same semantics, same value.


def test_supabase_rpc_passes_timeout_kwarg_to_urlopen(monkeypatch):
    # Verify the new `timeout` kwarg on supabase_rpc actually reaches
    # urllib's urlopen (since that's what gives us the cap on a stuck
    # request). Mock urlopen to capture the kwarg without touching the
    # network.
    import cli_pulse_helper

    captured: dict[str, object] = {}

    class _FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b'{"ok": true}'

    def fake_urlopen(req, timeout=None):
        captured["timeout"] = timeout
        return _FakeResp()

    monkeypatch.setattr(cli_pulse_helper, "SUPABASE_URL", "https://example.test")
    monkeypatch.setattr(cli_pulse_helper, "SUPABASE_ANON_KEY", "anon-key")
    monkeypatch.setattr(cli_pulse_helper.urllib.request, "urlopen", fake_urlopen)

    cli_pulse_helper.supabase_rpc("noop", {}, timeout=2.5)
    assert captured["timeout"] == 2.5

    cli_pulse_helper.supabase_rpc("noop", {}, timeout=0.5)
    assert captured["timeout"] == 0.5


def test_supabase_rpc_default_timeout_is_30s(monkeypatch):
    # The 30s default preserves the historical behaviour for daemon
    # bulk-sync callers (commits, sessions, alerts). Only tight-polling
    # callers like the hook opt into a shorter ceiling.
    import cli_pulse_helper

    captured: dict[str, object] = {}

    class _FakeResp:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def read(self): return b'{}'

    def fake_urlopen(req, timeout=None):
        captured["timeout"] = timeout
        return _FakeResp()

    monkeypatch.setattr(cli_pulse_helper, "SUPABASE_URL", "https://example.test")
    monkeypatch.setattr(cli_pulse_helper, "SUPABASE_ANON_KEY", "anon-key")
    monkeypatch.setattr(cli_pulse_helper.urllib.request, "urlopen", fake_urlopen)

    cli_pulse_helper.supabase_rpc("noop", {})  # no timeout kwarg
    assert captured["timeout"] == 30.0


def test_run_hook_create_passes_request_timeout_to_rpc(monkeypatch):
    # The create call should carry `timeout=cfg.request_timeout_s`. We
    # capture every kwargs dict the fake_rpc sees and assert the create
    # request specifically has timeout=2.5 (default).
    captured_kwargs: list[dict[str, object]] = []

    def fake_rpc(name, params, **kwargs):
        captured_kwargs.append({"name": name, **kwargs})
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "approved", "decision": "approve", "scope": "once"}
        return {}

    payload = {
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
        "cwd": "/Users/dev/x",
    }
    _capture_stdout(monkeypatch)
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    create_calls = [c for c in captured_kwargs if c["name"] == "remote_helper_create_permission_request"]
    poll_calls = [c for c in captured_kwargs if c["name"] == "remote_helper_poll_permission_decision"]
    assert create_calls, "create RPC was not called"
    assert poll_calls, "poll RPC was not called"
    # Default request_timeout_s is 2.5s; both create and poll carry it.
    assert all(c.get("timeout") == 2.5 for c in create_calls), create_calls
    assert all(c.get("timeout") == 2.5 for c in poll_calls), poll_calls


def test_run_hook_request_timeout_is_configurable(monkeypatch):
    # A non-default request_timeout_s threads through to the RPC call.
    # Useful for environments with tight network budgets (or tests that
    # want to exercise the timeout path quickly).
    captured_kwargs: list[dict[str, object]] = []

    def fake_rpc(name, params, **kwargs):
        captured_kwargs.append({"name": name, **kwargs})
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "approved", "decision": "approve", "scope": "once"}
        return {}

    payload = {
        "tool_name": "Read",
        "tool_input": {"file_path": "/etc/hosts"},
        "cwd": "/Users/dev/x",
    }
    _capture_stdout(monkeypatch)
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(
            timeout_s=1.0,
            poll_interval_s=0.01,
            request_timeout_s=0.75,
        ),
        stdin_payload=payload,
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert all(c.get("timeout") == 0.75 for c in captured_kwargs), captured_kwargs


def test_main_cli_request_timeout_arg_threads_through(monkeypatch):
    # `--request-timeout` on the CLI should populate the HookConfig, so
    # an operator (or a future managed-session install) can override the
    # default per-deployment without code changes.
    seen_config: dict[str, object] = {}

    def fake_run_hook(provider, config, **_kwargs):
        seen_config["request_timeout_s"] = config.request_timeout_s
        seen_config["timeout_s"] = config.timeout_s
        return 0

    monkeypatch.setattr(remote_hook, "run_hook", fake_run_hook)
    rc = remote_hook.main([
        "--provider", "claude",
        "--timeout", "8",
        "--request-timeout", "1.25",
    ])
    assert rc == 0
    assert seen_config["request_timeout_s"] == 1.25
    assert seen_config["timeout_s"] == 8.0


# ── M3: token-level high-risk Bash classifier (cross-team backport) ──
#
# Mirrors cli-pulse-desktop v0.7.0 `risk.rs::is_high_risk_bash`. The
# previous Mac classifier used `"rm -rf" in cmd` substring matching,
# which silently failed on whitespace-perturbed forms. The new
# classifier is whitespace-tolerant by construction (`command.split()`
# collapses any run of whitespace) and uses exact-token equality for
# single-word dangers so substring-style false positives like
# `sudoer-config-tool` no longer trip HIGH.


def _bash_risk(cmd: str) -> str:
    parsed = ClaudeAdapter().parse_hook_input(
        {"tool_name": "Bash", "tool_input": {"command": cmd}},
        cwd_hmac=None,
    )
    return parsed.risk


@pytest.mark.parametrize(
    "cmd",
    [
        "rm -rf /tmp/junk",     # canonical -rf
        "rm -fr /var/log",      # -fr
        "rm  -rf /tmp/junk",    # double space (the v0.7.0 P1 bug)
        "rm\t-rf\t/tmp",        # tab
        "rm -r -f /tmp/junk",   # split flags
        "rm -rfv /tmp",         # extra verbose flag
        "  rm -rf /",           # leading whitespace
        "rm -r --force ./build",  # long-form --force counts (contains 'f')
    ],
)
def test_classify_rm_with_destructive_flags_is_high(cmd):
    assert _bash_risk(cmd) == AdapterRisk.HIGH, f"expected HIGH for {cmd!r}"


@pytest.mark.parametrize(
    "cmd",
    [
        "rm file.txt",        # no -r or -f
        "rm -i file.txt",     # interactive flag — recoverable
        "rm -v file.txt",     # verbose only
    ],
)
def test_classify_rm_without_destructive_flags_is_medium(cmd):
    assert _bash_risk(cmd) == AdapterRisk.MEDIUM, f"expected MEDIUM for {cmd!r}"


@pytest.mark.parametrize(
    "cmd",
    [
        "sudo apt-get install",
        "find . -type f | sudo cat",   # trailing sudo
        "mkfs.ext4 /dev/sda1",          # mkfs base — not exact tok match, but mkfs.ext4 IS the token
    ],
)
def test_classify_sudo_mkfs_token_high(cmd):
    # `sudo` and `mkfs` (bare) are danger tokens. `mkfs.ext4` is a
    # different token — confirm baseline `mkfs` matches the bare form
    # only. (The .ext4 / .vfat / etc. variants are not classified HIGH
    # — this matches Windows risk.rs and is intentional: real-world
    # provisioning scripts use the suffixed form intentionally; the
    # bare `mkfs` is the sledgehammer.)
    if "mkfs.ext4" in cmd:
        # Confirm the suffixed variant slips through as MEDIUM (drift
        # from Windows would surface here).
        assert _bash_risk(cmd) == AdapterRisk.MEDIUM
    else:
        assert _bash_risk(cmd) == AdapterRisk.HIGH


@pytest.mark.parametrize("cmd", ["curl https://x", "wget http://example.com/file"])
def test_classify_curl_wget_is_high(cmd):
    assert _bash_risk(cmd) == AdapterRisk.HIGH


@pytest.mark.parametrize(
    "cmd",
    ["ssh user@host", "scp ./file user@host:/tmp", "rsync -av ./ remote:/dest"],
)
def test_classify_remote_transfer_tokens_high(cmd):
    assert _bash_risk(cmd) == AdapterRisk.HIGH


def test_classify_chmod_777_root_is_high():
    assert _bash_risk("chmod 777 / -R") == AdapterRisk.HIGH


def test_classify_chmod_777_local_path_is_medium():
    # Setting permissive perms on a project file isn't world-ending.
    # Matches Windows risk.rs.
    assert _bash_risk("chmod 777 ./file.sh") == AdapterRisk.MEDIUM


def test_classify_fork_bomb_is_high():
    assert _bash_risk(" :(){ :|:& };:") == AdapterRisk.HIGH


def test_classify_history_clear_is_high():
    assert _bash_risk("history -c") == AdapterRisk.HIGH


def test_classify_kextload_csrutil_high():
    assert _bash_risk("kextload my.kext") == AdapterRisk.HIGH
    assert _bash_risk("csrutil disable") == AdapterRisk.HIGH


@pytest.mark.parametrize(
    "cmd",
    [
        "./sudoer-config-tool --validate",  # NOT sudo (substring would FP)
        "./forecast-curl-stats",            # NOT curl
        "ssh-keygen -l -f ~/.ssh/id_rsa",   # NOT ssh — the binary is ssh-keygen
        "less /var/log/messages",           # contains 'sudo' nowhere; harmless
        "pip install requests",             # 'requests' is a project name
    ],
)
def test_classify_token_names_dont_substring_false_positive(cmd):
    assert _bash_risk(cmd) == AdapterRisk.MEDIUM, f"false HIGH for {cmd!r}"


def test_classify_dd_only_high_with_if_flag():
    # bare `dd` is dangerous with `if=`; without it `dd` could be a
    # filename or an unrelated command. Avoids false-positive on
    # `cd dd-folder/`.
    assert _bash_risk("dd if=/dev/zero of=/tmp/file") == AdapterRisk.HIGH
    assert _bash_risk("ls dd-folder/") == AdapterRisk.MEDIUM
    assert _bash_risk("dd") == AdapterRisk.MEDIUM   # bare dd, no if= — safe


def test_classify_low_risk_tools_unchanged():
    # The token-level rewrite only changed the Bash branch; LOW for
    # read-only tools must still hold (regression guard).
    for tool in ("Read", "Glob", "Grep", "WebFetch", "WebSearch", "TodoRead"):
        parsed = ClaudeAdapter().parse_hook_input(
            {"tool_name": tool, "tool_input": {}},
            cwd_hmac=None,
        )
        assert parsed.risk == AdapterRisk.LOW, f"tool {tool!r} should be LOW"


def test_classify_unknown_tool_is_medium():
    parsed = ClaudeAdapter().parse_hook_input(
        {"tool_name": "MyMcpTool", "tool_input": {}},
        cwd_hmac=None,
    )
    assert parsed.risk == AdapterRisk.MEDIUM


def test_classify_bash_with_no_command_field_is_medium():
    # Missing or non-string command — graceful degrade to medium.
    for tool_input in ({}, {"command": None}, {"command": 42}, {"command": ""}):
        parsed = ClaudeAdapter().parse_hook_input(
            {"tool_name": "Bash", "tool_input": tool_input},
            cwd_hmac=None,
        )
        assert parsed.risk == AdapterRisk.MEDIUM, f"input {tool_input!r} → {parsed.risk}"
