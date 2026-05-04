"""Submit-semantics unit test for `RemoteAgentManager.write_to_session`.

Manual UI testing showed that prompts typed into a managed Claude
session were echoed in claude's TUI input field but never submitted —
the helper appended `\\n` to the payload, but Claude Code's TUI runs
in raw mode with bracketed-paste enabled (CSI ?2004h) where LF means
"more text being pasted" and CR means "Enter / submit." Fix: append
`\\r` instead of `\\n`. This test pins the new behavior with an
in-memory transport stub so we never regress to LF-only.
"""
from __future__ import annotations

import sys
from dataclasses import dataclass
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from remote_agent import (  # noqa: E402
    RemoteAgentManager,
    SessionStartParams,
    _ManagedSession,
)
from transports.base import SessionHandle, SessionTransport  # noqa: E402


# ── stub transport that captures every write ───────────────────


@dataclass
class _Captured:
    handle: SessionHandle
    data: bytes


class _StubTransport(SessionTransport):
    def __init__(self) -> None:
        self.writes: list[_Captured] = []

    def start(self, *args, **kwargs):  # pragma: no cover — unused in this test
        raise NotImplementedError

    def read_stdout(self, handle, max_bytes):  # pragma: no cover
        return b""

    def write_stdin(self, handle, data: bytes) -> int:
        self.writes.append(_Captured(handle=handle, data=data))
        return len(data)

    def is_alive(self, handle) -> bool:
        return True

    def wait(self, handle, timeout=None):  # pragma: no cover
        return 0

    def interrupt(self, handle) -> None:  # pragma: no cover
        pass

    def terminate(self, handle) -> None:  # pragma: no cover
        pass

    def close(self, handle) -> None:  # pragma: no cover
        pass


# ── shared fixtures ────────────────────────────────────────────


@dataclass
class _StubHelperConfig:
    device_id: str = "00000000-0000-0000-0000-000000000000"
    helper_secret: str = "stub-secret"
    user_id: str = "00000000-0000-0000-0000-000000000000"


def _make_manager_with_session(session_id: str = "11111111-1111-1111-1111-111111111111"):
    """Build a manager with a stubbed transport and inject one fake
    running session so write_to_session can find it without going
    through the real spawn path."""
    transport = _StubTransport()
    manager = RemoteAgentManager(
        helper_config=_StubHelperConfig(),
        rpc_caller=lambda *_a, **_kw: None,  # pyright: ignore[reportArgumentType]
        transport=transport,
    )
    handle = SessionHandle(session_id=session_id, payload=None)
    # Inject directly into the private session map. Production code
    # would set this via _handle_start; we want to exercise only the
    # write path here.
    params = SessionStartParams(session_id=session_id, provider="claude")
    manager._sessions[session_id] = _ManagedSession(  # noqa: SLF001
        params=params,
        handle=handle,
        spawned_at=0.0,
    )
    return manager, transport


# ── 1. Plain payload gets a trailing CR appended ───────────────


def test_plain_payload_appended_with_cr_not_lf():
    """No trailing terminator → append `\\r` so Claude TUI submits."""
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session(sid, "hello")
    assert ok is True

    assert len(transport.writes) == 1
    written = transport.writes[0].data
    assert written == b"hello\r"
    assert not written.endswith(b"\n"), "must NOT end with LF — that's the bug we fixed"


# ── 2. Trailing LF in payload is replaced with CR ─────────────


def test_trailing_lf_is_replaced_with_cr():
    """User pastes `hello\\n` → helper rewrites to `hello\\r` so the
    prompt is submitted, not treated as continuation paste."""
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session(sid, "hello\n")
    assert ok is True
    assert transport.writes[0].data == b"hello\r"


# ── 3. Trailing CRLF is normalized to CR ───────────────────────


def test_trailing_crlf_is_normalized_to_cr():
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session(sid, "hello\r\n")
    assert ok is True
    assert transport.writes[0].data == b"hello\r"


# ── 4. Trailing CR alone is preserved (no double-CR) ───────────


def test_trailing_cr_already_present_is_preserved():
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session(sid, "hello\r")
    assert ok is True
    assert transport.writes[0].data == b"hello\r"


# ── 5. Multiline payload preserves embedded LFs but ends with CR


def test_multiline_payload_only_terminator_swapped():
    """Embedded `\\n` inside the payload (e.g. multi-line prompt) stays
    intact — only the terminating LF (if any) is swapped to CR. This
    matters because Claude's bracketed paste passes embedded LFs
    through as part of the pasted content, but treats the trailing
    CR as Enter."""
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session(sid, "line one\nline two\n")
    assert ok is True
    assert transport.writes[0].data == b"line one\nline two\r"


# ── 6. Missing session returns False, no write attempted ───────


def test_missing_session_returns_false_without_writing():
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session("99999999-9999-9999-9999-999999999999", "hello")
    assert ok is False
    assert transport.writes == []


# ── 7. Long payload gets capped at 8192 chars ──────────────────


def test_long_payload_capped_then_terminated():
    """Payload over 8 KiB is truncated to 8192 chars, then terminator
    is appended to the truncated body. Mirrors the column CHECK on
    remote_session_commands.payload."""
    sid = "11111111-1111-1111-1111-111111111111"
    manager, transport = _make_manager_with_session(sid)

    ok = manager.write_to_session(sid, "x" * 9000)
    assert ok is True
    written = transport.writes[0].data
    assert len(written) == 8193  # 8192 'x' + 1 '\r'
    assert written.endswith(b"\r")
    assert written[:-1] == b"x" * 8192
