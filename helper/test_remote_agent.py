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

import json
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

    def start(self, session_id, argv, env=None, cwd=None):
        self.calls.append(("start", {"session_id": session_id, "argv": argv,
                                     "env": dict(env or {}), "cwd": cwd}))
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


def _make_manager(rpc_responses: dict[str, Any] | None = None):
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

    # write_stdin should have received "hello claude\n" (newline auto-added).
    stdin = b"".join(transport.stdin_log.get(session_id, []))
    assert stdin == b"hello claude\n"

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


def test_dispatch_start_rejects_non_claude_provider():
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
    assert starts == []  # spawn refused
    completes = [p for n, p in log if n == "remote_helper_complete_command"]
    assert completes and completes[0]["p_status"] == "failed"


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

    def start(self, session_id, argv, env=None, cwd=None):
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
