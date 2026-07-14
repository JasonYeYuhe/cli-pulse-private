"""Tests for the tmux control-mode transport (DEV_PLAN_2026-07-14 M4).

The escaping tests are pure. The round-trip tests drive a REAL tmux server on a
throwaway socket (skipped if tmux isn't installed) — they prove bidirectional
byte-exact I/O against a session an external process controls.
"""
from __future__ import annotations

import os
import shutil
import tempfile
import time

import pytest

from transports.base import TransportError
from transports.tmux import TmuxTransport, unescape_control_output

_TMUX = shutil.which("tmux")
requires_tmux = pytest.mark.skipif(_TMUX is None, reason="tmux not installed")


# --- pure: control-mode un-escaping ---------------------------------------

def test_unescape_passthrough_and_octal():
    # ESC is octal-escaped \033; backslash doubled; CR/LF and UTF-8 raw.
    raw = b"A\\033[31mB\\\\C\r\n\xc3\xa9\xf0\x9f\x90\xb1Z"
    assert unescape_control_output(raw) == b"A\x1b[31mB\\C\r\n\xc3\xa9\xf0\x9f\x90\xb1Z"


def test_unescape_empty_and_plain():
    assert unescape_control_output(b"") == b""
    assert unescape_control_output(b"hello world") == b"hello world"


def test_unescape_lone_trailing_backslash_is_literal():
    assert unescape_control_output(b"x\\") == b"x\\"


# --- real tmux round-trip --------------------------------------------------

@pytest.fixture
def transport():
    d = tempfile.mkdtemp(prefix="clip-tmux-")
    sock = os.path.join(d, "t.sock")
    t = TmuxTransport(socket_path=sock)
    yield t
    # best-effort teardown of the whole server
    try:
        t._tmux("kill-server")
    except Exception:
        pass


def _read_until(t, h, needle: bytes, timeout: float = 4.0) -> bytes:
    acc = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        acc.extend(t.read_stdout(h, 65536))
        if needle in acc:
            return bytes(acc)
        time.sleep(0.05)
    return bytes(acc)


@requires_tmux
def test_start_stream_and_inject(transport):
    # An interactive shell stands in for an external claude/codex TUI.
    h = transport.start("s1", ["bash", "--norc", "-i"])
    try:
        assert transport.is_alive(h)
        # inject a command as raw bytes and read its output via control mode
        transport.write_stdin(h, b"echo INJECTED_$((20+22))\n")
        out = _read_until(transport, h, b"INJECTED_42")
        assert b"INJECTED_42" in out, out
        # resize is failure-soft and returns cleanly
        transport.resize(h, rows=24, cols=80)
    finally:
        transport.close(h)
    assert not transport.is_alive(h)


@requires_tmux
def test_write_after_exit_returns_zero(transport):
    h = transport.start("s2", ["bash", "--norc", "-c", "true"])
    transport.wait(h, timeout=3.0)
    assert not transport.is_alive(h)
    assert transport.write_stdin(h, b"noop\n") == 0
    transport.close(h)


@requires_tmux
def test_attach_existing_session(transport):
    # Create a session directly (as if the user launched it), then attach.
    transport._tmux("new-session", "-d", "-s", "ext", "-x", "80", "-y", "24",
                    "bash", "--norc", "-i")
    time.sleep(0.3)
    h = transport.attach_existing("mylabel", "ext")
    try:
        assert h.session_id == "mylabel"
        transport.write_stdin(h, b"echo HELLO_EXTERNAL\n")
        out = _read_until(transport, h, b"HELLO_EXTERNAL")
        assert b"HELLO_EXTERNAL" in out, out
    finally:
        # attach_existing does NOT own the session → close must not kill it
        transport.close(h)
    assert transport._tmux("has-session", "-t", "ext").returncode == 0


@requires_tmux
def test_close_is_idempotent(transport):
    h = transport.start("s3", ["bash", "--norc", "-i"])
    transport.close(h)
    transport.close(h)  # no raise


def test_foreign_handle_rejected(transport):
    from transports.base import SessionHandle
    with pytest.raises(TransportError):
        transport.write_stdin(SessionHandle(session_id="x", payload=object()), b"x")


@requires_tmux
def test_session_id_with_colons_and_periods(transport):
    h = transport.start("foo.bar:baz", ["bash", "--norc", "-i"])
    try:
        assert transport.is_alive(h)
        transport.write_stdin(h, b"echo INJECTED\n")
        out = _read_until(transport, h, b"INJECTED")
        assert b"INJECTED" in out
    finally:
        transport.close(h)


@requires_tmux
def test_write_stdin_after_kill_returns_zero(transport):
    h = transport.start("s_kill", ["bash", "--norc", "-i"])
    try:
        transport.close(h)
        assert transport.write_stdin(h, b"hello") == 0
    finally:
        transport.close(h)


@requires_tmux
def test_resize_coerces_integers(transport):
    h = transport.start("s_resize", ["bash", "--norc", "-i"])
    try:
        # String dimensions should be successfully coerced to int without TypeError
        transport.resize(h, "24", "80")
    finally:
        transport.close(h)

