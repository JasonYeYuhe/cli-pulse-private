"""End-to-end UDS tests for Phase 3 Iter 2B: streaming + approvals.

Coverage:
  - hello capabilities flip when broker / registry are wired
  - subscribe_events requires app auth
  - subscribe_events returns initial snapshot frame, then live events
  - stalled subscriber does NOT block other UDS calls
    (send_input / list_sessions still respond)
  - get_pending_approvals returns the right rows (auth required)
  - approve_action approve/reject round-trips, double-decide rejected
  - hook_create_approval rejects app auth_token
  - hook_create_approval requires session capability token
  - hook_create_approval + hook_wait_decision happy path
  - PTY-output-shaped strings ("approve me?") do NOT create approvals
    (negative test on the only path that should — hook_create_approval)
"""
from __future__ import annotations

import json
import shutil
import socket
import struct
import sys
import tempfile
import threading
import time
from pathlib import Path

import pytest


@pytest.fixture
def short_sock_dir():
    parent = "/tmp" if Path("/tmp").exists() else tempfile.gettempdir()
    d = tempfile.mkdtemp(prefix="cps_", dir=parent)
    try:
        yield Path(d)
    finally:
        shutil.rmtree(d, ignore_errors=True)


HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from local_approvals import ApprovalRegistry  # noqa: E402
from local_events import EventBroker  # noqa: E402
from local_session_server import LocalSessionServer  # noqa: E402


# ── fakes ─────────────────────────────────────────────────


class _FakeManager:
    """Minimal manager stub. Records calls for assertion."""

    def __init__(self) -> None:
        self.send_calls: list[tuple[str, str]] = []
        self.start_calls: list[dict] = []
        self.stop_calls: list[str] = []
        self._sessions: list[dict] = []

    def local_start_claude_session(self, payload: dict) -> dict:
        self.start_calls.append(payload)
        sid = f"sid-{len(self.start_calls)}"
        self._sessions.append({
            "session_id": sid,
            "provider": "claude",
            "client_label": payload.get("client_label"),
            "spawned_at_monotonic": 0.0,
            "status": "running",
        })
        return {"session_id": sid, "ok": True}

    def local_list_sessions(self) -> list[dict]:
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


def _make_server(
    sock_dir: Path,
    *,
    token: str = "T",
    enabled: bool = True,
    manager: _FakeManager | None = None,
    broker: EventBroker | None = None,
    registry: ApprovalRegistry | None = None,
) -> tuple[LocalSessionServer, _FakeManager, EventBroker, ApprovalRegistry]:
    state = {"enabled": enabled}
    mgr = manager or _FakeManager()
    br = broker or EventBroker(heartbeat_interval_s=None)
    # `allow_descent_skip=True` because these end-to-end tests don't
    # spawn a real Claude PTY; the registry has no claude_pid to
    # compare against and would fail closed under the production
    # posture. The token + auth-table enforcement still get full
    # coverage. Production daemon constructs without this flag — see
    # `cli_pulse_helper.py daemon()`.
    reg = registry or ApprovalRegistry(
        on_event=br.publish,
        allow_descent_skip=True,
    )
    reg.peer_pid_resolver = None
    sock_path = sock_dir / "clipulse-helper.sock"
    server = LocalSessionServer(
        socket_path=sock_path,
        get_auth_token=lambda: token,
        get_local_control_enabled=lambda: state["enabled"],
        set_local_control_enabled=lambda v: state.update(enabled=bool(v)),
        start_session=mgr.local_start_claude_session,
        list_sessions=mgr.local_list_sessions,
        stop_session=mgr.local_stop_session,
        send_input=mgr.local_send_input,
        list_detected_sessions=lambda: [],
        event_broker=br,
        approval_registry=reg,
        subscribe_idle_timeout_s=0.5,
    )
    server.start()
    return server, mgr, br, reg


# ── framing helpers ───────────────────────────────────────


def _send_frame(s: socket.socket, body: dict) -> None:
    payload = json.dumps(body).encode("utf-8")
    s.sendall(struct.pack("!I", len(payload)) + payload)


