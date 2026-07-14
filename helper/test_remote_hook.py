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
import swarm  # noqa: E402


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


def test_claude_webfetch_strips_url_credentials_from_summary_and_payload():
    """Audit F7: a signed / credential-bearing WebFetch URL must not leave the
    device — neither in the remote-visible summary nor the uploaded payload
    (the key-name redactor alone misses userinfo, ?token=, and OAuth ?code=)."""
    adapter = ClaudeAdapter()
    cases = [
        ("https://api.example.com/d?access_token=sk-secret-abc123&x=1", "sk-secret-abc123"),
        ("https://user:p4ssw0rd@host.example.com/path", "p4ssw0rd"),
        ("https://cb.example.com/callback?code=oauth_secret_xyz", "oauth_secret_xyz"),
    ]
    for url, secret in cases:
        parsed = adapter.parse_hook_input(
            {"tool_name": "WebFetch", "tool_input": {"url": url},
             "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479"},
            cwd_hmac=None,
        )
        assert secret not in parsed.summary, (url, parsed.summary)
        assert secret not in json.dumps(parsed.payload), (url, parsed.payload)
    # A plain WebSearch query (not a URL) is preserved intact.
    parsed = adapter.parse_hook_input(
        {"tool_name": "WebSearch", "tool_input": {"query": "how to center a div"}}, cwd_hmac=None)
    assert "center a div" in parsed.summary


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


def _mark_managed(monkeypatch):
    """Simulate a CLI-Pulse-SPAWNED (managed) session by setting the session
    env the helper injects on spawn. Managed sessions fail CLOSED (deny) when
    the remote channel is unavailable; EXTERNAL sessions (no env) fail OPEN
    (M1). Setting only the session id (not sock/token) leaves the UDS fast-path
    inert — it needs all three — so the Supabase path still runs."""
    monkeypatch.setenv("CLI_PULSE_LOCAL_SESSION_ID", "managed-session-1")


def _mark_external(monkeypatch):
    """Simulate a hand-launched (external) terminal Claude — none of the
    managed session env vars are set, so the hook fails OPEN."""
    for var in ("CLI_PULSE_REMOTE_SESSION_ID", "CLI_PULSE_LOCAL_SESSION_ID",
                "CLI_PULSE_LOCAL_HELPER_SOCK", "CLI_PULSE_LOCAL_HOOK_TOKEN"):
        monkeypatch.delenv(var, raising=False)


# ── Iter 2B: local-first hook + fallback policy ──────────────


def test_local_first_envvars_unset_bypasses_local_path(monkeypatch):
    """Without the three CLI_PULSE_LOCAL_* env vars set, the local
    UDS path is a no-op and the hook proceeds straight to Supabase.
    """
    for var in (
        "CLI_PULSE_LOCAL_HELPER_SOCK",
        "CLI_PULSE_LOCAL_SESSION_ID",
        "CLI_PULSE_LOCAL_HOOK_TOKEN",
    ):
        monkeypatch.delenv(var, raising=False)
    parsed_obj = type("P", (), {})()
    parsed_obj.payload = {}
    parsed_obj.provider = "claude"
    parsed_obj.risk = "low"
    parsed_obj.cwd_basename = ""
    parsed_obj.tool_name = "Read"
    parsed_obj.summary = ""
    out = remote_hook._try_local_uds_hook(parsed_obj, ClaudeAdapter())
    assert out is None


def test_local_first_helper_unreachable_falls_through_to_supabase(monkeypatch, tmp_path):
    """Connection-time failure (socket file missing) returns None so
    the caller falls through to Supabase. This is the ONLY path the
    function returns None — once create_pending succeeds it must
    return AdapterDecision or the local-fallback sentinel.
    """
    sock = tmp_path / "definitely-not-bound.sock"
    monkeypatch.setenv("CLI_PULSE_LOCAL_HELPER_SOCK", str(sock))
    monkeypatch.setenv("CLI_PULSE_LOCAL_SESSION_ID", "11111111-1111-1111-1111-111111111111")
    monkeypatch.setenv("CLI_PULSE_LOCAL_HOOK_TOKEN", "deadbeef")
    parsed_obj = type("P", (), {})()
    parsed_obj.payload = {}
    parsed_obj.provider = "claude"
    parsed_obj.risk = "low"
    parsed_obj.cwd_basename = ""
    parsed_obj.tool_name = "Read"
    parsed_obj.summary = ""
    out = remote_hook._try_local_uds_hook(parsed_obj, ClaudeAdapter())
    assert out is None


