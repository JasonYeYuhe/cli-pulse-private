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

    def fake_rpc(name, params):
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

    def fake_rpc(name, params):
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

    def fake_rpc(name, params):
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

    def fake_rpc(name, params):
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

    def fake_rpc(name, params):
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