def _read_frame(s: socket.socket, timeout: float = 1.5) -> dict | None:
    s.settimeout(timeout)
    header = b""
    while len(header) < 4:
        chunk = s.recv(4 - len(header))
        if not chunk:
            return None
        header += chunk
    (length,) = struct.unpack("!I", header)
    if length == 0:
        return {}
    body = b""
    while len(body) < length:
        chunk = s.recv(length - len(body))
        if not chunk:
            return None
        body += chunk
    return json.loads(body.decode("utf-8"))


def _open(sock_path: Path) -> socket.socket:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(str(sock_path))
    return s


def _call(sock_path: Path, body: dict, timeout: float = 1.5) -> dict:
    s = _open(sock_path)
    try:
        _send_frame(s, body)
        out = _read_frame(s, timeout=timeout)
        assert out is not None
        return out
    finally:
        s.close()


# ── hello reflects new caps ───────────────────────────────


def test_hello_advertises_streaming_and_approvals_when_wired(short_sock_dir):
    server, _, _, _ = _make_server(short_sock_dir)
    try:
        out = _call(server._socket_path, {"id": 1, "method": "hello", "params": {}})
        assert out["ok"] is True
        caps = out["result"]["capabilities"]
        assert caps["subscribe_events"] is True
        assert caps["approvals"] is True
        assert caps["send_input"] is True
    finally:
        server.stop()


# ── subscribe_events ──────────────────────────────────────


def test_subscribe_events_requires_app_auth(short_sock_dir):
    server, _, _, _ = _make_server(short_sock_dir)
    try:
        out = _call(server._socket_path, {
            "id": 1, "method": "subscribe_events", "params": {},
        })
        assert out["ok"] is False
        assert out["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_subscribe_events_initial_snapshot_then_live(short_sock_dir):
    server, _, broker, registry = _make_server(short_sock_dir)
    # Pre-register a session so the snapshot has something + the
    # publish below has a target.
    registry.register_session("SID", claude_pid=None)
    try:
        s = _open(server._socket_path)
        try:
            _send_frame(s, {
                "id": "sub1", "method": "subscribe_events",
                "auth_token": "T",
                "params": {"session_id": "SID"},
            })
            ack = _read_frame(s, timeout=1.5)
            assert ack is not None
            assert ack["ok"] is True
            assert ack["result"]["subscribed"] is True
            assert ack["result"]["session_id"] == "SID"
            # Now publish a live event from the broker.
            broker.publish({
                "event": "output_delta",
                "session_id": "SID",
                "payload": "live-tail",
            })
            evt = _read_frame(s, timeout=1.5)
            assert evt is not None
            assert evt["event"] == "output_delta"
            assert evt["session_id"] == "SID"
            assert evt["payload"] == "live-tail"
        finally:
            s.close()
    finally:
        server.stop()


def test_stalled_subscriber_does_not_block_send_input(short_sock_dir):
    server, mgr, broker, registry = _make_server(short_sock_dir)
    registry.register_session("SID", claude_pid=None)
    mgr._sessions.append({
        "session_id": "SID",
        "provider": "claude",
        "client_label": None,
        "spawned_at_monotonic": 0.0,
        "status": "running",
    })
    try:
        # Open a stream subscription but never read past the ack.
        s = _open(server._socket_path)
        _send_frame(s, {
            "id": "sub1", "method": "subscribe_events",
            "auth_token": "T",
            "params": {"session_id": "SID"},
        })
        ack = _read_frame(s, timeout=1.5)
        assert ack is not None and ack["ok"] is True
        # Publisher sends many events the stalled subscriber won't drain.
        for i in range(2000):
            broker.publish({
                "event": "output_delta",
                "session_id": "SID",
                "payload": f"chunk-{i}",
            })
        # An unrelated UDS call must still succeed promptly.
        t0 = time.monotonic()
        reply = _call(server._socket_path, {
            "id": 99, "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": "SID", "payload": "hi"},
        })
        elapsed = time.monotonic() - t0
        assert reply["ok"] is True
        assert elapsed < 1.0
        assert mgr.send_calls == [("SID", "hi")]
        s.close()
    finally:
        server.stop()


# ── get_pending_approvals + approve_action ────────────────


