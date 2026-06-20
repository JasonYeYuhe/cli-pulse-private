"""POSIX PTY transport — macOS + Linux helper deployment.

Spawns a child under a master/slave PTY pair via `os.openpty()` and
`subprocess.Popen`. The child's session is detached (`start_new_session`)
so SIGINT can be sent to its process group without affecting the helper
daemon.

This module imports `pty`, `termios`, `fcntl`, and `select`, all of which
exist on POSIX only. It is imported lazily by `transports.default_transport`
so a Windows host that loads `helper/transports/__init__.py` does not
crash on import.

Why we don't use `pty.fork()`:
  `pty.fork()` does fork + execvp inline and obscures the spawn failure
  surface (you have to inspect WIFEXITED on the child after waitpid). The
  `os.openpty()` + `subprocess.Popen` pattern keeps spawn errors as
  Python exceptions and lets us reuse Popen's process-group machinery.
"""
from __future__ import annotations

import errno
import fcntl
import logging
import os
import select
import signal
import struct
import subprocess
import termios
from dataclasses import dataclass

from .base import SessionHandle, SessionTransport, TransportError

logger = logging.getLogger("cli_pulse.transports.posix_pty")

# v1.16.3: default winsize for managed PTYs. `os.openpty()` returns a
# 0×0 PTY by default — ratatui-based TUIs (Codex) treat that as
# "1 column wide" and wrap each *double-width* char (every CJK glyph,
# many emoji) onto its own line. iPhone users then see one Chinese
# character per row in the transcript view. 120×40 is the de-facto
# baseline for "real terminal" emulation; matches Apple Terminal's
# default and gives Codex enough room to lay out without aggressive
# wrapping. Resize-on-the-fly isn't exposed to clients in v1.16; if
# we add a SwiftUI client-driven resize control later it'll need a new
# `SessionTransport.resize(rows, cols)` method + TIOCSWINSZ.
_DEFAULT_PTY_ROWS = 40
_DEFAULT_PTY_COLS = 120


@dataclass
class _PosixPayload:
    """Internal state stashed in `SessionHandle.payload` for POSIX."""
    proc: subprocess.Popen
    master_fd: int
    slave_fd: int        # Closed in start() right after Popen launch but
                         # kept on the dataclass for accountability in tests.
    closed: bool = False


def _set_nonblocking(fd: int) -> None:
    flags = fcntl.fcntl(fd, fcntl.F_GETFL)
    fcntl.fcntl(fd, fcntl.F_SETFL, flags | os.O_NONBLOCK)


