"""Helper-restart wire-level integration test.

Codex review on PR #18 manual test surfaced two related bugs:
  1. macOS app's `shouldRouteSessionLocally` device_id fallback let
     stale Supabase rows from a previous helper process masquerade
     as locally controllable.
  2. `RemoteAgentManager._dispatch_one` for `kind=="stop"` /
     `"interrupt"` reported `delivered` for a no-op when the helper
     didn't own the session.

Both were unit-tested separately. This file adds one full wire-level
scenario test: drive a real `LocalSessionServer` + `RemoteAgentManager`
combo through Python UDS framing, simulate a helper restart by
tearing the manager+server down and standing up a fresh pair on the
same socket path, and assert that the new helper:
  * does not list the previous helper's session in `list_sessions`
  * returns `session_not_found` for `send_input` / `stop_session`
    on the previous helper's session id
  * accepts a brand-new `start_session` and lists it
  * — i.e. the post-restart wire surface matches the contract the
    macOS app's iter-2B+ routing now requires.

The session lifecycle uses the same `_FakeManager` stub as the
existing streaming tests rather than spawning a real Claude PTY —
the wire format and the manager state machine are what we care
about here, not the PTY details (which the existing
`test_local_session_server.py` covers via PosixPtyTransport tests).
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
    parent = "/tmp" if Path("/tmp").exists() else tempfile.gettempdir()
    d = tempfile.mkdtemp(prefix="cps_restart_", dir=parent)
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


# ── helpers (mirrors test_local_session_server_streaming.py) ───


class _FakeManager:
    """Per-helper-process state. Each instance simulates the
    in-memory session table the real RemoteAgentManager keeps. A
    fresh instance models a helper restart — empty session table
    even if the previous instance had spawned sessions.

    Uses real UUIDs for session ids so two manager instances never
    accidentally collide on a counter. Real `RemoteAgentManager`
    uses `uuid.uuid4()` too — so this also matches the wire shape
    the macOS app expects.
    """

    def __init__(self) -> None:
        self._sessions: list[dict] = []

    def local_start_claude_session(self, payload: dict) -> dict:
        import uuid
        sid = str(uuid.uuid4())
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
        before = len(self._sessions)
        self._sessions = [s for s in self._sessions if s["session_id"] != session_id]
        return {"session_id": session_id, "stopped": before != len(self._sessions)}

    def local_send_input(self, session_id: str, payload: str) -> dict:
        owns = any(s["session_id"] == session_id for s in self._sessions)
        return {"session_id": session_id, "written": owns}


def _make_server(
    sock_path: Path,
    *,
    manager: _FakeManager,
    token: str = "T",
) -> LocalSessionServer:
    state = {"enabled": True}
    broker = EventBroker(heartbeat_interval_s=None)
    registry = ApprovalRegistry(on_event=broker.publish, allow_descent_skip=True)
    registry.peer_pid_resolver = None
    server = LocalSessionServer(
        socket_path=sock_path,
        get_auth_token=lambda: token,
        get_local_control_enabled=lambda: state["enabled"],
        set_local_control_enabled=lambda v: state.update(enabled=bool(v)),
        start_session=manager.local_start_claude_session,
        list_sessions=manager.local_list_sessions,
        stop_session=manager.local_stop_session,
        send_input=manager.local_send_input,
        list_detected_sessions=lambda: [],
        event_broker=broker,
        approval_registry=registry,
        subscribe_idle_timeout_s=0.3,
    )
    server.start()
    return server


def _call(sock_path: Path, body: dict, timeout: float = 1.5) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect(str(sock_path))
    try:
        payload = json.dumps(body).encode("utf-8")
        s.sendall(struct.pack("!I", len(payload)) + payload)
        # length-prefixed read
        header = b""
        while len(header) < 4:
            chunk = s.recv(4 - len(header))
            if not chunk:
                raise RuntimeError("EOF before header")
            header += chunk
        (length,) = struct.unpack("!I", header)
        body_buf = b""
        while len(body_buf) < length:
            chunk = s.recv(length - len(body_buf))
            if not chunk:
                raise RuntimeError("EOF mid-body")
            body_buf += chunk
        return json.loads(body_buf.decode("utf-8"))
    finally:
        s.close()


# ── scenarios ──────────────────────────────────────────────


def test_helper_restart_drops_previous_sessions_from_wire_surface(short_sock_dir):
    """Spin up helper-1, start a session, tear helper-1 down,
    stand up helper-2 on the same socket path, verify helper-2's
    `list_sessions` is empty AND `send_input` / `stop_session`
    on the previous helper's session id return the typed error
    `session_not_found` (not "delivered"-style silent success).

    This is the wire-level e2e companion to:
      * test_remote_agent.test_dispatch_stop_for_unknown_session_completes_failed
        (server-side queue path)
      * SessionControlIntegrationGapTests.testHelperRestartSimulation_*
        (Swift state-reconciliation path)
    """
    sock_path = short_sock_dir / "clipulse-helper.sock"

    # ── helper-1 lifecycle ────────────────────────────────
    manager_1 = _FakeManager()
    server_1 = _make_server(sock_path, manager=manager_1)
    try:
        # Sanity: hello + start_session work end-to-end.
        hello = _call(sock_path, {"id": "h", "method": "hello", "params": {}})
        assert hello["ok"] is True

        start = _call(sock_path, {
            "id": "s1",
            "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude", "client_label": "before-restart"},
        })
        assert start["ok"] is True
        previous_sid = start["result"]["session_id"]
        assert previous_sid

        # helper-1 lists the new session.
        listed = _call(sock_path, {
            "id": "l1",
            "method": "list_sessions",
            "auth_token": "T",
            "params": {},
        })
        assert listed["ok"] is True
        managed_ids = [r["session_id"] for r in listed["result"]["managed"]]
        assert previous_sid in managed_ids
    finally:
        server_1.stop()

    # ── helper-2 simulates restart ────────────────────────
    # Brand-new manager + server. Same socket path. `_FakeManager`
    # carries no memory of helper-1's sessions, mirroring how the
    # real `RemoteAgentManager` rebuilds its `_sessions` dict from
    # scratch on each helper process spawn.
    manager_2 = _FakeManager()
    server_2 = _make_server(sock_path, manager=manager_2)
    try:
        # The new helper's `list_sessions` MUST NOT carry the
        # previous helper's session id. Pre-fix this part already
        # worked at the helper level — what was broken was the
        # macOS app's interpretation of stale Supabase rows. We
        # pin this to make sure no future refactor accidentally
        # persists session state across helper processes.
        listed = _call(sock_path, {
            "id": "l2",
            "method": "list_sessions",
            "auth_token": "T",
            "params": {},
        })
        assert listed["ok"] is True
        managed_ids = [r["session_id"] for r in listed["result"]["managed"]]
        assert previous_sid not in managed_ids, \
            "helper-2 must NOT see helper-1's sessions in list_sessions"

        # send_input(previous_sid) must surface session_not_found —
        # this is the surface the macOS app sees when its stale
        # local-routing tries to talk to the new helper. Before
        # the fix, the app's device_id fallback let it think the
        # session was still locally owned, so it called
        # send_input(stale) and got this typed error every tick.
        send = _call(sock_path, {
            "id": "si1",
            "method": "send_input",
            "auth_token": "T",
            "params": {"session_id": previous_sid, "payload": "hello"},
        })
        assert send["ok"] is False
        assert send["error"]["code"] == "session_not_found"

        # stop_session(previous_sid) must also surface
        # session_not_found. The macOS app's iter-2B+ stale-row
        # routing no longer dispatches local Stop for stale ids;
        # this assertion guards the helper-side contract that
        # would catch any future regression in that routing.
        stop = _call(sock_path, {
            "id": "st1",
            "method": "stop_session",
            "auth_token": "T",
            "params": {"session_id": previous_sid},
        })
        assert stop["ok"] is False
        assert stop["error"]["code"] == "session_not_found"

        # Brand-new start on helper-2 produces a fresh session id
        # (not the previous one) and is listed correctly. This is
        # the smoke that helper-2 is functional, not just empty.
        start_2 = _call(sock_path, {
            "id": "s2",
            "method": "start_session",
            "auth_token": "T",
            "params": {"provider": "claude", "client_label": "after-restart"},
        })
        assert start_2["ok"] is True
        new_sid = start_2["result"]["session_id"]
        assert new_sid
        assert new_sid != previous_sid

        listed_2 = _call(sock_path, {
            "id": "l3",
            "method": "list_sessions",
            "auth_token": "T",
            "params": {},
        })
        assert listed_2["ok"] is True
        managed_ids_2 = [r["session_id"] for r in listed_2["result"]["managed"]]
        assert new_sid in managed_ids_2
        assert previous_sid not in managed_ids_2
    finally:
        server_2.stop()


def test_get_pending_approvals_for_stale_session_returns_empty(short_sock_dir):
    """Tighter wire-level pin for the same scenario: the macOS app
    used to repeatedly poll `get_pending_approvals(session=stale)`
    after a helper restart (visible in the helper log on Jason's
    manual test). The Swift fix guards that call from the client
    side, but the helper's own response for an unknown session
    should be a clean empty list — NOT an error, because
    `get_pending_approvals` for a session the helper doesn't own
    is genuinely "no pending" (nothing happened).

    Pin the contract so a future refactor that tightens this to
    `session_not_found` (which would also be reasonable) doesn't
    silently change the wire shape.
    """
    sock_path = short_sock_dir / "clipulse-helper.sock"
    manager = _FakeManager()
    server = _make_server(sock_path, manager=manager)
    try:
        out = _call(sock_path, {
            "id": "p1",
            "method": "get_pending_approvals",
            "auth_token": "T",
            "params": {"session_id": "stale-id-from-previous-helper"},
        })
        assert out["ok"] is True
        assert out["result"]["pending_approvals"] == []
    finally:
        server.stop()
