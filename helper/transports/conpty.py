"""Windows ConPTY transport — PLACEHOLDER for the cli-pulse-desktop track.

Instantiating this class raises `NotImplementedError`. The real Tauri 2
desktop helper for Windows + Linux will implement this against the same
`SessionTransport` protocol so nothing in `RemoteAgentManager` has to
change.

Implementation notes for the desktop track (do not delete — this is the
contract handoff):

  * Use Win32 `CreatePseudoConsole` to allocate a master-side handle.
  * Spawn the child via `STARTUPINFOEX` with
    `EXTENDED_STARTUPINFO_PRESENT | EXTENDED_PROCESS_INFORMATION_PRESENT`,
    setting `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` to bind the child to
    the pseudoconsole.
  * `ResizePseudoConsole` is the equivalent of TIOCSWINSZ.
  * `ClosePseudoConsole` releases the master-side handle; the child is
    expected to exit cleanly when the pseudoconsole closes.
  * For pure-Python prototyping, `pywinpty` (PyPI: `pywinpty`) wraps the
    above into a high-level `PtyProcess` with `read()` / `write()` /
    `setwinsize()`. The Tauri helper will likely link the underlying
    DLLs directly via Rust crates rather than depend on the Python
    binding, but the surface is the same.
  * SIGINT-equivalent on Windows is `GenerateConsoleCtrlEvent
    (CTRL_C_EVENT, pgid)` against the child's process group ID. SIGTERM
    is `TerminateProcess`.

The contract above mirrors the POSIX implementation in `posix_pty.py`,
so a swap should be drop-in.
"""
from __future__ import annotations

from .base import SessionHandle, SessionTransport


class ConPtyTransport(SessionTransport):
    """Windows pseudoconsole transport. Not implemented in this iteration.

    The Mac helper deliberately doesn't carry the dependencies this
    transport needs (pywinpty / Win32 PInvoke), so `RemoteAgentManager`
    only constructs `PosixPtyTransport` on non-Windows hosts. The
    cli-pulse-desktop track owns the implementation.
    """

    def __init__(self) -> None:
        raise NotImplementedError(
            "Windows ConPTY transport — implemented in cli-pulse-desktop track. "
            "See helper/transports/conpty.py module docstring for the Win32 API "
            "contract (CreatePseudoConsole, ResizePseudoConsole, "
            "ClosePseudoConsole, pywinpty.PtyProcess) the desktop helper must "
            "satisfy."
        )

    def start(self, session_id, argv, env=None, cwd=None):  # pragma: no cover
        raise NotImplementedError

    def write_stdin(self, handle, data):  # pragma: no cover
        raise NotImplementedError

    def read_stdout(self, handle, max_bytes=4096):  # pragma: no cover
        raise NotImplementedError

    def interrupt(self, handle):  # pragma: no cover
        raise NotImplementedError

    def terminate(self, handle):  # pragma: no cover
        raise NotImplementedError

    def is_alive(self, handle):  # pragma: no cover
        raise NotImplementedError

    def wait(self, handle, timeout=None):  # pragma: no cover
        raise NotImplementedError

    def close(self, handle):  # pragma: no cover
        raise NotImplementedError
