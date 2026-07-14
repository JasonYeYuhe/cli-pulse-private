"""Tests for the iter-1 RemoteAgentManager and PosixPtyTransport.

These tests:
  - Exercise the POSIX transport against `cat` (a portable PTY-friendly
    echo). Verifies start → write_stdin → read_stdout → terminate.
  - Exercise the manager's command dispatch table with a fake transport
    + fake rpc_caller, so a CI host without `claude` installed can still
    validate the dispatch logic.

No network. No real Supabase. No real `claude` binary.
"""
from __future__ import annotations

import base64
import json
import os
import sys
import time
import uuid
from pathlib import Path
from typing import Any

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from remote_agent import RemoteAgentManager  # noqa: E402
from transports import SessionHandle, SessionTransport, TransportError  # noqa: E402


# ── PosixPtyTransport against `cat` ──────────────────────────────


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX-only transport")
def test_posix_pty_round_trip_through_cat():
    from transports.posix_pty import PosixPtyTransport

    t = PosixPtyTransport()
    handle = t.start(
        session_id="11111111-1111-1111-1111-111111111111",
        argv=["cat"],
    )
    try:
        assert t.is_alive(handle)
        # cat echoes stdin to stdout. Send a marker, drain.
        t.write_stdin(handle, b"hello-pty\n")
        # Drain with a short polling loop because the kernel needs a tick
        # to deliver the bytes through the PTY.
        deadline = time.monotonic() + 1.5
        seen = b""
        while time.monotonic() < deadline:
            chunk = t.read_stdout(handle, max_bytes=1024)
            if chunk:
                seen += chunk
                if b"hello-pty" in seen:
                    break
            time.sleep(0.05)
        assert b"hello-pty" in seen, f"cat did not echo within timeout; got {seen!r}"
    finally:
        t.terminate(handle)
        # Wait briefly so `wait` reports the exit code rather than None.
        for _ in range(20):
            if t.wait(handle, timeout=0) is not None:
                break
            time.sleep(0.05)
        t.close(handle)
        assert not t.is_alive(handle)


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX-only transport")
def test_posix_pty_spawn_failure_raises_transport_error():
    from transports.posix_pty import PosixPtyTransport

    t = PosixPtyTransport()
    with pytest.raises(TransportError):
        t.start(
            session_id="22222222-2222-2222-2222-222222222222",
            argv=["/this/path/does/not/exist/xyzzy"],
        )


@pytest.mark.skipif(sys.platform == "win32", reason="POSIX-only transport")
def test_posix_pty_close_is_idempotent():
    from transports.posix_pty import PosixPtyTransport

    t = PosixPtyTransport()
    handle = t.start(
        session_id="33333333-3333-3333-3333-333333333333",
        argv=["cat"],
    )
    t.close(handle)
    t.close(handle)  # second call must not raise


# ── ConPtyTransport stub ─────────────────────────────────────────


def test_conpty_transport_raises_not_implemented_on_construction():
    from transports.conpty import ConPtyTransport

    with pytest.raises(NotImplementedError) as exc_info:
        ConPtyTransport()
    # The error message must mention the desktop track so a future
    # debugger can find the implementation handoff.
    assert "cli-pulse-desktop" in str(exc_info.value).lower()


# ── RemoteAgentManager dispatch with fake transport ──────────────


class _StubHelperConfig:
    device_id = "44444444-4444-4444-4444-444444444444"
    helper_secret = "helper-secret-for-tests"


class FakeHandle:
    pass