def test_local_first_resolved_local_fallback_emits_local_not_supabase(monkeypatch):
    """When `_try_local_uds_hook` returns the local-fallback sentinel
    (pending row was created but didn't resolve to approve/reject),
    `run_hook` must emit `adapter.emit_local_fallback` and NOT call
    any Supabase RPC. Otherwise the iPhone gets a duplicate pending
    request after the user already saw the local one.
    """
    buf = _capture_stdout(monkeypatch)
    _mark_managed(monkeypatch)  # local-UDS sentinel path is inherently managed
    monkeypatch.setattr(
        remote_hook, "_try_local_uds_hook",
        lambda *args, **kwargs: remote_hook._LOCAL_FALLBACK_SENTINEL,
    )
    rpc_calls = []

    def fake_rpc(name, _params, **_kwargs):
        rpc_calls.append(name)
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
    # Critical: no Supabase RPC was issued. The local fallback
    # path is authoritative once the pending row was created.
    assert rpc_calls == []
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
    assert "Local approval did not resolve" in out["hookSpecificOutput"]["decision"]["message"]


def test_local_first_approve_skips_supabase(monkeypatch):
    """An AdapterDecision returned from the local UDS path is emitted
    directly; Supabase is never touched.
    """
    buf = _capture_stdout(monkeypatch)
    monkeypatch.setattr(
        remote_hook, "_try_local_uds_hook",
        lambda *args, **kwargs: AdapterDecision(decision="approve", scope="once", reason=""),
    )
    rpc_calls = []
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload={
            "tool_name": "Read",
            "tool_input": {"file_path": "/etc/hosts"},
            "cwd": "/Users/dev/x",
        },
        helper_config=_StubHelperConfig(),
        rpc_caller=lambda name, _params: rpc_calls.append(name) or {},
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert rpc_calls == []
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "allow"


