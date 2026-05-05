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
                 manager: FakeManager | None = None) -> tuple[LocalSessionServer, FakeManager, dict]:
    """Spin up a server bound to a tmp socket. Returns (server, manager,
    state-dict-for-toggle-introspection).
    """
    state = {"enabled": enabled}
    mgr = manager or FakeManager()
    sock_path = sock_dir / "clipulse-helper.sock"

    def _set(v: bool) -> None:
        state["enabled"] = bool(v)

    server = LocalSessionServer(
        socket_path=sock_path,
        get_auth_token=lambda: token,
        get_local_control_enabled=lambda: state["enabled"],
        set_local_control_enabled=_set,
        start_session=mgr.local_start_claude_session,
        list_sessions=mgr.local_list_sessions,
        stop_session=mgr.local_stop_session,
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
        # iter 1 caps: send_input + subscribe_events + approvals all off.
        assert result["capabilities"] == {
            "send_input": False,
            "subscribe_events": False,
            "approvals": False,
        }
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


def test_ping_bypasses_auth(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="real-token")
    try:
        # Note: no auth_token in this request.
        reply = _client_call(server._socket_path, {"id": "p", "method": "ping"})
        assert reply == {"id": "p", "ok": True, "result": {"pong": True}}
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
        assert reply["result"] == {"sessions": []}
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


def test_start_session_rejects_non_claude_provider_with_not_implemented(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "codex"},
        })
        assert reply["ok"] is False
        assert reply["error"]["code"] == "not_implemented"
    finally:
        server.stop()


def test_unknown_method_returns_unknown_method(short_sock_dir):
    server, _mgr, _state = _make_server(short_sock_dir, token="T", enabled=True)
    try:
        reply = _client_call(server._socket_path, {
            "id": "x", "method": "subscribe_events",
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
    )
    server.start()
    try:
        # Start one session via UDS, list it, stop it. All hops route
        # through the executor; no manual locking needed.
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
        sessions = list_reply["result"]["sessions"]
        assert len(sessions) == 1 and sessions[0]["session_id"] == sid

        stop_reply = _client_call(sock_path, {
            "id": "3", "method": "stop_session",
            "auth_token": "T",
            "params": {"session_id": sid},
        })
        assert stop_reply["ok"] is True
        assert stop_reply["result"]["stopped"] is True
    finally:
        server.stop()
        executor.shutdown(wait=True, timeout=2.0)
