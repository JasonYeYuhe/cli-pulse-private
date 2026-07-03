"""R0 (S3) — Python helper terminal-broadcast productionization.

Pins the three invariants that make the fleet-wide default-ON producer safe:

  1. LOCAL privacy gate (Gemini #2): `_post_stdout_chunk` submits to the
     broadcast producer ONLY for a session the start payload marked private.
     Public / unknown sessions never submit → zero mint calls, zero HTTP, so a
     default-ON producer can't hammer mint-realtime-token with 403s.
  2. Cloud `tail_snapshot` dispatcher: a private session's warm-resume snapshot
     is broadcast as `tail_snapshot_result`; a public session is a no-op success
     (client falls back to its 2 s timeout); an unowned session fails.
  3. Packaging + default: the gate defaults True in helper 1.24.0, both PyInstaller
     specs pin the lazily-imported `realtime_broadcast`, and the module imports
     with its expected producer symbols.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from remote_agent import (  # noqa: E402
    RemoteAgentManager,
    SessionStartParams,
    _ManagedSession,
)
from transports.base import SessionHandle, SessionTransport  # noqa: E402


class _StubTransport(SessionTransport):
    def start(self, *args, **kwargs):  # pragma: no cover — unused
        raise NotImplementedError

    def read_stdout(self, handle, max_bytes):  # pragma: no cover
        return b""

    def write_stdin(self, handle, data: bytes) -> int:  # pragma: no cover
        return len(data)

    # Mutable so the exit-observation test can simulate the child dying.
    alive: bool = True

    def is_alive(self, handle) -> bool:
        return self.alive

    def wait(self, handle, timeout=None):  # pragma: no cover
        return 0

    def interrupt(self, handle) -> None:  # pragma: no cover
        pass

    def terminate(self, handle) -> None:  # pragma: no cover
        pass

    def close(self, handle) -> None:  # pragma: no cover
        pass


@dataclass
class _StubHelperConfig:
    device_id: str = "00000000-0000-0000-0000-000000000000"
    helper_secret: str = "stub-secret"
    user_id: str = "00000000-0000-0000-0000-000000000000"


class _FakeBroadcastPublisher:
    """Records every submit/flush/forget so tests can assert what (didn't)
    reach the sink and that teardown purges per-session state."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, bytes]] = []
        self.flushed: list[str] = []
        self.forgotten: list[str] = []

    def submit(self, session_id: str, event: str, data: bytes) -> None:
        self.calls.append((session_id, event, bytes(data)))

    def flush(self, session_id: str) -> None:
        self.flushed.append(session_id)

    def forget(self, session_id: str) -> None:
        self.forgotten.append(session_id)


SID = "11111111-1111-1111-1111-111111111111"


def _make_manager(realtime_private, *, with_publisher=True):
    publisher = _FakeBroadcastPublisher() if with_publisher else None
    manager = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=lambda *_a, **_kw: None,  # pyright: ignore[reportArgumentType]
        transport=_StubTransport(),
        broadcast_publisher=publisher,
    )
    params = SessionStartParams(
        session_id=SID, provider="claude", realtime_private=realtime_private
    )
    manager._sessions[SID] = _ManagedSession(  # noqa: SLF001
        params=params, handle=SessionHandle(session_id=SID, payload=None), spawned_at=0.0
    )
    return manager, publisher


# ── 1. local privacy gate on the stdout stream ─────────────────


def test_post_stdout_broadcasts_only_a_private_session():
    manager, pub = _make_manager(realtime_private=True)
    manager._post_stdout_chunk(SID, "hello world\n")  # noqa: SLF001
    assert len(pub.calls) == 1
    sid, event, _data = pub.calls[0]
    assert sid == SID
    assert event == "stdout"


def test_post_stdout_skips_a_public_session():
    manager, pub = _make_manager(realtime_private=False)
    manager._post_stdout_chunk(SID, "hello world\n")  # noqa: SLF001
    assert pub.calls == [], "public session must never reach the broadcast producer"