class FakeTransport(SessionTransport):
    """Test double — records calls, returns canned bytes for read_stdout."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self.alive: dict[str, bool] = {}
        self.exit_code: dict[str, int | None] = {}
        self.stdin_log: dict[str, list[bytes]] = {}
        self.canned_stdout: dict[str, bytes] = {}

    def start(self, session_id, argv, env=None, cwd=None, *,
              pass_fds=(), env_remove=frozenset()):
        self.calls.append(("start", {"session_id": session_id, "argv": argv,
                                     "env": dict(env or {}), "cwd": cwd,
                                     "pass_fds": tuple(pass_fds),
                                     "env_remove": frozenset(env_remove)}))
        self.alive[session_id] = True
        self.stdin_log[session_id] = []
        return SessionHandle(session_id=session_id, payload=FakeHandle())

    def write_stdin(self, handle, data):
        self.calls.append(("write_stdin",
                           {"session_id": handle.session_id, "data": data}))
        if not self.alive.get(handle.session_id, False):
            return 0
        self.stdin_log[handle.session_id].append(data)
        return len(data)

    def read_stdout(self, handle, max_bytes=4096):
        return self.canned_stdout.pop(handle.session_id, b"")

    def interrupt(self, handle):
        self.calls.append(("interrupt", {"session_id": handle.session_id}))

    def terminate(self, handle):
        self.calls.append(("terminate", {"session_id": handle.session_id}))
        self.alive[handle.session_id] = False
        self.exit_code.setdefault(handle.session_id, 0)

    def is_alive(self, handle):
        return self.alive.get(handle.session_id, False)

    def wait(self, handle, timeout=None):
        return self.exit_code.get(handle.session_id)

    def close(self, handle):
        self.calls.append(("close", {"session_id": handle.session_id}))
        self.alive[handle.session_id] = False


def _make_manager(rpc_responses: dict[str, Any] | None = None,
                  *, claude_token_resolver=None):
    rpc_log: list[tuple[str, dict[str, Any]]] = []
    rpc_responses = dict(rpc_responses or {})

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name in rpc_responses:
            r = rpc_responses[name]
            if callable(r):
                return r(params)
            return r
        if name == "remote_helper_pull_commands":
            return []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
        claude_token_resolver=claude_token_resolver,
    )
    return mgr, transport, rpc_log


def _start_payload(provider="claude", cwd_basename="", cwd_hmac=None,
                   client_label=None) -> str:
    return json.dumps({
        "provider": provider,
        "cwd_basename": cwd_basename,
        "cwd_hmac": cwd_hmac,
        "client_label": client_label,
    })


def test_dispatch_start_spawns_session_and_sets_env_var():
    session_id = str(uuid.uuid4())
    cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(client_label="MyMac"),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })

    counters = mgr.tick()
    assert counters["commands_processed"] == 1

    # Transport saw a start call.
    starts = [c for c in transport.calls if c[0] == "start"]
    assert len(starts) == 1
    start_args = starts[0][1]
    # iter 1: claude only → argv[0] should be `claude`.
    assert start_args["argv"][0] == "claude"
    # CLI_PULSE_REMOTE_SESSION_ID env var must equal the session id, so
    # remote_hook can bind permission requests back to this session.
    assert start_args["env"]["CLI_PULSE_REMOTE_SESSION_ID"] == session_id

    # Helper completed the command as `delivered` + register_session ran.
    rpc_names = [name for name, _ in log]
    assert "remote_helper_register_session" in rpc_names
    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert completes, "complete_command not called"
    assert completes[-1]["p_status"] == "delivered"


def test_dispatch_prompt_writes_to_session_stdin():
    session_id = str(uuid.uuid4())
    start_cmd_id = str(uuid.uuid4())
    prompt_cmd_id = str(uuid.uuid4())

    queue: list[list[dict[str, Any]]] = [
        [{
            "id": start_cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(),
        }],
        [{
            "id": prompt_cmd_id,
            "session_id": session_id,
            "kind": "prompt",
            "payload": "hello claude",
        }],
        [],
    ]

    def pull_commands(_params):
        return queue.pop(0) if queue else []

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })

    mgr.tick()  # spawn
    mgr.tick()  # prompt

    # write_stdin should have received "hello claude\r" — Claude Code's
    # TUI runs raw with bracketed-paste enabled, so LF is "more text"
    # and CR is the submit key. write_to_session normalizes any trailing
    # terminator to CR. See helper/test_remote_agent_submit.py for the
    # full matrix; this assertion just pins the dispatch wiring.
    stdin = b"".join(transport.stdin_log.get(session_id, []))
    assert stdin == b"hello claude\r"

    # Both commands completed delivered.
    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert {c["p_command_id"] for c in completes} == {start_cmd_id, prompt_cmd_id}
    assert all(c["p_status"] == "delivered" for c in completes)


def test_dispatch_prompt_for_unknown_session_fails():
    cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": str(uuid.uuid4()),
            "kind": "prompt",
            "payload": "hello",
        }]

    mgr, _transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert len(completes) == 1
    assert completes[0]["p_status"] == "failed"
    assert "not running" in (completes[0]["p_error"] or "")


def test_dispatch_stop_for_unknown_session_completes_failed():
    """PR #18 manual-test surface: previously remote-queue stop on
    a session this helper doesn't own returned (True, "") and
    complete_command was marked `delivered`. The macOS app then saw
    the no-op as a successful stop, the stale Supabase row stayed
    running, and the user couldn't tell the operation hadn't
    happened. Now the dispatcher checks ownership before invoking
    `_stop_session_impl`.
    """
    cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": str(uuid.uuid4()),
            "kind": "stop",
            "payload": "",
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    # Transport.terminate / .close must NOT have been invoked — the
    # session was never owned, so the old code path's silent no-op
    # would have visited terminate(handle=None) and crashed at the
    # type check. Check the explicit fail-closed signal instead.
    terminates = [c for c in transport.calls if c[0] == "terminate"]
    assert terminates == [], "stop on unknown session must not signal a transport"
    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert len(completes) == 1
    assert completes[0]["p_status"] == "failed", (
        "stop on unknown session must mark `failed` — `delivered` would "
        "let the macOS app think a stale row was successfully stopped"
    )
    assert "not running" in (completes[0]["p_error"] or "")


def test_dispatch_interrupt_for_unknown_session_completes_failed():
    """Same fail-closed posture as stop above. Interrupt for a
    session this helper doesn't own is a no-op; reporting it as
    `delivered` would mask stale Supabase rows the same way.
    """
    cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": str(uuid.uuid4()),
            "kind": "interrupt",
            "payload": "",
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert completes and completes[0]["p_status"] == "failed"
    assert "not running" in (completes[0]["p_error"] or "")


def test_dispatch_unknown_kind_marks_failed():
    cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": str(uuid.uuid4()),
            "kind": "explode",
            "payload": "",
        }]

    mgr, _transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert completes and completes[0]["p_status"] == "failed"
    assert "explode" in (completes[0]["p_error"] or "")


def test_dispatch_start_rejects_unknown_provider():
    """v1.15 (was: `_rejects_non_claude_provider`): only rejects
    providers that have NO registered spawner. Claude / Codex / Gemini
    are all accepted. Use a clearly-bogus name to assert the
    rejection path still fires for the unsupported case.
    """
    cmd_id = str(uuid.uuid4())
    sid = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": sid,
            "kind": "start",
            "payload": _start_payload(provider="totally-not-a-cli"),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    starts = [c for c in transport.calls if c[0] == "start"]
    assert starts == []  # spawn refused
    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert completes and completes[0]["p_status"] == "failed"


def test_dispatch_start_accepts_codex_provider():
    """v1.15: codex is now a first-class spawnable provider. argv
    resolves to ['codex'] and the spawn proceeds (transport stub
    captures it without actually exec'ing).
    """
    cmd_id = str(uuid.uuid4())
    sid = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": sid,
            "kind": "start",
            "payload": _start_payload(provider="codex"),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    starts = [c for c in transport.calls if c[0] == "start"]
    assert len(starts) == 1, f"expected 1 spawn for codex, got {starts}"
    assert starts[0][1]["argv"] == ["codex"], (
        f"argv must be ['codex'], got {starts[0][1]['argv']}"
    )


def test_dispatch_start_accepts_gemini_provider_default():
    """gemini accepted; default argv is bare ['agy'] (v-next P0-B: the
    gemini provider spawns the Antigravity CLI `agy`, no skip-permissions
    flag). The opt-in flag is exercised separately.
    """
    cmd_id = str(uuid.uuid4())
    sid = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": cmd_id,
            "session_id": sid,
            "kind": "start",
            "payload": _start_payload(provider="gemini"),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    starts = [c for c in transport.calls if c[0] == "start"]
    assert len(starts) == 1
    # Default: bare agy, NO --dangerously-skip-permissions. The picker
    # opts the user in explicitly via extra_env.
    assert starts[0][1]["argv"] == ["agy"], (
        f"default gemini argv must be bare agy, got {starts[0][1]['argv']}"
    )


# ── v-next P0-A: claude OAuth token injection ───────────────────────

_INJECTED_TOKEN = "sk-ant-oat01-INJECTEDtoken"


def _spawn_claude_and_get_start(mgr, transport, provider="claude"):
    """Spawn one session directly and return the recorded transport.start
    kwargs dict (`{"argv","env","cwd","pass_fds",...}`)."""
    from remote_agent import SessionStartParams
    transport.calls.clear()
    mgr.spawn_session(SessionStartParams(session_id=str(uuid.uuid4()), provider=provider))
    starts = [c for c in transport.calls if c[0] == "start"]
    assert len(starts) == 1
    return starts[0][1]


def test_claude_auth_injected_via_inherited_fd_not_env():
    """claude spawn injects the resolved token over an inherited fd
    (CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR) + pass_fds — the raw token
    NEVER appears in the child env (no `ps eww` / tool-subprocess leak)."""
    mgr, transport, _log = _make_manager(
        claude_token_resolver=lambda: _INJECTED_TOKEN,
    )
    start = _spawn_claude_and_get_start(mgr, transport)
    env = start["env"]
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" in env
    fd_str = env["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"]
    assert fd_str.isdigit()
    assert start["pass_fds"] == (int(fd_str),)
    # Leak guard: raw token in NO env value, and the plain env var is unset.
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in env
    assert all(_INJECTED_TOKEN not in v for v in env.values())


def test_claude_auth_falls_back_to_env_when_fd_plumbing_fails(monkeypatch):
    """If os.pipe fails, fall back to the CLAUDE_CODE_OAUTH_TOKEN env var
    (degraded but functional) and pass no fds."""
    import remote_agent
    monkeypatch.setattr(remote_agent.os, "pipe",
                        lambda: (_ for _ in ()).throw(OSError("no fds")))
    mgr, transport, _log = _make_manager(
        claude_token_resolver=lambda: _INJECTED_TOKEN,
    )
    start = _spawn_claude_and_get_start(mgr, transport)
    env = start["env"]
    assert env.get("CLAUDE_CODE_OAUTH_TOKEN") == _INJECTED_TOKEN
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" not in env
    assert start["pass_fds"] == ()


def test_no_auth_injection_when_resolver_absent():
    """Default manager (no resolver) → no token vars, no pass_fds. Keeps
    existing callers + tests hermetic (never reads real creds)."""
    mgr, transport, _log = _make_manager()  # resolver defaults to None
    start = _spawn_claude_and_get_start(mgr, transport)
    env = start["env"]
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in env
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" not in env
    assert start["pass_fds"] == ()


def test_no_auth_injection_for_non_claude_provider():
    """The claude resolver is provider-scoped — a gemini spawn never gets
    claude's token."""
    mgr, transport, _log = _make_manager(
        claude_token_resolver=lambda: _INJECTED_TOKEN,
    )
    start = _spawn_claude_and_get_start(mgr, transport, provider="gemini")
    env = start["env"]
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in env
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" not in env
    assert all(_INJECTED_TOKEN not in v for v in env.values())


def test_codex_spawn_pins_home_and_scrubs_openai_key_on_plan(monkeypatch):
    """v1.35 parity: an on-plan Codex spawn (a) applies the spawner's
    env_overrides — CODEX_HOME + RUST_BACKTRACE — which nothing merged
    before, and (b) forwards env_remove={OPENAI_API_KEY} to the transport
    so the child can't fall back to the billed API. Mirrors the Swift
    manager's envPatch glue."""
    import provider_spawners.codex as codex_mod
    monkeypatch.setattr(codex_mod, "resolved_user_home", lambda: "/Users/z")
    monkeypatch.setattr(
        codex_mod.CodexSpawner, "has_verified_chatgpt_auth",
        staticmethod(lambda home, file_loader=None: True),
    )
    mgr, transport, _log = _make_manager()
    start = _spawn_claude_and_get_start(mgr, transport, provider="codex")
    assert start["env"]["CODEX_HOME"] == "/Users/z/.codex"
    assert start["env"]["RUST_BACKTRACE"] == "1"
    assert "OPENAI_API_KEY" in start["env_remove"]


def test_codex_spawn_off_plan_does_not_scrub(monkeypatch):
    """An api-key Codex user is left alone: CODEX_HOME is still pinned but
    OPENAI_API_KEY is NOT scrubbed (their own auth stays intact)."""
    import provider_spawners.codex as codex_mod
    monkeypatch.setattr(codex_mod, "resolved_user_home", lambda: "/Users/z")
    monkeypatch.setattr(
        codex_mod.CodexSpawner, "has_verified_chatgpt_auth",
        staticmethod(lambda home, file_loader=None: False),
    )
    mgr, transport, _log = _make_manager()
    start = _spawn_claude_and_get_start(mgr, transport, provider="codex")
    assert start["env"]["CODEX_HOME"] == "/Users/z/.codex"
    assert "OPENAI_API_KEY" not in start["env_remove"]


def test_no_auth_injection_when_resolver_returns_none():
    """Resolver present but yields no token (no creds) → spawn proceeds
    with no injection (pre-existing 401 behaviour, not a crash)."""
    mgr, transport, _log = _make_manager(claude_token_resolver=lambda: None)
    start = _spawn_claude_and_get_start(mgr, transport)
    env = start["env"]
    assert "CLAUDE_CODE_OAUTH_TOKEN" not in env
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" not in env
    assert start["pass_fds"] == ()


def test_resolver_exception_does_not_break_spawn():
    """A throwing resolver must not abort the spawn — degrade to no
    injection."""
    def _boom():
        raise RuntimeError("resolver exploded")
    mgr, transport, _log = _make_manager(claude_token_resolver=_boom)
    start = _spawn_claude_and_get_start(mgr, transport)
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" not in start["env"]
    assert start["pass_fds"] == ()


def test_spawn_env_has_augmented_path():
    """v-next P0-C: the child's PATH includes the common CLI dirs launchd
    omits (so claude/agy actually exec)."""
    mgr, transport, _log = _make_manager()
    start = _spawn_claude_and_get_start(mgr, transport)
    path = start["env"].get("PATH", "")
    assert "/opt/homebrew/bin" in path
    assert os.path.expanduser("~/.local/bin") in path


def test_build_env_augments_caller_path_instead_of_overwriting():
    """A caller-supplied extra_env PATH is preserved + augmented (not
    clobbered) — codex review."""
    from remote_agent import SessionStartParams
    mgr, transport, _log = _make_manager()
    transport.calls.clear()
    mgr.spawn_session(SessionStartParams(
        session_id=str(uuid.uuid4()), provider="claude",
        extra_env={"PATH": "/custom/bin"},
    ))
    env = [c for c in transport.calls if c[0] == "start"][0][1]["env"]
    assert "/custom/bin" in env["PATH"]        # caller PATH kept
    assert "/opt/homebrew/bin" in env["PATH"]  # + augmented


def test_claude_auth_fd_partial_failure_closes_read_fd_and_falls_back(monkeypatch):
    """If a step AFTER os.pipe() fails (here os.set_inheritable), the read
    fd must be closed (no daemon fd leak) and we degrade to the env var —
    codex/Gemini review."""
    import remote_agent
    real_pipe = os.pipe
    opened: dict[str, int] = {}
    closed: list[int] = []
    real_close = os.close

    def tracking_pipe():
        r, w = real_pipe()
        opened["r"], opened["w"] = r, w
        return r, w

    def tracking_close(fd):
        closed.append(fd)
        return real_close(fd)

    def boom_set_inheritable(*_a, **_k):
        raise OSError("set_inheritable failed")

    monkeypatch.setattr(remote_agent.os, "pipe", tracking_pipe)
    monkeypatch.setattr(remote_agent.os, "close", tracking_close)
    monkeypatch.setattr(remote_agent.os, "set_inheritable", boom_set_inheritable)

    mgr, transport, _log = _make_manager(claude_token_resolver=lambda: _INJECTED_TOKEN)
    start = _spawn_claude_and_get_start(mgr, transport)
    env = start["env"]
    assert env.get("CLAUDE_CODE_OAUTH_TOKEN") == _INJECTED_TOKEN  # env fallback
    assert "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR" not in env
    assert start["pass_fds"] == ()
    # Both pipe ends were closed — the read end in the except, the write
    # end in the inner finally. No leak into the daemon.
    assert opened["r"] in closed
    assert opened["w"] in closed


# ── v-next P1-2: get_tail_snapshot + per-session raw ring ────────────


def _spawn(mgr, provider="claude", realtime_private=None):
    from remote_agent import SessionStartParams
    sid = str(uuid.uuid4())
    mgr.spawn_session(SessionStartParams(
        session_id=sid, provider=provider, realtime_private=realtime_private))
    return sid


def test_post_stdout_chunk_fills_raw_ring_with_ansi_preserved():
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    mgr._post_stdout_chunk(sid, "\x1b[31mhello\x1b[0m world")
    snap = mgr.local_get_tail_snapshot(sid)
    data = base64.b64decode(snap["bytes_base64"])
    # Raw (un-stripped) ANSI is preserved in the ring for xterm.js.
    assert data == "\x1b[31mhello\x1b[0m world".encode()


def test_get_tail_snapshot_unknown_session_returns_none():
    mgr, _transport, _log = _make_manager()
    assert mgr.local_get_tail_snapshot("no-such-session") is None


def test_raw_ring_is_bounded_to_cap():
    import remote_agent
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    # Push well past the 64 KB cap. Use normal prose (NOT a long run of one
    # char — the redactor scrubs secret-shaped blobs) so redaction is a no-op
    # and the only size change is the ring's own eviction.
    chunk = "normal terminal output line here\n" * 250  # ~8 KB, redaction-safe
    for _ in range(12):  # ~99 KB total
        mgr._post_stdout_chunk(sid, chunk)
    sess = mgr._sessions[sid]
    assert len(sess.raw_ring) == remote_agent._RAW_RING_CAP_BYTES
    snap = mgr.local_get_tail_snapshot(sid, max_bytes=remote_agent._RAW_RING_CAP_BYTES)
    data = base64.b64decode(snap["bytes_base64"])
    assert len(data) == remote_agent._RAW_RING_CAP_BYTES
    # Tail content is the (redaction-untouched) prose.
    assert b"terminal output line" in data


def test_get_tail_snapshot_honors_max_bytes():
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    mgr._post_stdout_chunk(sid, "0123456789")
    snap = mgr.local_get_tail_snapshot(sid, max_bytes=4)
    data = base64.b64decode(snap["bytes_base64"])
    assert data == b"6789"  # last 4 bytes


def test_get_tail_snapshot_via_drain_path():
    """Integration: bytes flowing through the real drain (tick) land in the
    ring and come back via the snapshot."""
    mgr, transport, _log = _make_manager()
    sid = _spawn(mgr)
    # >flush_bytes so the batcher flushes on this tick (→ _post_stdout_chunk).
    # Redaction-safe prose so the bytes survive to the ring unchanged.
    transport.canned_stdout[sid] = b"hello world from the terminal\n" * 150
    mgr.tick()
    snap = mgr.local_get_tail_snapshot(sid)
    data = base64.b64decode(snap["bytes_base64"])
    assert b"hello world from the terminal" in data


# ── v-next P1-1: working-directory selection ────────────────────────


def test_local_start_threads_cwd_to_transport(tmp_path):
    mgr, transport, _log = _make_manager()
    result = mgr.local_start_claude_session({"provider": "claude", "cwd": str(tmp_path)})
    assert result["ok"]
    start = [c for c in transport.calls if c[0] == "start"][0][1]
    assert start["cwd"] == str(tmp_path)


def test_local_start_without_cwd_inherits():
    mgr, transport, _log = _make_manager()
    mgr.local_start_claude_session({"provider": "claude"})
    start = [c for c in transport.calls if c[0] == "start"][0][1]
    assert start["cwd"] is None  # POSIX transport treats None as inherit


def test_remote_start_inherits_cwd_none():
    """review L7: the remote (Supabase) start path keeps cwd='' → None
    (inherit) — working-dir selection is a local-only feature."""
    cmd_id = str(uuid.uuid4())
    sid = str(uuid.uuid4())

    def pull(_p):
        return [{"id": cmd_id, "session_id": sid, "kind": "start",
                 "payload": _start_payload()}]

    mgr, transport, _log = _make_manager({"remote_helper_pull_commands": pull})
    mgr.tick()
    start = [c for c in transport.calls if c[0] == "start"][0][1]
    assert start["cwd"] is None


def test_spawn_failure_sanitizes_cwd_path_from_info_event():
    """A bad cwd makes the transport raise an error embedding the ABSOLUTE
    path; it must NOT leak into the cloud `info` event — only the basename
    survives (codex review)."""
    from remote_agent import SessionStartParams

    class _RaisingTransport(FakeTransport):
        def start(self, session_id, argv, env=None, cwd=None, *,
                  pass_fds=(), env_remove=frozenset()):
            raise TransportError(
                f"failed to spawn {argv[0]}: [Errno 2] No such file or directory: '{cwd}'"
            )

    rpc_log: list = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        return [] if name == "remote_helper_pull_commands" else {}

    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(), rpc_caller=fake_rpc, transport=_RaisingTransport(),
    )
    secret = "/Users/jason/private-client-project"
    mgr.spawn_session(SessionStartParams(
        session_id=str(uuid.uuid4()), provider="claude", cwd=secret))
    posted = " ".join(
        str(p.get("p_payload", "")) for (n, p) in rpc_log if n == "remote_helper_post_event"
    )
    assert secret not in posted                 # full path NOT leaked to cloud
    assert "private-client-project" in posted   # basename kept for context


