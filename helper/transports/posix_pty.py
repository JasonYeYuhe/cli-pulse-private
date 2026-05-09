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
# 0×0 PTY by default. 120×40 is the de-facto "real terminal" baseline
# (matches Apple Terminal default) and gives Node-based TUIs (Claude,
# Gemini) sane layout dimensions.
#
# v1.16.4 carve-out: Codex (ratatui-based) renders an *elaborate* full
# TUI at 120×40 — banner box + working spinner + status bar + input
# prompt area — which the conversation-preview formatter cannot extract
# back into chat lines. At 0×0 the ratatui mode degrades to a per-char
# emit that the formatter can sort-of recover (English looks OK,
# CJK breaks one-glyph-per-line). The real fix is to rewrite Codex
# managed sessions onto `codex exec --json` (subprocess-per-turn) —
# tracked for v1.17. Until then, leave the Codex PTY at 0×0 so English
# chat at least surfaces. CJK regression is a known-issue.
_DEFAULT_PTY_ROWS = 40
_DEFAULT_PTY_COLS = 120
_PROVIDER_NO_WINSIZE = {"codex"}  # argv[0] basenames that opt out


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
        # v1.16.3: set winsize BEFORE the child inherits the slave fd —
        # 0×0 makes Node TUIs lay text out poorly. Master and slave
        # refer to the same kernel object so ioctl on master is enough.
        # v1.16.4 carve-out: Codex's ratatui at 120×40 paints a full
        # TUI (banner box, working spinner, status bar) that the
        # CodexConversationPreviewFormatter can't disassemble back into
        # chat lines, leaving the iPhone stuck on "Waiting for
        # conversational output…". Until v1.17 ships the codex-exec
        # subprocess-per-turn rewrite, route Codex spawns through a
        # 0×0 PTY so the conversation at least surfaces. See
        # `_PROVIDER_NO_WINSIZE` docstring for the full reasoning.
        argv0_base = os.path.basename(argv[0]) if argv else ""
        if argv0_base in _PROVIDER_NO_WINSIZE:
            logger.info(
                "session %s argv0=%s: skipping TIOCSWINSZ (provider opt-out)",
                session_id, argv0_base,
            )
        else:
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
        # Best-effort terminate. If the child is wedged, the helper's own
        # shutdown loop will eventually escalate to SIGKILL via the
        # manager.
        try:
            if p.proc.poll() is None:
                self._signal_pgid(handle, signal.SIGTERM)
        finally:
            try:
                os.close(p.master_fd)
            except OSError:
                pass
            p.closed = True