def test_post_stdout_skips_unknown_privacy_fail_closed():
    # None = no authoritative privacy source (pre-v0.61 payload / local session).
    manager, pub = _make_manager(realtime_private=None)
    manager._post_stdout_chunk(SID, "hello world\n")  # noqa: SLF001
    assert pub.calls == [], "unknown privacy must fail-closed (no broadcast, no mint)"


# ── 2. cloud tail_snapshot dispatcher ──────────────────────────


def _dispatch(manager, kind, session_id=SID, payload=""):
    manager._dispatch_one({  # noqa: SLF001
        "id": "cmd-1", "kind": kind, "session_id": session_id, "payload": payload,
    })


def test_dispatch_tail_snapshot_broadcasts_result_for_private():
    manager, pub = _make_manager(realtime_private=True)
    # Seed the ring so there's something to snapshot.
    manager._post_stdout_chunk(SID, "screen state\n")  # noqa: SLF001
    pub.calls.clear()
    _dispatch(manager, "tail_snapshot", payload="8192")
    assert len(pub.calls) == 1
    _sid, event, data = pub.calls[0]
    assert event == "tail_snapshot_result"
    assert b"screen state" in data


def test_dispatch_tail_snapshot_is_noop_success_for_public():
    manager, pub = _make_manager(realtime_private=False)
    manager._post_stdout_chunk(SID, "screen state\n")  # noqa: SLF001
    pub.calls.clear()
    _dispatch(manager, "tail_snapshot", payload="8192")
    assert pub.calls == [], "public session snapshot must not hit the public path"


def test_dispatch_tail_snapshot_unknown_session_fails():
    manager, pub = _make_manager(realtime_private=True)
    completed: list[dict] = []
    manager.rpc_caller = lambda name, params: completed.append(params) or None  # type: ignore[assignment]
    _dispatch(manager, "tail_snapshot", session_id="99999999-9999-9999-9999-999999999999")
    assert pub.calls == []
    assert completed and completed[0]["p_status"] == "failed"


# ── 2b. teardown purges broadcast state on the CHILD-EXIT path ─


def test_child_exit_flushes_and_forgets_broadcast_state():
    # 2026-07-03 review: child-exit (/exit, Ctrl-D, CLI crash) is the MOST
    # COMMON session end, but only the explicit-stop path purged the
    # publisher's per-session token/denial/retry caches — violating their
    # "bounded to LIVE sessions" contract on the long-lived daemon.
    manager, pub = _make_manager(realtime_private=True)
    manager.transport.alive = False  # simulate the child dying on its own
    manager._observe_exits()  # noqa: SLF001
    assert SID in pub.flushed, "final coalesced chunk must be flushed on exit"
    assert SID in pub.forgotten, "per-session broadcast caches must be purged on exit"
    assert SID not in manager._sessions  # noqa: SLF001


# ── 3. packaging + default ─────────────────────────────────────


def test_broadcast_gate_defaults_true_in_1_24():
    from cli_pulse_helper import HelperConfig  # noqa: PLC0415
    cfg = HelperConfig(
        device_id="d", user_id="u", device_name="dev", helper_version="1.24.0"
    )
    assert cfg.remote_realtime_broadcast_enabled is True


def test_both_specs_pin_realtime_broadcast_hiddenimport():
    # The lazy `from realtime_broadcast import ...` under a conditional can be
    # dropped by PyInstaller's static graph — both specs must pin it explicitly.
    for spec in ("cli_pulse_helper_pkg.spec", "cli_pulse_helper.spec"):
        text = (HELPER_DIR / spec).read_text(encoding="utf-8")
        assert '"realtime_broadcast"' in text, f"{spec} missing realtime_broadcast hiddenimport"


def test_realtime_broadcast_imports_with_producer_symbols():
    import realtime_broadcast  # noqa: PLC0415
    for sym in ("RealtimeBroadcastSink", "RealtimeTokenClient", "TerminalBroadcastPublisher"):
        assert hasattr(realtime_broadcast, sym), f"realtime_broadcast missing {sym}"