def test_raw_ring_fails_closed_on_ansi_split_secret():
    """A secret split by a VT escape (which hides the token shape from the
    naive redactor) must NOT survive in the retained/replayable ring —
    the fail-closed path stores the stripped+redacted form (codex review)."""
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    # `sk-ant-oat01-real` + color escape + `tokenABCDEFGHIJKLMNOP`.
    mgr._post_stdout_chunk(sid, "sk-ant-oat01-real\x1b[31mtokenABCDEFGHIJKLMNOP")
    data = base64.b64decode(mgr.local_get_tail_snapshot(sid)["bytes_base64"])
    # The post-escape token fragment must be gone (a naive redact would leak it).
    assert b"tokenABCDEFGHIJKLMNOP" not in data
    assert b"sk-ant-oat" not in data


def test_control_plane_activity_bumps_last_activity():
    """resize / reattach-snapshot / interrupt are user presence — they must
    refresh the idle timer so an attached-but-quiet session isn't reaped
    (codex review)."""
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    for action in (
        lambda: mgr.resize_session(sid, 40, 120),
        lambda: mgr.local_get_tail_snapshot(sid),
        lambda: mgr.interrupt_session(sid),
    ):
        mgr._sessions[sid].last_activity_at = time.monotonic() - 10_000
        action()
        assert time.monotonic() - mgr._sessions[sid].last_activity_at < 5


