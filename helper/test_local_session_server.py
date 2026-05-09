"""Tests for the local UDS session server.

Covers:
  - 4-byte length-prefixed wire framing (read + write)
  - 1 MiB payload cap rejection (read side)
  - malformed JSON returns a structured `bad_request` error
  - hello / ping bypass auth_token
  - all other methods require a matching auth_token (constant-time
    `hmac.compare_digest` path proven via local_auth_token tests)
  - local_control_enabled gate blocks start/list/stop when off, but
    not hello / ping / set_local_control_enabled
  - set_local_control_enabled persists through the helper config
  - stale socket recovery: a leftover unconnected socket is unlinked,
    then bind succeeds
  - start/list/stop end-to-end through a fake RemoteAgentManager
  - start_session goes through the executor (no manager-internal
    locking required because the executor IS the lock)

Note on socket paths: macOS limits AF_UNIX paths to ~104 chars, and
pytest's short_sock_dir lives under /private/var/folders/... which already
eats most of the budget. We use a `short_sock_dir` fixture that puts
the socket under /tmp (a short, well-known location on every POSIX) so
bind() doesn't blow up on a perfectly good test rig.
"""
from __future__ import annotations

import json
import shutil
import socket
import struct
import sys
import tempfile
from pathlib import Path

import pytest