def test_local_first_none_falls_through_to_supabase(monkeypatch):
    """When the local UDS path returns None (helper down / not
    started locally), run_hook falls through to Supabase exactly as
    the iter-2A behaviour did.
    """
    buf = _capture_stdout(monkeypatch)
    monkeypatch.setattr(
        remote_hook, "_try_local_uds_hook",
        lambda *args, **kwargs: None,
    )
    rpc_calls = []

    def fake_rpc(name, _params, **_kwargs):
        rpc_calls.append(name)
        if name == "remote_helper_create_permission_request":
            return {"request_id": "x", "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "approved", "decision": "approve", "scope": "once"}
        return {}

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload={
            "tool_name": "Read",
            "tool_input": {"file_path": "/etc/hosts"},
            "cwd": "/Users/dev/x",
        },
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert "remote_helper_create_permission_request" in rpc_calls
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "allow"


def test_run_hook_high_risk_short_circuits_to_local_fallback(monkeypatch):
    buf = _capture_stdout(monkeypatch)
    _mark_managed(monkeypatch)  # managed session → high-risk fails CLOSED (deny)
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
    _mark_managed(monkeypatch)  # managed session → timeout fails CLOSED (deny)
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
    _mark_managed(monkeypatch)  # managed session → create failure fails CLOSED

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
    _mark_managed(monkeypatch)  # managed session → mid-run crash fails CLOSED

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


# ── v1.22.0 Swarm dark-gate + _swarm_mark lifecycle (S1) ──────
# Ship-critical: the entire v1.22.0 release rests on swarm_enabled
# defaulting False. The hook-side gate was previously untested.


class _SwarmCfg:
    """Helper config with the swarm gate explicitly enabled."""
    device_id = "11111111-1111-1111-1111-111111111111"
    helper_secret = "acct-secret"
    swarm_enabled = True


def _capture_swarm_marks(monkeypatch):
    marks = []

    def _fake_record(self, swarm_key, *, status="running", **_kw):
        marks.append(status)

    monkeypatch.setattr(swarm.SwarmStore, "record_activity", _fake_record)
    return marks


def test_swarm_dark_gate_false_never_touches_swarmstore(monkeypatch):
    """swarm_enabled absent/False ⇒ remote_hook must NOT resolve a
    worktree or write SwarmStore, even on a code path that calls
    _swarm_mark("running") (local-approve). This is the dark-launch
    invariant the whole v1.22.0 ship depends on."""
    buf = _capture_stdout(monkeypatch)
    resolved = []
    monkeypatch.setattr(
        swarm, "resolve_worktree",
        lambda *a, **k: resolved.append(1) or None,
    )
    marks = _capture_swarm_marks(monkeypatch)
    monkeypatch.setattr(
        remote_hook, "_try_local_uds_hook",
        lambda *a, **k: AdapterDecision(decision="approve", scope="once", reason=""),
    )
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload={"tool_name": "Read",
                       "tool_input": {"file_path": "/etc/hosts"},
                       "cwd": "/Users/dev/x"},
        helper_config=_StubHelperConfig(),  # no swarm_enabled attr → False
        rpc_caller=lambda name, _p, **_k: {},
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert resolved == []          # gate skipped worktree resolution
    assert marks == []             # zero SwarmStore writes
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "allow"


def test_swarm_mark_awaiting_on_ingress_when_enabled(monkeypatch):
    """swarm_enabled=True ⇒ hook ingress marks the swarm
    'awaiting-approval' (it just hit an approval gate), independent of
    how the approval later resolves (here: times out)."""
    _capture_stdout(monkeypatch)
    monkeypatch.setattr(
        swarm, "resolve_worktree",
        lambda *a, **k: swarm.WorktreeInfo(
            main_repo="/r", branch="main", is_linked_worktree=False),
    )
    marks = _capture_swarm_marks(monkeypatch)
    monkeypatch.setattr(remote_hook, "_try_local_uds_hook", lambda *a, **k: None)
    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.02, poll_interval_s=0.01),
        stdin_payload={"tool_name": "Read",
                       "tool_input": {"file_path": "/etc/hosts"},
                       "cwd": "/Users/dev/x"},
        helper_config=_SwarmCfg(),
        rpc_caller=lambda name, _p, **_k: {},   # never resolves → timeout
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert marks == ["awaiting-approval"]