def test_stop_all_sessions_stops_everything():
    mgr, transport, _log = _make_manager()
    _spawn(mgr)
    _spawn(mgr)
    n = mgr.stop_all_sessions("test_reason")
    assert n == 2
    assert mgr._sessions == {}
    teardown = [c for c in transport.calls if c[0] in ("close", "terminate")]
    assert len(teardown) >= 2


def test_tick_local_skips_command_poll_but_drains():
    """P1-5: tick_local() (the fast active-cadence tick) does the local
    drain/exit/reap but NOT the Supabase command poll — so faster local ticks
    don't multiply remote RPC. The full tick() still polls."""
    polls: list = []

    def fake_rpc(name, params):
        if name == "remote_helper_pull_commands":
            polls.append(1)
            return []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(), rpc_caller=fake_rpc, transport=transport,
    )
    sid = _spawn(mgr)
    transport.canned_stdout[sid] = b"hello from the cli\n" * 200  # >flush_bytes
    result = mgr.tick_local()
    assert len(polls) == 0                     # fast tick does NOT poll
    assert result["bytes_drained"] > 0         # but DOES drain local PTY
    mgr.tick()                                 # full tick polls
    assert len(polls) == 1


# ── v-next P1-6: orphan / idle reaping ──────────────────────────────


def test_reaper_stops_idle_session():
    import remote_agent
    mgr, transport, _log = _make_manager()
    sid = _spawn(mgr)
    mgr._sessions[sid].last_activity_at = (
        time.monotonic() - remote_agent._SESSION_IDLE_TIMEOUT_S - 1
    )
    result = mgr.tick()
    assert sid not in mgr._sessions
    assert result["sessions_reaped"] == 1
    assert any(c[0] in ("close", "terminate") for c in transport.calls)


def test_reaper_stops_max_age_session():
    import remote_agent
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    sess = mgr._sessions[sid]
    sess.spawned_at = time.monotonic() - remote_agent._SESSION_MAX_AGE_S - 1
    sess.last_activity_at = time.monotonic()  # recent → only max-age triggers
    result = mgr.tick()
    assert sid not in mgr._sessions
    assert result["sessions_reaped"] == 1


def test_tick_local_does_not_reap_idle_session():
    """review H1: reaping terminates LIVE children (blocking up to ~4s), so it
    must run ONLY on the 1 Hz full tick, never on the fast tick_local — else a
    reap stalls concurrent keystrokes/start/stop on the single-writer executor."""
    import remote_agent
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    mgr._sessions[sid].last_activity_at = (
        time.monotonic() - remote_agent._SESSION_IDLE_TIMEOUT_S - 1
    )
    result = mgr.tick_local()           # fast tick → must NOT reap
    assert sid in mgr._sessions
    assert result["sessions_reaped"] == 0
    result = mgr.tick()                 # full tick → reaps
    assert sid not in mgr._sessions
    assert result["sessions_reaped"] == 1