class PosixPtyTransport(SessionTransport):
    """Concrete POSIX PTY transport. Single instance is shared across all
    managed sessions on a given helper — it has no per-session state of
    its own. Sessions live on `SessionHandle.payload`.
    """

    def start(
        self,
        session_id: str,
        argv: list[str],
        env: dict[str, str] | None = None,
        cwd: str | None = None,
        *,
        pass_fds: tuple[int, ...] = (),
    ) -> SessionHandle:
        if not argv:
            raise TransportError("argv must not be empty")

        # Merge the base environment so PATH, TERM, locale, etc. survive.
        # Caller-supplied vars win on conflict.
        full_env = os.environ.copy()
        if env:
            full_env.update(env)
        # Force a sane TERM so Claude Code (which probes capabilities)
        # doesn't degrade to a teletype mode if the helper was launched
        # without one (e.g. from launchd).
        full_env.setdefault("TERM", "xterm-256color")

        master_fd, slave_fd = os.openpty()
        # v1.16.3: set winsize BEFORE the child inherits the slave fd.
        # Without this, the kernel reports 0 cols × 0 rows, and Codex's
        # ratatui TUI wraps every double-width CJK glyph onto its own
        # line. Done on master_fd (slave is the same kernel object —
        # ioctl works on either end). Best-effort: if the ioctl somehow
        # fails on this platform we'd rather still spawn the child than
        # bail the whole session.
        try:
            ws = struct.pack("HHHH", _DEFAULT_PTY_ROWS, _DEFAULT_PTY_COLS, 0, 0)
            fcntl.ioctl(master_fd, termios.TIOCSWINSZ, ws)
        except OSError as exc:
            logger.warning(
                "TIOCSWINSZ failed for session %s (continuing): %s",
                session_id, exc,
            )
        try:
            proc = subprocess.Popen(
                argv,
                stdin=slave_fd,
                stdout=slave_fd,
                stderr=slave_fd,
                env=full_env,
                cwd=cwd,
                start_new_session=True,         # SIGINT to pgid won't kill us
                close_fds=True,
                # v-next P0-A: keep the caller's auth fd(s) open across the
                # exec. close_fds=True would otherwise close everything but
                # 0/1/2; pass_fds whitelists the inherited token fd. The
                # caller marked them inheritable and closes its own copy
                # after we return.
                pass_fds=tuple(pass_fds),
                bufsize=0,
            )
        except (FileNotFoundError, PermissionError, OSError) as exc:
            os.close(master_fd)
            os.close(slave_fd)
            raise TransportError(f"failed to spawn {argv[0]}: {exc}") from exc

        # Slave fd is now owned by the child; close our copy.
        os.close(slave_fd)
        _set_nonblocking(master_fd)

        payload = _PosixPayload(proc=proc, master_fd=master_fd, slave_fd=-1)
        logger.info(
            "spawned managed session %s pid=%s argv0=%s",
            session_id, proc.pid, argv[0],
        )
        return SessionHandle(session_id=session_id, payload=payload)

    # ── helpers ──────────────────────────────────────────────

    @staticmethod
    def _payload(handle: SessionHandle) -> _PosixPayload:
        if not isinstance(handle.payload, _PosixPayload):
            raise TransportError("handle was not produced by PosixPtyTransport")
        return handle.payload

    def is_alive(self, handle: SessionHandle) -> bool:
        p = self._payload(handle)
        if p.closed:
            return False
        return p.proc.poll() is None

    # ── stdin / stdout ───────────────────────────────────────

    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        p = self._payload(handle)
        if p.closed:
            return 0
        if not data:
            return 0
        try:
            return os.write(p.master_fd, data)
        except BrokenPipeError:
            return 0
        except OSError as exc:
            if exc.errno in (errno.EPIPE, errno.EBADF, errno.EIO):
                return 0
            raise TransportError(f"write_stdin: {exc}") from exc

    def resize(self, handle: SessionHandle, rows: int, cols: int) -> None:
        """Live-resize the PTY window (v1.30.x in-app terminal). TIOCSWINSZ
        on the master fd; the kernel sends SIGWINCH to the child so its TUI
        re-flows. Clamp to xterm.js bounds (1..32767) and stay failure-soft —
        a resize must never kill the session."""
        p = self._payload(handle)
        if p.closed:
            return
        r = max(1, min(int(rows), 32767))
        c = max(1, min(int(cols), 32767))
        try:
            ws = struct.pack("HHHH", r, c, 0, 0)
            fcntl.ioctl(p.master_fd, termios.TIOCSWINSZ, ws)
        except OSError as exc:
            logger.warning("resize TIOCSWINSZ failed (continuing): %s", exc)

    def read_stdout(self, handle: SessionHandle, max_bytes: int = 4096) -> bytes:
        p = self._payload(handle)
        if p.closed:
            return b""
        try:
            ready, _, _ = select.select([p.master_fd], [], [], 0)
        except (ValueError, OSError):
            return b""
        if not ready:
            return b""
        try:
            return os.read(p.master_fd, max_bytes)
        except BlockingIOError:
            return b""
        except OSError as exc:
            if exc.errno in (errno.EIO, errno.EBADF):
                # PTY master returns EIO when the child has exited and the
                # slave fd is closed. Treat as EOF.
                return b""
            raise TransportError(f"read_stdout: {exc}") from exc

    # ── signals ──────────────────────────────────────────────

    def interrupt(self, handle: SessionHandle) -> None:
        self._signal_pgid(handle, signal.SIGINT)

    def terminate(self, handle: SessionHandle) -> None:
        self._signal_pgid(handle, signal.SIGTERM)

    def _signal_pgid(self, handle: SessionHandle, sig: int) -> None:
        p = self._payload(handle)
        if p.closed or p.proc.poll() is not None:
            return
        try:
            pgid = os.getpgid(p.proc.pid)
            os.killpg(pgid, sig)
        except (ProcessLookupError, PermissionError):
            return
        except OSError as exc:
            logger.warning(
                "signal pgid %s on session %s failed: %s",
                sig, handle.session_id, exc,
            )

    # ── lifecycle ────────────────────────────────────────────

    def wait(self, handle: SessionHandle, timeout: float | None = None) -> int | None:
        p = self._payload(handle)
        if p.closed:
            return p.proc.returncode
        try:
            if timeout == 0:
                code = p.proc.poll()
                return code
            return p.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            return None

    def close(self, handle: SessionHandle) -> None:
        p = self._payload(handle)
        if p.closed:
            return
        # v1.21 F1: SIGTERM → grace → SIGKILL escalation + zombie reap.
        # Previous behaviour was "send SIGTERM and hope": if the child
        # ignored SIGTERM, the master fd was closed but the child + its
        # process group leaked until daemon restart, draining file
        # descriptors and leaving a zombie. Grace defaults to 3 s, override
        # via `HELPER_TERM_GRACE_SECONDS` for CLIs that legitimately need
        # longer to flush state. `_signal_pgid` already guards
        # ProcessLookupError; we wrap the second-stage SIGKILL in an extra
        # try/except for the "child died between poll() and killpg()" race.
        try:
            if p.proc.poll() is None:
                self._signal_pgid(handle, signal.SIGTERM)
                try:
                    grace = float(os.environ.get("HELPER_TERM_GRACE_SECONDS", "3"))
                except ValueError:
                    grace = 3.0
                try:
                    p.proc.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    logger.warning(
                        "session %s did not exit within %ss of SIGTERM; escalating to SIGKILL",
                        handle.session_id, grace,
                    )
                    try:
                        pgid = os.getpgid(p.proc.pid)
                        os.killpg(pgid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError, OSError):
                        pass
                    # Non-blocking reap so the zombie is collected immediately
                    # rather than waiting for the next poll cycle.
                    try:
                        p.proc.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        # Even SIGKILL didn't take it down within 1s — log and
                        # move on; the kernel will eventually reap when the
                        # helper itself exits.
                        logger.error(
                            "session %s still alive 1s after SIGKILL; orphan PID %s",
                            handle.session_id, p.proc.pid,
                        )
        finally:
            try:
                os.close(p.master_fd)
            except OSError:
                pass
            p.closed = True