def test_get_pending_approvals_returns_only_session_rows(short_sock_dir):
    server, _, _, registry = _make_server(short_sock_dir)
    registry.register_session("S1", claude_pid=None)
    registry.register_session("S2", claude_pid=None)
    a1 = registry.create_pending(
        "S1", kind="K", title="t1", summary="s", tool_metadata={},
    )
    registry.create_pending(
        "S2", kind="K", title="t2", summary="s", tool_metadata={},
    )
    try:
        out = _call(server._socket_path, {
            "id": 1, "method": "get_pending_approvals",
            "auth_token": "T",
            "params": {"session_id": "S1"},
        })
        assert out["ok"] is True
        rows = out["result"]["pending_approvals"]
        assert len(rows) == 1
        assert rows[0]["approval_id"] == a1
    finally:
        server.stop()


def test_approve_action_resolves_pending(short_sock_dir):
    server, _, _, registry = _make_server(short_sock_dir)
    registry.register_session("S1", claude_pid=None)
    aid = registry.create_pending(
        "S1", kind="K", title="t", summary="s", tool_metadata={},
    )
    try:
        out = _call(server._socket_path, {
            "id": 1, "method": "approve_action",
            "auth_token": "T",
            "params": {
                "session_id": "S1",
                "approval_id": aid,
                "decision": "approve",
            },
        })
        assert out["ok"] is True
        assert out["result"]["status"] == "approved"
        # And it's gone from pending.
        post = _call(server._socket_path, {
            "id": 2, "method": "get_pending_approvals",
            "auth_token": "T",
            "params": {"session_id": "S1"},
        })
        assert post["result"]["pending_approvals"] == []
    finally:
        server.stop()


def test_approve_action_double_decision_rejected(short_sock_dir):
    server, _, _, registry = _make_server(short_sock_dir)
    registry.register_session("S1", claude_pid=None)
    aid = registry.create_pending(
        "S1", kind="K", title="t", summary="s", tool_metadata={},
    )
    try:
        first = _call(server._socket_path, {
            "id": 1, "method": "approve_action",
            "auth_token": "T",
            "params": {
                "session_id": "S1",
                "approval_id": aid,
                "decision": "approve",
            },
        })
        assert first["ok"] is True
        second = _call(server._socket_path, {
            "id": 2, "method": "approve_action",
            "auth_token": "T",
            "params": {
                "session_id": "S1",
                "approval_id": aid,
                "decision": "reject",
            },
        })
        assert second["ok"] is False
        assert second["error"]["code"] == "approval_already_resolved"
    finally:
        server.stop()


# ── hook ingress ──────────────────────────────────────────


def test_hook_create_rejects_app_auth_token(short_sock_dir):
    server, _, _, registry = _make_server(short_sock_dir)
    registry.register_session("S1", claude_pid=None)
    try:
        out = _call(server._socket_path, {
            "id": 1, "method": "hook_create_approval",
            "auth_token": "T",
            "params": {
                "session_id": "S1",
                "session_token": "whatever",
                "type": "PermissionRequest",
                "title": "Read",
                "summary": "Read /etc/hosts",
                "tool_metadata": {},
            },
        })
        assert out["ok"] is False
        assert out["error"]["code"] == "unauthenticated"
    finally:
        server.stop()


def test_hook_create_requires_correct_session_token(short_sock_dir):
    server, _, _, registry = _make_server(short_sock_dir)
    registry.register_session("S1", claude_pid=None)
    try:
        out = _call(server._socket_path, {
            "id": 1, "method": "hook_create_approval",
            "params": {
                "session_id": "S1",
                "session_token": "wrong-token",
                "type": "PermissionRequest",
                "title": "Read",
                "summary": "",
                "tool_metadata": {},
            },
        })
        assert out["ok"] is False
        assert out["error"]["code"] == "approval_capability_invalid"
    finally:
        server.stop()