def test_reaper_keeps_active_session():
    mgr, _transport, _log = _make_manager()
    sid = _spawn(mgr)
    mgr._sessions[sid].last_activity_at = time.monotonic()
    result = mgr.tick()
    assert sid in mgr._sessions
    assert result["sessions_reaped"] == 0


def test_has_active_sessions_reflects_session_count():
    mgr, _transport, _log = _make_manager()
    assert mgr.has_active_sessions() is False
    _spawn(mgr)
    assert mgr.has_active_sessions() is True


def test_shutdown_terminates_running_sessions():
    session_id = str(uuid.uuid4())
    start_cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": start_cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(),
        }]

    mgr, transport, _log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()
    assert transport.is_alive(SessionHandle(session_id=session_id))

    mgr.shutdown()
    terminates = [c for c in transport.calls if c[0] == "terminate"]
    closes = [c for c in transport.calls if c[0] == "close"]
    assert len(terminates) == 1 and terminates[0][1]["session_id"] == session_id
    assert len(closes) == 1


def test_observe_exits_emits_status_event():
    session_id = str(uuid.uuid4())
    start_cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": start_cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()
    # Simulate the child exiting cleanly.
    transport.alive[session_id] = False
    transport.exit_code[session_id] = 0

    mgr.tick()  # observe exit

    status_events = [
        p for n, p in log
        if n == "remote_helper_post_event" and p.get("p_kind") == "status"
    ]
    assert any(p["p_payload"] == "stopped" for p in status_events)


def test_gate_off_pull_commands_is_swallowed():
    """When Remote Control is disabled server-side, the helper RPC raises
    'Device not found or unauthorized'. The manager must keep running so
    that re-enabling resumes dispatch.
    """
    def pull_commands(_params):
        raise RuntimeError("Device not found or unauthorized")

    mgr, _transport, _log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    counters = mgr.tick()  # must not raise
    assert counters["commands_processed"] == 0


# ── Status event payload pinning (Codex review iter1 P1) ───────────


class _SpawnFailingTransport(FakeTransport):
    """Variant that always raises TransportError on start, to simulate
    a missing `claude` binary or PATH lookup miss."""

    def start(self, session_id, argv, env=None, cwd=None, *,
              pass_fds=(), env_remove=frozenset()):
        self.calls.append(("start", {"session_id": session_id, "argv": argv}))
        raise TransportError(f"failed to spawn {argv[0]}: ENOENT")


def test_spawn_failure_emits_exact_errored_payload():
    """Codex review iter1 P1 #2: the SQL gate in `remote_helper_post_event`
    only updates `remote_sessions.status` when `p_payload` is EXACTLY
    `'errored'` or `'stopped'`. An earlier draft sent
    `f"errored: {exc}"`, which silently kept failed sessions stuck on
    pending/running. Pin the exact-string posture here."""
    cmd_id = str(uuid.uuid4())
    sid = str(uuid.uuid4())

    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return [{
                "id": cmd_id,
                "session_id": sid,
                "kind": "start",
                "payload": _start_payload(),
            }]
        return {}

    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=_SpawnFailingTransport(),
    )
    mgr.tick()

    status_events = [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "status"
    ]
    assert status_events, "no status event posted on spawn failure"
    payloads = [p["p_payload"] for p in status_events]
    assert payloads == ["errored"], (
        f"spawn-failure status payload must be exactly 'errored'; got {payloads!r}"
    )


def test_observe_exits_with_nonzero_emits_exact_errored_payload():
    """Same gate as above: a child exiting non-zero must transition the
    session row to `status='errored'`, which only happens when the
    posted event payload is the bare string `'errored'`."""
    session_id = str(uuid.uuid4())
    start_cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": start_cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()  # spawn

    # Child died with code=2 (e.g. claude --version mismatch).
    transport.alive[session_id] = False
    transport.exit_code[session_id] = 2

    mgr.tick()  # observe exit

    status_events = [
        p for n, p in log
        if n == "remote_helper_post_event" and p.get("p_kind") == "status"
    ]
    payloads = [p["p_payload"] for p in status_events]
    assert payloads == ["errored"], (
        f"non-zero-exit status payload must be exactly 'errored'; got {payloads!r}"
    )


def test_observe_exits_with_missing_code_emits_exact_errored_payload():
    """Same gate when `transport.wait` returns None (child gone before
    we could observe a code) — must still post bare `'errored'`."""
    session_id = str(uuid.uuid4())
    start_cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": start_cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(),
        }]

    mgr, transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()

    transport.alive[session_id] = False
    transport.exit_code[session_id] = None  # "child gone" path

    mgr.tick()

    status_payloads = [
        p["p_payload"] for n, p in log
        if n == "remote_helper_post_event" and p.get("p_kind") == "status"
    ]
    assert status_payloads == ["errored"]


def test_post_status_refuses_unknown_status():
    """Defensive: `_post_status` rejects anything other than 'stopped' /
    'errored' rather than letting a typo silently produce a
    no-op event row that doesn't trip the SQL gate."""
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        return {}

    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=FakeTransport(),
    )
    mgr._post_status("11111111-1111-1111-1111-111111111111", "running")

    posted = [n for n, _ in rpc_log if n == "remote_helper_post_event"]
    assert posted == [], (
        "_post_status must NOT call the post_event RPC for unknown statuses"
    )


def test_stop_session_emits_exact_stopped_payload():
    """Symmetric pinning for the success path."""
    session_id = str(uuid.uuid4())
    start_cmd_id = str(uuid.uuid4())

    def pull_commands(_params):
        return [{
            "id": start_cmd_id,
            "session_id": session_id,
            "kind": "start",
            "payload": _start_payload(),
        }]

    mgr, _transport, log = _make_manager({
        "remote_helper_pull_commands": pull_commands,
    })
    mgr.tick()  # spawn

    mgr.stop_session(session_id)

    status_payloads = [
        p["p_payload"] for n, p in log
        if n == "remote_helper_post_event" and p.get("p_kind") == "status"
    ]
    assert status_payloads == ["stopped"]


# ── Phase 2 — live event tail (stdout / info / redaction) ───────


def _start_a_session(mgr, session_id):
    """Helper: queue a single 'start' command, tick once, leave the
    session running. Used by the stdout / info tests below.
    """
    cmd_id = str(uuid.uuid4())
    queue = [
        [{"id": cmd_id, "session_id": session_id,
          "kind": "start", "payload": _start_payload()}],
        [],
    ]
    return queue


def test_stdout_drain_posts_redacted_event():
    """Helper writes redacted stdout chunks to remote_helper_post_event
    when the per-session batcher flushes. Phase 2 P1 — without this,
    the live tail stays empty in the UI even though the helper is
    reading PTY bytes.
    """
    session_id = str(uuid.uuid4())
    queue = _start_a_session(None, session_id)

    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return queue.pop(0) if queue else []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
    )
    mgr.tick()  # spawn

    # Simulate a chunky enough stdout read to trip the batcher's
    # default flush_bytes=3500 cutoff.
    big = "Bearer sk-ant-supersecrettokenAAAAAAAAAAAAAAAAAA " + ("x" * 4000)
    transport.canned_stdout[session_id] = big.encode("utf-8")

    mgr.tick()

    stdout_events = [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "stdout"
    ]
    assert stdout_events, "expected at least one stdout event posted"
    payload = stdout_events[-1]["p_payload"]
    # Secret was redacted before the wire.
    assert "sk-ant-supersecrettokenAAAAAAAAAAAAAAAAAA" not in payload
    assert "«REDACTED»" in payload
    # Server-side row CHECK is `length(payload) <= 4096`; the helper's
    # cap is intentionally a hair under to leave headroom for the SQL
    # `left(p_payload, 4096)` truncation. Event payload must respect.
    assert len(payload) <= 4096