def test_swarm_mark_running_after_remote_approval(monkeypatch):
    """Full S1 lifecycle: 'awaiting-approval' on ingress, then
    'running' once the remote approval resolves (remote_hook:398)."""
    _capture_stdout(monkeypatch)
    monkeypatch.setattr(
        swarm, "resolve_worktree",
        lambda *a, **k: swarm.WorktreeInfo(
            main_repo="/r", branch="main", is_linked_worktree=False),
    )
    marks = _capture_swarm_marks(monkeypatch)
    monkeypatch.setattr(remote_hook, "_try_local_uds_hook", lambda *a, **k: None)

    def fake_rpc(name, _p, **_k):
        if name == "remote_helper_create_permission_request":
            return {"request_id": "x", "status": "pending"}
        if name == "remote_helper_poll_permission_decision":
            return {"status": "approved", "decision": "approve", "scope": "once"}
        return {}

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload={"tool_name": "Read",
                       "tool_input": {"file_path": "/etc/hosts"},
                       "cwd": "/Users/dev/x"},
        helper_config=_SwarmCfg(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert marks == ["awaiting-approval", "running"]


# ── M1: PreToolUse event shape + external fail-open vs managed fail-closed ──

def _ptu(**over):
    p = {"tool_name": "Read", "tool_input": {"file_path": "/etc/hosts"},
         "cwd": "/Users/dev/x", "hook_event_name": "PreToolUse"}
    p.update(over)
    return p


def test_adapter_parses_pretooluse_event_name():
    parsed = ClaudeAdapter().parse_hook_input(_ptu(), cwd_hmac=None)
    assert parsed.event_name == "PreToolUse"


def test_adapter_defaults_to_permission_request_without_event_name():
    raw = {"tool_name": "Read", "tool_input": {}, "cwd": "/x"}  # no hook_event_name
    parsed = ClaudeAdapter().parse_hook_input(raw, cwd_hmac=None)
    assert parsed.event_name == "PermissionRequest"


def test_adapter_pretooluse_allow_shape():
    parsed = ClaudeAdapter().parse_hook_input(_ptu(), cwd_hmac=None)
    out = ClaudeAdapter().emit_hook_output(AdapterDecision(decision="approve"), parsed)
    hso = out["hookSpecificOutput"]
    assert hso["hookEventName"] == "PreToolUse"
    assert hso["permissionDecision"] == "allow"
    assert "permissionDecisionReason" not in hso  # allow carries no reason


def test_adapter_pretooluse_deny_shape():
    parsed = ClaudeAdapter().parse_hook_input(_ptu(), cwd_hmac=None)
    out = ClaudeAdapter().emit_hook_output(
        AdapterDecision(decision="deny", reason="nope"), parsed)
    hso = out["hookSpecificOutput"]
    assert hso["permissionDecision"] == "deny"
    assert hso["permissionDecisionReason"] == "nope"


def test_adapter_pretooluse_fallback_external_asks():
    # EXTERNAL (fail_open) PreToolUse fallback → "ask" (defer to local prompt),
    # NEVER a hard deny that would brick the terminal.
    parsed = ClaudeAdapter().parse_hook_input(_ptu(), cwd_hmac=None)
    parsed.fail_open = True
    out = ClaudeAdapter().emit_local_fallback(parsed, "channel down")
    assert out["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_adapter_pretooluse_fallback_managed_denies():
    # MANAGED (fail_closed) PreToolUse fallback → deny.
    parsed = ClaudeAdapter().parse_hook_input(_ptu(), cwd_hmac=None)
    parsed.fail_open = False
    out = ClaudeAdapter().emit_local_fallback(parsed, "channel down")
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_adapter_permission_request_fallback_external_defers_empty():
    # EXTERNAL PermissionRequest fallback → {} (no decision → Claude's own
    # prompt runs). PermissionRequest has no "ask" value.
    raw = {"tool_name": "Read", "tool_input": {}, "cwd": "/x"}
    parsed = ClaudeAdapter().parse_hook_input(raw, cwd_hmac=None)
    parsed.fail_open = True
    out = ClaudeAdapter().emit_local_fallback(parsed, "channel down")
    assert out == {}


def test_run_hook_pretooluse_external_timeout_asks(monkeypatch):
    # End-to-end: a hand-launched (external) PreToolUse whose remote poll times
    # out must emit permissionDecision "ask" — never bricks the terminal.
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        return {"status": "pending"}  # never resolves → timeout

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload=_ptu(),
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
    assert out["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_run_hook_pretooluse_managed_timeout_denies(monkeypatch):
    # A MANAGED PreToolUse whose remote poll times out fails CLOSED (deny).
    buf = _capture_stdout(monkeypatch)
    _mark_managed(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        return {"status": "pending"}

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload=_ptu(),
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_run_hook_permission_request_external_timeout_defers(monkeypatch):
    # An external PermissionRequest (no event_name) timing out → {} (defer to
    # Claude's own prompt).
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        return {"status": "pending"}

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload={"tool_name": "Read", "tool_input": {"file_path": "/x"},
                       "cwd": "/Users/dev/x"},  # no hook_event_name
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    # Canonical abstain = EMPTY stdout (exit 0, no JSON) → Claude's own prompt.
    assert buf.getvalue() == ""


def test_run_hook_pretooluse_external_approve_allows(monkeypatch):
    # External PreToolUse the remote user APPROVES → permissionDecision allow.
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        return {"status": "approved", "decision": "approve", "scope": "once"}

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=1.0, poll_interval_s=0.01),
        stdin_payload=_ptu(),
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "allow"


def test_fail_open_external_config_off_denies(monkeypatch):
    # With fail_open_external=False, even an external session fails CLOSED.
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)

    def fake_rpc(name, params, **_kwargs):
        if name == "remote_helper_create_permission_request":
            return {"request_id": params["p_request_id"], "status": "pending"}
        return {"status": "pending"}

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01,
                                      fail_open_external=False),
        stdin_payload=_ptu(),
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        user_secret_loader=lambda: "user-hmac-secret",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


# ── M1 review (codex): early-exit + crash fallbacks are event/origin-aware ──

def test_run_hook_not_paired_external_pretooluse_asks(monkeypatch):
    # codex P1 #2: the "helper not paired" early exit must still fail OPEN for an
    # external PreToolUse (ask), not emit a fail-closed deny.
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)
    import cli_pulse_helper

    def _boom():
        raise RuntimeError("not paired")

    monkeypatch.setattr(cli_pulse_helper, "load_config", _boom)
    rc = remote_hook.run_hook("claude", stdin_payload=_ptu(), sleep_fn=lambda _s: None)
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
    assert out["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_run_hook_not_paired_managed_pretooluse_denies(monkeypatch):
    # Same early exit, MANAGED session → fail CLOSED (deny).
    buf = _capture_stdout(monkeypatch)
    _mark_managed(monkeypatch)
    import cli_pulse_helper

    def _boom():
        raise RuntimeError("not paired")

    monkeypatch.setattr(cli_pulse_helper, "load_config", _boom)
    rc = remote_hook.run_hook("claude", stdin_payload=_ptu(), sleep_fn=lambda _s: None)
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["permissionDecision"] == "deny"


def test_crash_fallback_external_pretooluse_asks(monkeypatch):
    # codex P1 #3: a crash in the hook body during an external PreToolUse must
    # emit the PreToolUse-shaped "ask", not a mismatched PermissionRequest deny.
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)

    class _BoomConfig:
        @property
        def device_id(self):
            raise RuntimeError("boom")
        helper_secret = "x"

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload=_ptu(),
        helper_config=_BoomConfig(),
        rpc_caller=lambda _n, _p, **_k: {},
        user_secret_loader=lambda: "x",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
    assert out["hookSpecificOutput"]["permissionDecision"] == "ask"


