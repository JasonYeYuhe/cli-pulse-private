"""Unit tests for the POSIX PTY transport — focused on the v1.32.1 P0
resize→SIGWINCH fix.

The child is spawned with ``start_new_session=True`` and never acquires the
slave as a controlling terminal, so ``TIOCSWINSZ`` on the master does NOT
trigger the kernel's automatic SIGWINCH. The transport's ``resize()`` must
therefore deliver SIGWINCH explicitly, or full-screen TUIs (claude / agy)
never re-flow on window resize. These tests pin that behaviour end-to-end:
a real child traps SIGWINCH and echoes a marker, and we assert the marker
arrives only after ``resize()`` is called.
"""
from __future__ import annotations

import sys
import time

import pytest

# POSIX-only module; skip the whole file on Windows CI.
if sys.platform.startswith("win"):
    pytest.skip("posix_pty is POSIX-only", allow_module_level=True)

from transports.posix_pty import PosixPtyTransport  # noqa: E402


# A child that prints "READY", then echoes "WINCH" every time it receives
# SIGWINCH, then exits after a short sleep. Reads winsize via the standard
# ioctl so it also serves as a sanity child for other PTY tests.
_WINCH_CHILD = (
    "import signal,sys,os,time\n"
    "def h(*a):\n"
    "    os.write(1, b'WINCH\\n')\n"
    "signal.signal(signal.SIGWINCH, h)\n"
    "os.write(1, b'READY\\n')\n"
    "t=time.time()\n"
    "while time.time()-t < 5:\n"
    "    time.sleep(0.02)\n"
)


def _read_until(transport, handle, needle: bytes, timeout: float = 3.0) -> bytes:
    """Drain stdout (non-blocking) until `needle` appears or timeout."""
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        chunk = transport.read_stdout(handle, 4096)
        if chunk:
            buf += chunk
            if needle in buf:
                return buf
        else:
            time.sleep(0.02)
    return buf


def test_resize_delivers_sigwinch_to_child():
    """resize() must deliver SIGWINCH so the child re-reads the winsize.

    Regression for the v1.32.1 'stuck columns' bug: TIOCSWINSZ updated the
    PTY winsize but the child (no controlling tty) never got SIGWINCH, so its
    TUI rendered at the old column count until a signal arrived."""
    t = PosixPtyTransport()
    handle = t.start("winch-test", [sys.executable, "-c", _WINCH_CHILD])
    try:
        # Wait for the child to install its handler and announce READY.
        got = _read_until(t, handle, b"READY")
        assert b"READY" in got, "child never started"

        # Quiet drain: collect any trailing startup output for a short window
        # so a stray/spurious SIGWINCH at spawn can't masquerade as our
        # post-resize delivery (Gemini/Codex review). Nothing should echo
        # WINCH before we call resize().
        quiet = b""
        deadline = time.time() + 0.3
        while time.time() < deadline:
            quiet += t.read_stdout(handle, 4096)
            time.sleep(0.02)
        assert b"WINCH" not in (got + quiet), "child saw a SIGWINCH before resize()"

        # Resize: TIOCSWINSZ + explicit SIGWINCH.
        t.resize(handle, rows=50, cols=180)

        got = _read_until(t, handle, b"WINCH")
        assert b"WINCH" in got, (
            "child did not receive SIGWINCH after resize() — the explicit "
            "delivery regressed; TUIs will not re-flow on window resize"
        )
    finally:
        t.close(handle)


def test_resize_after_close_is_noop():
    """resize() on a torn-down session must not raise (early `p.closed` path)."""
    t = PosixPtyTransport()
    handle = t.start("winch-closed", [sys.executable, "-c", "import time;time.sleep(0.1)"])
    t.close(handle)
    # Should be a silent no-op, never an exception.
    t.resize(handle, rows=24, cols=80)


def test_resize_ioctl_failure_does_not_raise(monkeypatch):
    """If TIOCSWINSZ itself fails (e.g. master fd in a bad state) resize() must
    swallow the OSError, skip the SIGWINCH, and never raise — exercising the
    failure path the close-noop test skips over (it early-returns on
    `p.closed` before reaching the ioctl)."""
    import fcntl as _fcntl

    t = PosixPtyTransport()
    handle = t.start("winch-badioctl", [sys.executable, "-c", "import time;time.sleep(1)"])
    try:
        def _boom(*_a, **_k):
            raise OSError(9, "Bad file descriptor")
        # posix_pty does `import fcntl; fcntl.ioctl(...)`, so patching the
        # module attribute intercepts the TIOCSWINSZ call (close() path uses
        # os.close / os.killpg, not fcntl.ioctl, so teardown stays clean).
        monkeypatch.setattr(_fcntl, "ioctl", _boom)
        t.resize(handle, rows=40, cols=100)  # must not raise
    finally:
        t.close(handle)


def test_resize_updates_winsize():
    """The kernel winsize must reflect the requested rows/cols."""
    import fcntl
    import struct
    import termios

    t = PosixPtyTransport()
    handle = t.start("winch-size", [sys.executable, "-c", "import time;time.sleep(2)"])
    try:
        t.resize(handle, rows=33, cols=177)
        master_fd = handle.payload.master_fd
        packed = fcntl.ioctl(master_fd, termios.TIOCGWINSZ, struct.pack("HHHH", 0, 0, 0, 0))
        rows, cols, _, _ = struct.unpack("HHHH", packed)
        assert (rows, cols) == (33, 177)
    finally:
        t.close(handle)