def test_stdout_chunking_flushes_on_idle_when_no_new_reads():
    """Even with no fresh PTY bytes this tick, an idle batcher must
    flush stale data once `max_idle_s` has elapsed so interactive
    output (a few words at a time) doesn't sit half a second behind
    the user's expectations.
    """
    session_id = str(uuid.uuid4())
    queue = _start_a_session(None, session_id)
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return queue.pop(0) if queue else []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
    )
    mgr.tick()  # spawn

    sess = mgr._sessions[session_id]
    # Force the batcher into a "due" state by pre-filling a bit and
    # rewinding `_first_at` past the threshold.
    sess.stdout_batcher.add("hello world\n")
    sess.stdout_batcher._first_at = (
        time.monotonic() - sess.stdout_batcher.max_idle_s - 1
    )

    transport.canned_stdout[session_id] = b""  # no new bytes
    mgr.tick()  # the idle-flush path should fire

    stdout_events = [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "stdout"
    ]
    assert any(
        "hello world" in p["p_payload"] for p in stdout_events
    ), "idle flush did not deliver buffered stdout"


def test_stdout_post_failure_is_non_fatal():
    """Phase 2 invariant: an upload failure must NOT crash the manager
    or kill the session. The local Claude run keeps going; events are
    ephemeral by retention design.
    """
    session_id = str(uuid.uuid4())
    queue = _start_a_session(None, session_id)
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return queue.pop(0) if queue else []
        if name == "remote_helper_post_event" and params.get("p_kind") == "stdout":
            raise RuntimeError("simulated network blip")
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
    )
    mgr.tick()
    transport.canned_stdout[session_id] = ("a" * 4000).encode("utf-8")
    # tick MUST NOT raise
    mgr.tick()

    # Session is still alive.
    assert mgr._sessions[session_id] is not None
    # Helper still attempted the upload (one record in the log).
    attempted = [
        n for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "stdout"
    ]
    assert attempted, "expected at least one stdout post attempt"


def test_stdout_post_does_not_collide_with_status_payload_exactness():
    """Regression guard: adding the stdout uploader must not regress the
    `status='errored'` exact-payload posture pinned in iter1.
    """
    session_id = str(uuid.uuid4())
    queue = _start_a_session(None, session_id)
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return queue.pop(0) if queue else []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
    )
    mgr.tick()
    transport.canned_stdout[session_id] = (
        "some output before exit\n" * 200
    ).encode("utf-8")
    transport.alive[session_id] = False
    transport.exit_code[session_id] = 2
    mgr.tick()

    status_payloads = [
        p["p_payload"] for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "status"
    ]
    assert "errored" in status_payloads
    # No status payload may carry detail — that breaks the SQL gate.
    assert all(p in ("stopped", "errored") for p in status_payloads)


def test_info_event_redacts_and_is_size_bounded():
    """Lifecycle detail (spawn-failure reason, exit code) lands on
    `kind='info'` with redaction + a 1024-char cap. This complements
    but does NOT replace the bare-string `kind='status'` event.
    """
    session_id = str(uuid.uuid4())
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        return {}

    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=FakeTransport(),
    )
    # Synthesise a session entry so _post_info uses the per-session
    # seq counter and not the seq=0 fallback.
    mgr._sessions[session_id] = mgr._sessions.get(session_id) or None
    very_long_token = "Bearer eyJabc.eyJdef.eyJghi-" + ("X" * 5000)
    mgr._post_info(session_id, f"spawn failed: {very_long_token}")

    info_events = [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "info"
    ]
    assert len(info_events) == 1
    payload = info_events[0]["p_payload"]
    # Secret was redacted.
    assert "Bearer eyJabc" not in payload
    assert "«REDACTED»" in payload
    # Capped at the info ceiling (1024 chars).
    assert len(payload) <= 1024


def test_info_event_skipped_when_detail_empty():
    """`_post_info` must no-op on empty detail so callers can invoke it
    unconditionally without a guard."""
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        return {}

    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=FakeTransport(),
    )
    sid = str(uuid.uuid4())
    assert mgr._post_info(sid, "") is False
    assert [n for n, _ in rpc_log if n == "remote_helper_post_event"] == []


def test_spawn_failure_emits_status_and_redacted_info_pair():
    """Phase 2: a spawn failure should land BOTH a bare-string
    `status='errored'` event (gate trips the SQL transition) AND a
    redacted `kind='info'` carrying the failure detail (so the UI
    can render 'Failed to spawn: claude not found' or similar).
    """
    cmd_id = str(uuid.uuid4())
    sid = str(uuid.uuid4())
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return [{
                "id": cmd_id, "session_id": sid,
                "kind": "start", "payload": _start_payload(),
            }]
        return {}

    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=_SpawnFailingTransport(),
    )
    mgr.tick()

    posted = [
        (p["p_kind"], p["p_payload"]) for n, p in rpc_log
        if n == "remote_helper_post_event"
    ]
    statuses = [p for k, p in posted if k == "status"]
    infos = [p for k, p in posted if k == "info"]
    assert statuses == ["errored"]
    assert len(infos) == 1
    assert infos[0].startswith("spawn failed:")


def test_observe_exits_emits_info_with_exit_code():
    """The non-zero-exit path now also posts a redacted info event
    carrying `exit_code=N` so the UI can show "exited code=2"."""
    session_id = str(uuid.uuid4())
    queue = _start_a_session(None, session_id)
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return queue.pop(0) if queue else []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
    )
    mgr.tick()
    transport.alive[session_id] = False
    transport.exit_code[session_id] = 7
    mgr.tick()

    info_events = [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "info"
    ]
    assert any("exit_code=7" in p["p_payload"] for p in info_events)


def test_per_session_event_seq_counter_starts_at_one():
    """Per-session monotonic seq starts at 1 on the first event.
    Phase 2 P0 — replaces the iter1 monotonic-ms scheme that risked
    int32 wrap on long-uptime hosts."""
    session_id = str(uuid.uuid4())
    queue = _start_a_session(None, session_id)
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        if name == "remote_helper_pull_commands":
            return queue.pop(0) if queue else []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
    )
    mgr.tick()  # spawn → no events posted yet
    # Now post a stop manually.
    mgr.stop_session(session_id)

    seqs = [
        p["p_seq"] for n, p in rpc_log
        if n == "remote_helper_post_event"
    ]
    # The only event for this session lifetime is the 'stopped' status.
    assert seqs == [1]


# ── v1.30.x Phase 1b: output_raw vs output_delta in _post_stdout_chunk ──

def _make_broker_manager():
    from local_events import EventBroker
    rpc_log: list[tuple[str, dict[str, Any]]] = []

    def fake_rpc(name, params):
        rpc_log.append((name, dict(params)))
        return {}

    broker = EventBroker(heartbeat_interval_s=None)
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=FakeTransport(),
        event_broker=broker,
    )
    return mgr, broker, rpc_log