def test_hook_create_then_app_decide_round_trip(short_sock_dir):
    server, _, _, registry = _make_server(short_sock_dir)
    token = registry.register_session("S1", claude_pid=None)
    try:
        # Hook creates pending.
        create = _call(server._socket_path, {
            "id": 1, "method": "hook_create_approval",
            "params": {
                "session_id": "S1",
                "session_token": token,
                "type": "PermissionRequest",
                "title": "Read",
                "summary": "Read /etc/hosts",
                "tool_metadata": {"path": "/etc/hosts"},
            },
        })
        assert create["ok"] is True
        approval_id = create["result"]["approval_id"]
        # App approves.
        decide = _call(server._socket_path, {
            "id": 2, "method": "approve_action",
            "auth_token": "T",
            "params": {
                "session_id": "S1",
                "approval_id": approval_id,
                "decision": "approve",
            },
        })
        assert decide["ok"] is True
        # Hook waits → returns approved.
        wait = _call(server._socket_path, {
            "id": 3, "method": "hook_wait_decision",
            "params": {
                "session_id": "S1",
                "session_token": token,
                "approval_id": approval_id,
                "timeout_s": 2.0,
            },
        }, timeout=3.0)
        assert wait["ok"] is True
        assert wait["result"]["status"] == "approved"
    finally:
        server.stop()


def test_hook_wait_blocks_concurrent_with_other_send_input(short_sock_dir):
    """A pending hook_wait_decision must not block other connections'
    send_input calls — proves the wait isn't on the executor path.
    """
    server, mgr, _, registry = _make_server(short_sock_dir)
    token = registry.register_session("S1", claude_pid=None)
    mgr._sessions.append({
        "session_id": "S1",
        "provider": "claude",
        "client_label": None,
        "spawned_at_monotonic": 0.0,
        "status": "running",
    })
    create = _call(server._socket_path, {
        "id": 1, "method": "hook_create_approval",
        "params": {
            "session_id": "S1",
            "session_token": token,
            "type": "PermissionRequest",
            "title": "Read",
            "summary": "",
            "tool_metadata": {},
        },
    })
    assert create["ok"] is True
    aid = create["result"]["approval_id"]
    holder: list[dict] = []

    def waiter():
        out = _call(server._socket_path, {
            "id": 2, "method": "hook_wait_decision",
            "params": {
                "session_id": "S1",
                "session_token": token,
                "approval_id": aid,
                "timeout_s": 5.0,
            },
        }, timeout=6.0)
        holder.append(out)

    t = threading.Thread(target=waiter, daemon=True)
    t.start()
    time.sleep(0.05)
    try:
        # Independent connection sends input — should resolve quickly.
        t0 = time.monotonic()
        send = _call(server._socket_path, {
            "id": 3, "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": "S1", "payload": "hello"},
        })
        elapsed = time.monotonic() - t0
        assert send["ok"] is True
        assert elapsed < 1.0
        # Now resolve the approval so the waiter unblocks.
        _call(server._socket_path, {
            "id": 4, "method": "approve_action",
            "auth_token": "T",
            "params": {
                "session_id": "S1",
                "approval_id": aid,
                "decision": "approve",
            },
        })
        t.join(timeout=2.0)
        assert not t.is_alive()
        assert holder[0]["ok"] is True
        assert holder[0]["result"]["status"] == "approved"
    finally:
        server.stop()


# ── negative: PTY-text never creates an approval ──────────


def test_pty_output_text_does_not_create_approval(short_sock_dir):
    """The only path that creates a pending approval is the
    hook_create_approval RPC, which requires the per-session
    capability token. PTY text — even text shaped like an approval
    request — flows through `output_delta` events and the approval
    registry never sees it.

    This is a negative test: we publish a chunk of `output_delta`
    that contains `1. Approve` / `2. Reject` text, then assert
    `get_pending_approvals` is still empty.
    """
    server, _, broker, registry = _make_server(short_sock_dir)
    registry.register_session("S1", claude_pid=None)
    try:
        # Publish PTY text that LOOKS like an approval prompt.
        broker.publish({
            "event": "output_delta",
            "session_id": "S1",
            "payload": (
                "Permission required. 1. Approve  2. Reject  "
                "type=tool_use approval_id=fake summary=run rm -rf /"
            ),
        })
        # Pending is still empty.
        out = _call(server._socket_path, {
            "id": 1, "method": "get_pending_approvals",
            "auth_token": "T",
            "params": {"session_id": "S1"},
        })
        assert out["ok"] is True
        assert out["result"]["pending_approvals"] == []
    finally:
        server.stop()