def test_crash_fallback_external_permission_request_abstains(monkeypatch):
    # A crash during an external PermissionRequest → empty stdout (abstain).
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)

    class _BoomConfig:
        @property
        def device_id(self):
            raise RuntimeError("boom")
        helper_secret = "x"

    rc = remote_hook.run_hook(
        "claude",
        config=remote_hook.HookConfig(timeout_s=0.05, poll_interval_s=0.01),
        stdin_payload={"tool_name": "Read", "tool_input": {"file_path": "/x"},
                       "cwd": "/Users/dev/x"},  # PermissionRequest (no event name)
        helper_config=_BoomConfig(),
        rpc_caller=lambda _n, _p, **_k: {},
        user_secret_loader=lambda: "x",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    assert buf.getvalue() == ""


def test_crash_fallback_non_claude_provider_still_raw_denies(monkeypatch):
    # Non-claude providers keep the constant Claude-deny last resort (unchanged).
    buf = _capture_stdout(monkeypatch)
    _mark_external(monkeypatch)
    rc = remote_hook.run_hook(
        "codex",  # CodexAdapter.parse raises NotImplementedError → crash path
        stdin_payload={"tool_name": "Read", "tool_input": {}, "cwd": "/x"},
        helper_config=_StubHelperConfig(),
        rpc_caller=lambda _n, _p, **_k: {},
        user_secret_loader=lambda: "x",
        sleep_fn=lambda _s: None,
    )
    assert rc == 0
    out = json.loads(buf.getvalue())
    assert out["hookSpecificOutput"]["decision"]["behavior"] == "deny"