def test_post_stdout_chunk_pure_ansi_reaches_raw_not_delta():
    """agy review 2026-06-19: a chunk of pure color/cursor escapes
    (e.g. `\x1b[31m\x1b[0m`, `\x1b[0m`, `\x1b[?25l`) strips to EMPTY for
    output_delta, but MUST still reach the in-app terminal via output_raw —
    else the TUI breaks (these are ubiquitous in TUIs). It must NEVER hit the
    redacted preview or the cloud.
    """
    mgr, broker, rpc_log = _make_broker_manager()
    raw_sub = broker.subscribe(raw=True)
    plain_sub = broker.subscribe(raw=False)

    # Color-only: _ansi_strip → "" so output_delta is empty, but the raw
    # stream must still carry the escapes.
    result = mgr._post_stdout_chunk("S-ansi", "\x1b[31m\x1b[0m")
    assert result is True, "pure-ANSI chunk must still count as emitted (raw)"

    raw_evt = raw_sub.next(timeout=0.5)
    assert raw_evt is not None and raw_evt["event"] == "output_raw"
    assert "\x1b[31m" in raw_evt["payload"], "raw stream must keep the escapes"
    # The redacted preview (raw=False) must receive NOTHING (no empty delta).
    assert plain_sub.next(timeout=0.05) is None
    # NEVER posted to the cloud (no stdout _post_event for pure ANSI).
    assert not [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "stdout"
    ]


def test_post_stdout_chunk_normal_text_routes_both_streams():
    mgr, broker, rpc_log = _make_broker_manager()
    raw_sub = broker.subscribe(raw=True)
    plain_sub = broker.subscribe(raw=False)

    mgr._post_stdout_chunk("S-text", "\x1b[31mhello\x1b[0m")

    raw_evt = raw_sub.next(timeout=0.5)
    assert raw_evt["event"] == "output_raw"
    assert "\x1b[31m" in raw_evt["payload"], "raw keeps ANSI"

    plain_evt = plain_sub.next(timeout=0.5)
    assert plain_evt["event"] == "output_delta"
    assert "hello" in plain_evt["payload"]
    assert "\x1b[31m" not in plain_evt["payload"], "preview is stripped"

    # Cloud gets the stripped stdout, never the raw stream.
    cloud = [
        p for n, p in rpc_log
        if n == "remote_helper_post_event" and p.get("p_kind") == "stdout"
    ]
    assert cloud and "hello" in cloud[0]["p_payload"]
    assert all("\x1b[31m" not in p["p_payload"] for p in cloud)


# ---- R0 (B2) terminal-broadcast wiring -----------------------------------

class _RecordingPublisher:
    """Stand-in for realtime_broadcast.TerminalBroadcastPublisher."""

    def __init__(self) -> None:
        self.submitted: list[tuple[str, str, bytes]] = []
        self.flushed: list[str] = []
        self.forgotten: list[str] = []

    def submit(self, session_id: str, event: str, data: bytes) -> None:
        self.submitted.append((session_id, event, data))

    def flush(self, session_id: str) -> None:
        self.flushed.append(session_id)

    def forget(self, session_id: str) -> None:
        self.forgotten.append(session_id)


def _make_manager_with_publisher(publisher):
    def fake_rpc(name, params):
        if name == "remote_helper_pull_commands":
            return []
        return {}

    transport = FakeTransport()
    mgr = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=fake_rpc,
        transport=transport,
        broadcast_publisher=publisher,
    )
    return mgr, transport


def test_broadcast_disabled_by_default_is_dark():
    # Shipped state: no publisher → zero broadcast, behaves exactly as today.
    mgr, _t, _log = _make_manager()
    assert mgr._broadcast_publisher is None


def test_post_stdout_chunk_submits_ansi_preserved_redacted_to_broadcast():
    pub = _RecordingPublisher()
    mgr, _t = _make_manager_with_publisher(pub)
    sid = _spawn(mgr, realtime_private=True)  # R0 (S3): only PRIVATE sessions broadcast
    mgr._post_stdout_chunk(sid, "\x1b[31mhello\x1b[0m world")
    assert len(pub.submitted) == 1
    s_sid, event, data = pub.submitted[0]
    assert s_sid == sid
    assert event == "stdout"
    # Same redact-at-write bytes as the ring / in-app terminal (ANSI kept).
    assert data == "\x1b[31mhello\x1b[0m world".encode()


def test_broadcast_payload_is_redacted_never_raw():
    pub = _RecordingPublisher()
    mgr, _t = _make_manager_with_publisher(pub)
    sid = _spawn(mgr, realtime_private=True)  # R0 (S3): only PRIVATE sessions broadcast
    secret = "sk-ant-oat01-realtokenABCDEFGHIJKLMNOPQRSTUV"
    mgr._post_stdout_chunk(sid, secret + " after")
    assert pub.submitted, "a chunk should have been submitted"
    data = pub.submitted[0][2]
    assert b"realtokenABCDEFGHIJKLMNOPQRSTUV" not in data, \
        "broadcast MUST carry redacted bytes, never the raw secret"


def test_post_stdout_chunk_does_not_broadcast_a_public_session():
    # R0 (S3) local gate: a PUBLIC session (realtime_private=False) must never
    # reach the producer — zero mint calls, zero HTTP fleet-wide.
    pub = _RecordingPublisher()
    mgr, _t = _make_manager_with_publisher(pub)
    sid = _spawn(mgr, realtime_private=False)
    mgr._post_stdout_chunk(sid, "public output here")
    assert pub.submitted == []


def test_stop_session_flushes_and_forgets_broadcast():
    pub = _RecordingPublisher()
    mgr, _t = _make_manager_with_publisher(pub)
    sid = _spawn(mgr)
    mgr.stop_session(sid)
    assert sid in pub.flushed
    assert sid in pub.forgotten  # per-session state purged on teardown


# ── M4.4: attach EXTERNAL (shell-integration-wrapped) tmux sessions ───────

class _FakeTmuxTransport(SessionTransport):
    """Stand-in for TmuxTransport in attach tests — records I/O, never kills
    (models the NON-OWNING attach: terminate/close must not touch the user's
    real session)."""

    def __init__(self, socket_path, tmux_bin=None, **kw):
        self.socket_path = socket_path
        self.tmux_bin = tmux_bin
        self.attached: list[str] = []
        self.stdin_log: list[bytes] = []
        self.resized: list[tuple[int, int]] = []
        self.closed = False
        self.killed = False
        self._alive = True

    def attach_existing(self, session_id, tmux_session_name):
        self.attached.append(tmux_session_name)
        return SessionHandle(session_id=session_id, payload=FakeHandle())

    def start(self, *a, **k):  # pragma: no cover - attach path must never spawn
        raise AssertionError("attach_wrapped_session must not spawn a new session")

    def write_stdin(self, handle, data):
        self.stdin_log.append(data)
        return len(data)

    def read_stdout(self, handle, max_bytes=4096):
        return b""

    def interrupt(self, handle):
        pass

    def terminate(self, handle):
        # NON-OWNING: attaching to a pre-existing session never kills it.
        self.killed = True   # records the CALL; a real TmuxTransport no-ops it

    def resize(self, handle, rows, cols):
        self.resized.append((rows, cols))

    def is_alive(self, handle):
        return self._alive

    def wait(self, handle, timeout=None):
        return 0

    def close(self, handle):
        self.closed = True