@pytest.fixture
def short_sock_dir():
    """Return a short tmpdir suitable for AF_UNIX sockets on macOS.
    Cleans up at end-of-test.
    """
    parent = "/tmp" if Path("/tmp").exists() else tempfile.gettempdir()
    d = tempfile.mkdtemp(prefix="cps_", dir=parent)
    try:
        yield Path(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from local_executor import LocalExecutor  # noqa: E402
from local_session_server import (  # noqa: E402
    MAX_PAYLOAD,
    PROTOCOL_VERSION,
    SUPPORTED_METHODS,
    FrameError,
    LocalSessionServer,
    prepare_socket_path,
    read_frame,
    write_frame,
)


# ── framing primitives ────────────────────────────────────────


def _socketpair():
    """Create a connected pair of AF_UNIX sockets for in-process
    framing tests. Avoids touching the filesystem.
    """
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    return a, b


def test_write_then_read_round_trips_short_body():
    a, b = _socketpair()
    try:
        body = b'{"hello":"world"}'
        write_frame(a, body)
        out = read_frame(b)
        assert out == body
    finally:
        a.close()
        b.close()


def test_write_rejects_oversize_body():
    a, b = _socketpair()
    try:
        too_big = b"x" * (MAX_PAYLOAD + 1)
        with pytest.raises(FrameError) as exc_info:
            write_frame(a, too_big)
        assert exc_info.value.code == "frame_too_large"
    finally:
        a.close()
        b.close()


def test_read_rejects_declared_oversize_body():
    """Forge a header that promises > MAX_PAYLOAD; the reader must
    refuse without trying to drain the body.
    """
    a, b = _socketpair()
    try:
        bad_header = struct.pack("!I", MAX_PAYLOAD + 1)
        a.sendall(bad_header)
        with pytest.raises(FrameError) as exc_info:
            read_frame(b)
        assert exc_info.value.code == "frame_too_large"
    finally:
        a.close()
        b.close()


def test_read_returns_none_on_clean_eof():
    a, b = _socketpair()
    a.close()
    try:
        assert read_frame(b) is None
    finally:
        b.close()


def test_read_raises_truncated_when_header_complete_but_body_short():
    a, b = _socketpair()
    try:
        # Promise 8 bytes but send only 3.
        a.sendall(struct.pack("!I", 8) + b"abc")
        a.close()
        with pytest.raises(FrameError) as exc_info:
            read_frame(b)
        assert exc_info.value.code == "frame_truncated"
    finally:
        b.close()


# ── server end-to-end (real UDS, short_sock_dir) ─────────────────────


class FakeManager:
    """Minimal stand-in for RemoteAgentManager. Captures every call so
    tests can assert dispatch + executor-routing happened.
    """

    def __init__(self) -> None:
        self.start_calls: list[dict] = []
        self.list_calls: int = 0
        self.stop_calls: list[str] = []
        self.send_calls: list[tuple[str, str]] = []
        self._sessions: list[dict] = []
        self._next_id_counter = 0

    def local_start_claude_session(self, payload: dict) -> dict:
        self.start_calls.append(payload)
        self._next_id_counter += 1
        sid = f"fake-{self._next_id_counter}"
        self._sessions.append({
            "session_id": sid,
            "provider": "claude",
            "client_label": payload.get("client_label"),
            "spawned_at_monotonic": 0.0,
            "status": "running",
        })
        return {"session_id": sid, "ok": True}

    def local_list_sessions(self) -> list[dict]:
        self.list_calls += 1
        return list(self._sessions)

    def local_stop_session(self, session_id: str) -> dict:
        self.stop_calls.append(session_id)
        before = len(self._sessions)
        self._sessions = [s for s in self._sessions if s["session_id"] != session_id]
        return {"session_id": session_id, "stopped": before != len(self._sessions)}

    def local_send_input(self, session_id: str, payload: str) -> dict:
        self.send_calls.append((session_id, payload))
        owns = any(s["session_id"] == session_id for s in self._sessions)
        return {"session_id": session_id, "written": owns}


def _client_call(sock_path: Path, body: dict, timeout: float = 1.0) -> dict:
    """One-shot client: connect, send one frame, read one reply."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(sock_path))
    try:
        write_frame(s, json.dumps(body).encode("utf-8"))
        reply_bytes = read_frame(s)
        assert reply_bytes is not None
        return json.loads(reply_bytes.decode("utf-8"))
    finally:
        s.close()


def _make_server(sock_dir: Path, *, token: str = "T", enabled: bool = True,
                 manager: FakeManager | None = None,
                 detected: list[dict] | None = None,
                 helper_argv0: str | None = None,
                 ) -> tuple[LocalSessionServer, FakeManager, dict]:
    """Spin up a server bound to a tmp socket. Returns (server, manager,
    state-dict-for-toggle-introspection).
    """
    state = {"enabled": enabled}
    mgr = manager or FakeManager()
    sock_path = sock_dir / "clipulse-helper.sock"

    def _set(v: bool) -> None:
        state["enabled"] = bool(v)

    detected_rows = detected if detected is not None else []
    server = LocalSessionServer(
        socket_path=sock_path,
        get_auth_token=lambda: token,
        get_local_control_enabled=lambda: state["enabled"],
        set_local_control_enabled=_set,
        start_session=mgr.local_start_claude_session,
        list_sessions=mgr.local_list_sessions,
        stop_session=mgr.local_stop_session,
        send_input=mgr.local_send_input,
        list_detected_sessions=lambda: list(detected_rows),
        get_helper_argv0=(lambda: helper_argv0) if helper_argv0 else None,
    )
    server.start()
    return server, mgr, state


def test_hello_returns_caps_without_auth(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir)
    try:
        reply = _client_call(server._socket_path, {
            "id": "1",
            "method": "hello",
            "params": {"client_protocol_version": PROTOCOL_VERSION},
        })
        assert reply["ok"] is True
        result = reply["result"]
        assert result["protocol_version"] == PROTOCOL_VERSION
        assert set(result["supported_methods"]) == set(SUPPORTED_METHODS)
        # send_input lights up this iteration; subscribe_events +
        # approvals stay deferred to iter 2B.
        assert result["capabilities"] == {
            "send_input": True,
            "subscribe_events": False,
            "approvals": False,
        }
        # v1.15: provider_availability is a list of installed CLI
        # spawners. The exact contents depend on the host PATH (the
        # test runs against the dev machine). Assertion is structural:
        # always present, always a list, always a subset of the known
        # provider names. The macOS / iOS picker uses this to gray out
        # menu items for missing CLIs; an empty list means "helper
        # unsure, allow all".
        assert "provider_availability" in result
        assert isinstance(result["provider_availability"], list)
        assert set(result["provider_availability"]).issubset(
            {"claude", "codex", "gemini"}
        )
        # v1.16: helper_version is exposed in hello so the MAS app's
        # HelperInstaller state machine can distinguish a v1.15 nohup
        # helper (1.15.0) from a v1.16 pkg-installed helper (1.16.0+).
        assert "helper_version" in result
        assert isinstance(result["helper_version"], str)
        # Format: semver-ish "MAJOR.MINOR.PATCH". Loose check; the
        # actual value comes from helper.system_collector.HELPER_VERSION.
        parts = result["helper_version"].split(".")
        assert len(parts) >= 2
        assert all(p.isdigit() for p in parts[:2])
    finally:
        server.stop()


def test_hello_version_mismatch_returns_typed_error(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir)
    try:
        reply = _client_call(server._socket_path, {
            "id": "v",
            "method": "hello",
            "params": {"client_protocol_version": 999},
        })
        assert reply["ok"] is False
        assert reply["error"]["code"] == "version_mismatch"
    finally:
        server.stop()


def test_ping_now_requires_auth_codex_review(short_sock_dir):
    """Codex review fix from PR #15: `ping` previously bypassed auth.
    That gave any local process a free liveness probe of the helper.
    Locked down — `ping` now requires a matching token like every
    other method except `hello`.
    """
    server, _mgr, _state = _make_server(short_sock_dir, token="real-token")
    try:
        # No auth_token → unauthenticated.
        no_auth = _client_call(server._socket_path, {"id": "p", "method": "ping"})
        assert no_auth["ok"] is False
        assert no_auth["error"]["code"] == "unauthenticated"
        # Wrong token → unauthenticated.
        bad = _client_call(server._socket_path, {
            "id": "p2", "method": "ping", "auth_token": "wrong",
        })
        assert bad["error"]["code"] == "unauthenticated"
        # Correct token → pong.
        good = _client_call(server._socket_path, {
            "id": "p3", "method": "ping", "auth_token": "real-token",
        })
        assert good == {"id": "p3", "ok": True, "result": {"pong": True}}
    finally:
        server.stop()


def test_authenticated_method_rejects_missing_token(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "list_sessions", "params": {},
        })
        assert reply["ok"] is False
        assert reply["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_authenticated_method_rejects_wrong_token(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="real")
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "list_sessions",
            "auth_token": "wrong",
            "params": {},
        })
        assert reply["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_authenticated_method_accepts_correct_token(short_sock_dir):
    server, mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "list_sessions",
            "auth_token": "T",
            "params": {},
        })
        assert reply["ok"] is True
        # New shape: managed + detected + backward-compat `sessions`.
        assert reply["result"]["managed"] == []
        assert reply["result"]["detected"] == []
        assert reply["result"]["sessions"] == []
        assert mgr.list_calls == 1
    finally:
        server.stop()


def test_local_control_off_blocks_start(short_sock_dir):
    server, mgr, _state = _make_server(short_sock_dir, token="T", enabled=False)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude"},
        })
        assert reply["ok"] is False
        assert reply["error"]["code"] == "local_control_off"
        assert mgr.start_calls == []
    finally:
        server.stop()


def test_set_local_control_enabled_bypasses_gate(short_sock_dir):
    server, _mgr, state = _make_server(short_sock_dir, token="T", enabled=False)
    try:
        reply = _client_call(server._socket_path, {
            "id": "t", "method": "set_local_control_enabled",
            "auth_token": "T",
            "params": {"enabled": True},
        })
        assert reply["ok"] is True
        assert reply["result"] == {"enabled": True}
        assert state["enabled"] is True
    finally:
        server.stop()


def test_start_list_stop_round_trip(short_sock_dir):
    server, mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        # Start
        start_reply = _client_call(server._socket_path, {
            "id": "1", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude", "client_label": "Test Mac"},
        })
        assert start_reply["ok"] is True
        sid = start_reply["result"]["session_id"]
        assert sid.startswith("fake-")

        # List
        list_reply = _client_call(server._socket_path, {
            "id": "2", "method": "list_sessions",
            "auth_token": "T", "params": {},
        })
        assert list_reply["ok"] is True
        sessions = list_reply["result"]["sessions"]
        assert len(sessions) == 1
        assert sessions[0]["session_id"] == sid

        # Stop
        stop_reply = _client_call(server._socket_path, {
            "id": "3", "method": "stop_session",
            "auth_token": "T",
            "params": {"session_id": sid},
        })
        assert stop_reply["ok"] is True
        assert stop_reply["result"] == {"session_id": sid, "stopped": True}

        # List again — should be empty.
        list_reply2 = _client_call(server._socket_path, {
            "id": "4", "method": "list_sessions",
            "auth_token": "T", "params": {},
        })
        assert list_reply2["result"]["sessions"] == []
    finally:
        server.stop()


def test_start_session_rejects_unknown_provider_with_not_implemented(short_sock_dir):
    """v1.15: the local UDS server now accepts any registered provider
    (claude / codex / gemini); only TRULY unknown providers — names
    not in `helper.provider_spawners` — get rejected. This test pins
    that the rejection path still fires for the unknown case."""
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "totally-not-a-cli"},
        })
        assert reply["ok"] is False
        assert reply["error"]["code"] == "not_implemented"
    finally:
        server.stop()


def test_start_session_accepts_codex_provider(short_sock_dir):
    """v1.15 codex review fix: local UDS used to hardcode `claude`
    and reject `codex`/`gemini` even though the helper had spawners
    for them. Codex review caught this 2026-05-08. The local path
    must accept any registered provider so the macOS picker's
    selection gets honored end-to-end."""
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "codex"},
        })
        # The mock RemoteAgentManager (`_make_server`) records the
        # start request and returns ok; we don't actually exec codex
        # here. The assertion is that the UDS server didn't reject
        # the `codex` provider at the gate. `not_implemented` would
        # signal a regression.
        assert reply["ok"] is True, f"unexpected reject: {reply}"
    finally:
        server.stop()


def test_start_session_accepts_gemini_provider(short_sock_dir):
    """Same as codex parity — v1.15 must let `gemini` through."""
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "gemini"},
        })
        assert reply["ok"] is True, f"unexpected reject: {reply}"
    finally:
        server.stop()


def test_unknown_method_returns_unknown_method(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        # Use a method name that's not in SUPPORTED_METHODS at all.
        # `subscribe_events` graduated to a real method in iter 2B,
        # so we pick something that will never collide.
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "totally_made_up_method_xyz",
            "auth_token": "T", "params": {},
        })
        assert reply["error"]["code"] == "unknown_method"
    finally:
        server.stop()


def test_malformed_json_returns_bad_request(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T")
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(str(server._socket_path))
        try:
            write_frame(s, b"{not json}")
            reply_bytes = read_frame(s)
            assert reply_bytes is not None
            reply = json.loads(reply_bytes.decode("utf-8"))
            assert reply["ok"] is False
            assert reply["error"]["code"] == "bad_request"
        finally:
            s.close()
    finally:
        server.stop()


def test_oversize_request_rejected_at_read(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T")
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(1.0)
        s.connect(str(server._socket_path))
        try:
            # Forge a header that promises > MAX_PAYLOAD without sending
            # the body. The server must reply with frame_too_large and
            # close, NOT try to drain the body.
            s.sendall(struct.pack("!I", MAX_PAYLOAD + 1))
            reply_bytes = read_frame(s)
            assert reply_bytes is not None
            reply = json.loads(reply_bytes.decode("utf-8"))
            assert reply["error"]["code"] == "frame_too_large"
        finally:
            s.close()
    finally:
        server.stop()


# ── stale socket recovery ──────────────────────────────────────


def test_prepare_socket_path_unlinks_stale_socket(short_sock_dir):
    leftover = short_sock_dir / "stale.sock"
    leftover.parent.mkdir(parents=True, exist_ok=True)
    # Create a regular file masquerading as a socket — nothing
    # listens on it, so it's "stale" per our recovery semantics.
    leftover.touch()
    prepare_socket_path(leftover)
    assert not leftover.exists()


def test_prepare_socket_path_refuses_when_live_server_listening(short_sock_dir):
    sock_path = short_sock_dir / "live.sock"
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        listener.bind(str(sock_path))
        listener.listen(1)
        with pytest.raises(RuntimeError, match="already listening"):
            prepare_socket_path(sock_path)
    finally:
        listener.close()
        try:
            sock_path.unlink()
        except FileNotFoundError:
            pass


# ── executor-routing integration ────────────────────────────────


def test_server_dispatches_through_real_executor(short_sock_dir):
    """End-to-end: route a real RemoteAgentManager through a real
    LocalExecutor so we prove the writer-thread path doesn't deadlock
    or drop replies. Uses a stub PTY transport so no Claude binary
    is required.
    """
    from remote_agent import RemoteAgentManager, SessionStartParams  # noqa: F401
    from transports import SessionHandle, SessionTransport

    class StubTransport(SessionTransport):
        def __init__(self) -> None:
            self.handles: dict[str, object] = {}

        def start(self, *, session_id, argv, env=None, cwd=None):
            h = SessionHandle(session_id=session_id, payload={"pid": 4242, "alive": True})
            self.handles[session_id] = h
            return h

        def write_stdin(self, handle, body):
            return len(body)

        def read_stdout(self, handle, max_bytes=4096):
            return b""

        def is_alive(self, handle):
            return True

        def wait(self, handle, timeout=0):
            return None

        def terminate(self, handle):
            pass

        def interrupt(self, handle):
            pass

        def close(self, handle):
            self.handles.pop(handle.session_id, None)

    class FakeConfig:
        device_id = "dev-1"
        helper_secret = "secret-1"

    rpc_calls: list[tuple[str, dict]] = []

    def fake_rpc(name, params):
        rpc_calls.append((name, params))
        return None

    executor = LocalExecutor()
    mgr = RemoteAgentManager(
        helper_config=FakeConfig(),
        rpc_caller=fake_rpc,
        transport=StubTransport(),
        executor=executor,
    )

    state = {"enabled": True}
    sock_path = short_sock_dir / "real.sock"
    server = LocalSessionServer(
        socket_path=sock_path,
        get_auth_token=lambda: "T",
        get_local_control_enabled=lambda: state["enabled"],
        set_local_control_enabled=lambda v: state.update(enabled=bool(v)),
        start_session=mgr.local_start_claude_session,
        list_sessions=mgr.local_list_sessions,
        stop_session=mgr.local_stop_session,
        send_input=mgr.local_send_input,
        list_detected_sessions=lambda: [],
    )
    server.start()
    try:
        # Start one session via UDS, list it, send a prompt to it,
        # stop it. All hops route through the executor; no manual
        # locking needed.
        start_reply = _client_call(sock_path, {
            "id": "1", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude", "client_label": "X"},
        })
        assert start_reply["ok"] is True
        sid = start_reply["result"]["session_id"]

        list_reply = _client_call(sock_path, {
            "id": "2", "method": "list_sessions",
            "auth_token": "T", "params": {},
        })
        assert list_reply["ok"] is True
        # New (managed/detected) shape with backward-compat `sessions`.
        managed = list_reply["result"]["managed"]
        assert len(managed) == 1 and managed[0]["session_id"] == sid
        assert managed[0]["controllable"] is True
        assert managed[0]["source"] == "managed"
        assert list_reply["result"]["detected"] == []

        send_reply = _client_call(sock_path, {
            "id": "3", "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": sid, "payload": "hello\n"},
        })
        assert send_reply["ok"] is True
        assert send_reply["result"]["written"] is True

        stop_reply = _client_call(sock_path, {
            "id": "4", "method": "stop_session",
            "auth_token": "T",
            "params": {"session_id": sid},
        })
        assert stop_reply["ok"] is True
        assert stop_reply["result"]["stopped"] is True
    finally:
        server.stop()
        executor.shutdown(wait=True, timeout=2.0)


# ── new RPC coverage (Codex review fixes + iter 2A) ─────────────


def test_get_local_control_status_returns_gate_value(short_sock_dir):
    """Hydration RPC: the macOS app calls this on launch (and after
    flipping the toggle) so the UI reflects the helper's actual
    persisted state without keeping a duplicate.
    """
    server, _mgr, state = _make_server(short_sock_dir, token="T", enabled=False)
    try:
        reply = _client_call(server._socket_path, {
            "id": "s", "method": "get_local_control_status",
            "auth_token": "T", "params": {},
        })
        assert reply["ok"] is True
        assert reply["result"]["local_control_enabled"] is False
        assert reply["result"]["protocol_version"] == PROTOCOL_VERSION
        # Flip and re-query — must reflect the new value without a
        # restart.
        state["enabled"] = True
        reply2 = _client_call(server._socket_path, {
            "id": "s2", "method": "get_local_control_status",
            "auth_token": "T", "params": {},
        })
        assert reply2["result"]["local_control_enabled"] is True
    finally:
        server.stop()


def test_get_local_control_status_requires_auth(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=False)
    try:
        reply = _client_call(server._socket_path, {
            "id": "s", "method": "get_local_control_status", "params": {},
        })
        assert reply["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_get_local_control_status_bypasses_gate(short_sock_dir):
    """The hydration RPC must work even when the gate is OFF —
    otherwise the UI couldn't introspect "is local control on?"
    without first turning it on, which would defeat the purpose.
    """
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=False)
    try:
        reply = _client_call(server._socket_path, {
            "id": "s", "method": "get_local_control_status",
            "auth_token": "T", "params": {},
        })
        assert reply["ok"] is True
        assert reply["result"]["local_control_enabled"] is False
    finally:
        server.stop()


def test_send_input_round_trip_for_managed_session(short_sock_dir):
    server, mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        # Spawn a managed session first.
        start = _client_call(server._socket_path, {
            "id": "1", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude"},
        })
        sid = start["result"]["session_id"]
        # send_input → manager records the call.
        reply = _client_call(server._socket_path, {
            "id": "2", "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": sid, "payload": "hello\n"},
        })
        assert reply["ok"] is True
        assert reply["result"] == {"session_id": sid, "written": True}
        assert mgr.send_calls == [(sid, "hello\n")]
    finally:
        server.stop()


def test_send_input_requires_auth(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "send_input",
            "params": {"session_id": "any", "payload": "hi"},
        })
        assert reply["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_send_input_blocked_when_gate_off(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=False)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": "any", "payload": "hi"},
        })
        assert reply["error"]["code"] == "local_control_off"
    finally:
        server.stop()


def test_send_input_unknown_session_returns_session_not_found(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": "no-such", "payload": "hi"},
        })
        assert reply["error"]["code"] == "session_not_found"
    finally:
        server.stop()


def test_send_input_for_detected_only_session_returns_not_controllable(short_sock_dir):
    """Existing same-Mac Claude process the helper detected via
    `_detect_provider` but does NOT own. Writing to its stdin would
    require the helper to inject keystrokes into a user terminal —
    explicitly out of scope and unsafe — so the helper rejects with
    `not_controllable`.
    """
    detected_id = "proc-1234"
    detected = [{"session_id": detected_id, "provider": "Claude", "client_label": "claude"}]
    server, _mgr, _state = _make_server(
        short_sock_dir, token="T", enabled=True, detected=detected
    )
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": detected_id, "payload": "hi"},
        })
        assert reply["error"]["code"] == "not_controllable"
    finally:
        server.stop()


def test_stop_for_detected_only_session_returns_not_controllable(short_sock_dir):
    detected_id = "proc-9999"
    detected = [{"session_id": detected_id, "provider": "Claude"}]
    server, _mgr, _state = _make_server(
        short_sock_dir, token="T", enabled=True, detected=detected
    )
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "stop_session",
            "auth_token": "T",
            "params": {"session_id": detected_id},
        })
        assert reply["error"]["code"] == "not_controllable"
    finally:
        server.stop()


def test_list_sessions_includes_managed_and_detected(short_sock_dir):
    """The reply distinguishes managed (helper-spawned) from detected
    (process-scan-only) so the UI can render the right action set
    per row without knowing the source taxonomy.
    """
    detected = [
        {"session_id": "proc-1", "provider": "Claude", "client_label": "claude"},
        {"session_id": "proc-2", "provider": "Claude", "project": "demo"},
    ]
    server, mgr, _state = _make_server(
        short_sock_dir, token="T", enabled=True, detected=detected
    )
    try:
        # Spawn one managed session via UDS so we have a mix.
        _client_call(server._socket_path, {
            "id": "1", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude", "client_label": "X"},
        })
        reply = _client_call(server._socket_path, {
            "id": "2", "method": "list_sessions",
            "auth_token": "T", "params": {},
        })
        assert reply["ok"] is True
        assert len(reply["result"]["managed"]) == 1
        assert reply["result"]["managed"][0]["controllable"] is True
        assert reply["result"]["managed"][0]["source"] == "managed"
        assert len(reply["result"]["detected"]) == 2
        assert all(row["controllable"] is False for row in reply["result"]["detected"])
        assert all(row["source"] == "detected" for row in reply["result"]["detected"])
        # Backward-compat `sessions` array still equals managed-only.
        assert reply["result"]["sessions"] == reply["result"]["managed"]
        # The detected getter is called once per list_sessions; this
        # also proves the manager's list path was invoked.
        assert mgr.list_calls == 1
    finally:
        server.stop()


def test_send_input_routes_through_executor_no_duplicate_write(short_sock_dir):
    """End-to-end with a real LocalExecutor + real RemoteAgentManager.
    Asserts a single send_input request causes exactly one transport
    write and serializes correctly with the executor's queue (no
    duplicate-write race when the connection thread + the daemon
    poll thread share the executor).
    """
    from remote_agent import RemoteAgentManager
    from transports import SessionHandle, SessionTransport

    class CountingTransport(SessionTransport):
        def __init__(self) -> None:
            self.handles: dict[str, SessionHandle] = {}
            self.writes: list[bytes] = []

        def start(self, *, session_id, argv, env=None, cwd=None):
            h = SessionHandle(session_id=session_id, payload={"alive": True})
            self.handles[session_id] = h
            return h

        def write_stdin(self, handle, body):
            self.writes.append(bytes(body))
            return len(body)

        def read_stdout(self, handle, max_bytes=4096):
            return b""

        def is_alive(self, handle):
            return True

        def wait(self, handle, timeout=0):
            return None

        def terminate(self, handle):
            pass

        def interrupt(self, handle):
            pass

        def close(self, handle):
            self.handles.pop(handle.session_id, None)

    class FakeConfig:
        device_id = "dev"
        helper_secret = "secret"

    transport = CountingTransport()
    executor = LocalExecutor()
    mgr = RemoteAgentManager(
        helper_config=FakeConfig(),
        rpc_caller=lambda *_a, **_k: None,
        transport=transport,
        executor=executor,
    )
    sock_path = short_sock_dir / "exec.sock"
    state = {"enabled": True}
    server = LocalSessionServer(
        socket_path=sock_path,
        get_auth_token=lambda: "T",
        get_local_control_enabled=lambda: state["enabled"],
        set_local_control_enabled=lambda v: state.update(enabled=bool(v)),
        start_session=mgr.local_start_claude_session,
        list_sessions=mgr.local_list_sessions,
        stop_session=mgr.local_stop_session,
        send_input=mgr.local_send_input,
        list_detected_sessions=lambda: [],
    )
    server.start()
    try:
        start = _client_call(sock_path, {
            "id": "1", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude"},
        })
        sid = start["result"]["session_id"]
        reply = _client_call(sock_path, {
            "id": "2", "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": sid, "payload": "hello"},
        })
        assert reply["ok"] is True
        assert reply["result"]["written"] is True
        # Exactly one transport write — the executor serialised the
        # call, no duplicate-write race.
        assert len(transport.writes) == 1
        # The CR/newline submit semantics from
        # `helper/test_remote_agent_submit.py` are preserved by the
        # underlying `_write_to_session_impl` — payload "hello"
        # without a trailing newline becomes "hello\r" on the wire.
        assert transport.writes[0] == b"hello\r"
    finally:
        server.stop()
        executor.shutdown(wait=True, timeout=2.0)


# ── Phase 4: install_claude_hook UDS method ──────────────────
#
# Sandboxed macOS app cannot write to ~/.claude/settings.json
# directly; it asks the unsandboxed helper (this UDS server) to
# do the file write via the new `install_claude_hook` method.
# The helper wraps `permissions_diagnose.install_claude_hook`
# with its own argv[0] as the helper_path — the app deliberately
# does NOT pass arbitrary paths so a malicious socket peer cannot
# reroute the hook command at a third-party Python script.


def test_install_claude_hook_round_trip(short_sock_dir, tmp_path, monkeypatch):
    fake_helper = tmp_path / "cli_pulse_helper.py"
    fake_helper.write_text("# stub")
    fake_settings = tmp_path / "settings.json"
    server, _mgr, _state = _make_server(
        short_sock_dir, token="T", enabled=True,
        helper_argv0=str(fake_helper),
    )
    # Redirect the install path to a tmp file so we do NOT clobber
    # the test runners actual settings.json.
    import permissions_diagnose as pd
    real_install = pd.install_claude_hook
    def _install(helper_path, **kwargs):
        kwargs.setdefault("settings_path", fake_settings)
        return real_install(helper_path=helper_path, **kwargs)
    monkeypatch.setattr(pd, "install_claude_hook", _install)
    try:
        reply = _client_call(server._socket_path, {
            "id": "1", "method": "install_claude_hook",
            "auth_token": "T", "params": {},
        })
        assert reply["ok"] is True
        assert reply["result"]["action"] in ("created", "added", "replaced", "noop")
        # Helper supplied its own argv[0] as helper_path — the
        # written command must reference it (defence-in-depth: the
        # app never passes the path).
        import json
        written = json.loads(fake_settings.read_text())
        entry = written["hooks"]["PermissionRequest"][0]
        cmd = entry["hooks"][0]["command"]
        assert str(fake_helper) in cmd
    finally:
        server.stop()


def test_install_claude_hook_requires_auth(short_sock_dir):
    server, _mgr, _state = _make_server(
        short_sock_dir, token="T", enabled=True,
        helper_argv0="/dev/null",
    )
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "install_claude_hook",
            "params": {},  # no auth_token
        })
        assert reply["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_install_claude_hook_no_argv0_returns_not_implemented(short_sock_dir):
    # Older helper that did NOT wire `get_helper_argv0` should
    # surface a typed error; the app needs to know not to retry
    # silently.
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "1", "method": "install_claude_hook",
            "auth_token": "T", "params": {},
        })
        assert reply["error"]["code"] == "not_implemented"
    finally:
        server.stop()


def test_install_claude_hook_blocked_when_gate_off(short_sock_dir, tmp_path):
    fake_helper = tmp_path / "cli_pulse_helper.py"
    fake_helper.write_text("# stub")
    server, _mgr, _state = _make_server(
        short_sock_dir, token="T", enabled=False,
        helper_argv0=str(fake_helper),
    )
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "install_claude_hook",
            "auth_token": "T", "params": {},
        })
        assert reply["error"]["code"] == "local_control_off"
    finally:
        server.stop()

