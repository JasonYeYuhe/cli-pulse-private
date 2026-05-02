"""Pluggable PTY transports for managed remote agent sessions.

Phase-2 / iter-1 of Remote Agent Sessions ("Sessions Input"). Defines a
`SessionTransport` ABC so the helper's `RemoteAgentManager` can drive a
provider CLI (Claude Code, eventually Codex, eventually shell) under a
PTY without baking in POSIX-only assumptions.

Two concrete transports live alongside this package:

  * `PosixPtyTransport` (helper/transports/posix_pty.py)
        Real PTY via `os.openpty()` + `subprocess.Popen` with
        `start_new_session=True`. macOS + Linux. Exclusively used by the
        Mac helper today.

  * `ConPtyTransport` (helper/transports/conpty.py)
        Stub. Raises `NotImplementedError` on instantiation. Reserved for
        the cli-pulse-desktop track (Tauri 2 — Windows + Linux), which
        will implement against the same `SessionTransport` protocol so
        nothing in `RemoteAgentManager` has to change.

Importing this package on Windows is safe: only `base` + `conpty` get
loaded eagerly. `posix_pty` is imported lazily via the `default_transport`
factory below so a Windows host doesn't crash on `import pty`.
"""
from __future__ import annotations

import sys

from .base import SessionHandle, SessionTransport, TransportError

__all__ = [
    "SessionHandle",
    "SessionTransport",
    "TransportError",
    "default_transport",
]


def default_transport() -> SessionTransport:
    """Return the platform-appropriate `SessionTransport`.

    The Mac helper today is the only deployment target; the Windows /
    Linux Tauri desktop track will pick up `ConPtyTransport` against the
    same protocol.
    """
    if sys.platform == "win32":
        from .conpty import ConPtyTransport  # noqa: F401 — runtime gate
        raise NotImplementedError(
            "Windows ConPTY transport — implemented in cli-pulse-desktop track"
        )
    from .posix_pty import PosixPtyTransport
    return PosixPtyTransport()