def test_attach_wrapped_session_routes_io_to_per_session_transport(monkeypatch):
    mgr, shared, _rpc = _make_manager()
    made: list[_FakeTmuxTransport] = []

    def _factory(socket_path, tmux_bin=None, **kw):
        t = _FakeTmuxTransport(socket_path, tmux_bin)
        made.append(t)
        return t

    import transports.tmux as tmux_mod
    monkeypatch.setattr(tmux_mod, "TmuxTransport", _factory)

    ok = mgr.attach_wrapped_session(
        "ext-1", "clipulse-claude-123", provider="claude",
        socket_path="/tmp/x.sock",
    )
    assert ok is True
    assert len(made) == 1
    fake = made[0]
    assert fake.socket_path == "/tmp/x.sock"
    assert fake.attached == ["clipulse-claude-123"]

    # Raw input + resize route to the PER-SESSION transport, not the shared one.
    assert mgr.send_input_raw("ext-1", base64.b64encode(b"hi").decode()) is True
    assert fake.stdin_log == [b"hi"]
    assert mgr.resize_session("ext-1", 40, 100) is True
    assert fake.resized == [(40, 100)]
    assert not any(c[0] in ("write_stdin", "start") for c in shared.calls)

    # Stopping detaches via the per-session transport (close), and drops the row.
    mgr.stop_session("ext-1")
    assert fake.closed is True
    assert "ext-1" not in mgr._sessions


def test_attach_wrapped_session_is_idempotent(monkeypatch):
    mgr, _shared, _rpc = _make_manager()
    import transports.tmux as tmux_mod
    monkeypatch.setattr(tmux_mod, "TmuxTransport",
                        lambda socket_path, tmux_bin=None, **kw: _FakeTmuxTransport(socket_path))
    assert mgr.attach_wrapped_session("dup", "clipulse-claude-1", socket_path="/tmp/x") is True
    # second attach with the same id is a no-op success (doesn't double-register)
    assert mgr.attach_wrapped_session("dup", "clipulse-claude-1", socket_path="/tmp/x") is True
    assert len(mgr._sessions) == 1


def test_attach_wrapped_session_returns_false_on_transport_error(monkeypatch):
    mgr, _shared, _rpc = _make_manager()

    class _Boom(_FakeTmuxTransport):
        def attach_existing(self, session_id, tmux_session_name):
            raise TransportError("no such session")

    import transports.tmux as tmux_mod
    monkeypatch.setattr(tmux_mod, "TmuxTransport",
                        lambda socket_path, tmux_bin=None, **kw: _Boom(socket_path))
    assert mgr.attach_wrapped_session("bad", "clipulse-claude-9", socket_path="/tmp/x") is False
    assert "bad" not in mgr._sessions


def test_attach_wrapped_session_rejects_missing_tmux_session(monkeypatch):
    # A wrapped session whose tmux server has no such session (stale/wrong name)
    # must FAIL the attach (not register a doomed row), and must close the dead
    # control client it spawned. Review: codex/agy M4.4a.
    mgr, _shared, _rpc = _make_manager()

    class _Gone(_FakeTmuxTransport):
        def __init__(self, *a, **k):
            super().__init__(*a, **k)
            self._alive = False   # has-session → not present

    made: list[_Gone] = []

    def _factory(socket_path, tmux_bin=None, **kw):
        t = _Gone(socket_path, tmux_bin)
        made.append(t)
        return t

    import transports.tmux as tmux_mod
    monkeypatch.setattr(tmux_mod, "TmuxTransport", _factory)
    ok = mgr.attach_wrapped_session("stale", "clipulse-claude-dead", socket_path="/tmp/x")
    assert ok is False
    assert "stale" not in mgr._sessions
    assert made[0].closed is True, "must close the dead control client it spawned"


def test_list_wrapped_sessions_delegates_to_shell_integration(monkeypatch):
    mgr, _shared, _rpc = _make_manager()
    import shell_integration as si
    monkeypatch.setattr(si, "list_wrapped_sessions",
                        lambda *a, **k: ["clipulse-claude-1", "clipulse-codex-2"])
    assert mgr.list_wrapped_sessions() == ["clipulse-claude-1", "clipulse-codex-2"]


def test_spawned_session_still_uses_shared_transport(monkeypatch):
    # Regression: the per-session-transport plumbing must not change behaviour
    # for manager-SPAWNED sessions — they still go through `self.transport`.
    mgr, shared, _rpc = _make_manager()
    sid = _spawn(mgr)
    mgr.send_input_raw(sid, base64.b64encode(b"x").decode())
    assert any(c[0] == "write_stdin" and c[1]["session_id"] == sid for c in shared.calls)


import shutil as _shutil  # noqa: E402

_HAS_TMUX = _shutil.which("tmux") is not None


@pytest.mark.skipif(not _HAS_TMUX, reason="tmux not installed")
def test_attach_wrapped_session_real_tmux_roundtrip_and_nonowning():
    # The crown-jewel end-to-end: create a REAL tmux session (as if the user
    # launched `claude` in their terminal, wrapped by the shell integration),
    # attach it into the manager, drive it with remote input, read its output
    # back through the normal tail surface, and prove stop() DETACHES without
    # killing the user's real session (owns_session=False).
    import subprocess
    import tempfile
    tmux = _shutil.which("tmux")
    # Short socket dir — a UNIX socket path is capped at ~104 bytes on macOS, so
    # pytest's deep tmp_path overflows it (mirrors the tmux transport test).
    sock_dir = tempfile.mkdtemp(prefix="clip-", dir="/tmp")
    sock = os.path.join(sock_dir, "t.sock")
    name = "clipulse-claude-e2e"
    subprocess.run([tmux, "-S", sock, "new-session", "-d", "-s", name,
                    "-x", "80", "-y", "24", "cat"], check=True)
    try:
        mgr, _shared, _rpc = _make_manager()
        ok = mgr.attach_wrapped_session(
            "ext-real", name, provider="claude", tmux_bin=tmux, socket_path=sock,
        )
        assert ok is True

        # remote input → the attached session; `cat` echoes it back
        mgr.send_input_raw("ext-real", base64.b64encode(b"PING_42\n").decode())

        # drain through the normal loop, then read the tail the app would see
        got = b""
        for _ in range(80):
            mgr._drain_running_sessions_stdout()
            snap = mgr.local_get_tail_snapshot("ext-real", 65536)
            if snap and snap.get("bytes_base64"):
                got = base64.b64decode(snap["bytes_base64"])
                if b"PING_42" in got:
                    break
            time.sleep(0.05)
        assert b"PING_42" in got, got

        # stop() must DETACH, not kill — the user's real session survives.
        mgr.stop_session("ext-real")
        assert "ext-real" not in mgr._sessions
        alive = subprocess.run([tmux, "-S", sock, "has-session", "-t", name])
        assert alive.returncode == 0, "stop() killed the user's real session!"
    finally:
        subprocess.run([tmux, "-S", sock, "kill-server"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _shutil.rmtree(sock_dir, ignore_errors=True)


@pytest.mark.skipif(not _HAS_TMUX, reason="tmux not installed")
def test_attach_wrapped_session_real_tmux_nonexistent_name_fails():
    # A REAL tmux server that is up but has NO session by the requested name →
    # attach must return False (has-session guard), leaving nothing registered.
    import subprocess
    import tempfile
    tmux = _shutil.which("tmux")
    sock_dir = tempfile.mkdtemp(prefix="clip-", dir="/tmp")
    sock = os.path.join(sock_dir, "t.sock")
    # bring the server up with an unrelated session so the socket exists
    subprocess.run([tmux, "-S", sock, "new-session", "-d", "-s", "other", "cat"],
                   check=True)
    try:
        mgr, _shared, _rpc = _make_manager()
        ok = mgr.attach_wrapped_session(
            "ext-missing", "clipulse-claude-nope", provider="claude",
            tmux_bin=tmux, socket_path=sock,
        )
        assert ok is False
        assert "ext-missing" not in mgr._sessions
    finally:
        subprocess.run([tmux, "-S", sock, "kill-server"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _shutil.rmtree(sock_dir, ignore_errors=True)
