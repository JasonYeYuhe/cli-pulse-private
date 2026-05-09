"""MultiplexTransport — route per-session to the right concrete transport.

`PosixPtyTransport` handles Claude / Gemini / generic CLIs that work
under a real PTY. `CodexExecTransport` handles Codex via subprocess-
per-turn `codex exec --json` (avoids ratatui TUI rendering issues, see
the codex_exec module docstring for the full story).

`RemoteAgentManager` only knows about ONE `SessionTransport`. To add
the Codex carve-out without touching every call site, we introduce a
multiplex transport that:

  * On `start()`: looks at `argv[0]` basename and picks the inner
    transport.
  * On all other methods: dispatches by the type of `handle.payload`
    so the right inner transport sees its own state.

This is conceptually a strategy-pattern dispatcher. Adding a new
provider-specific transport later is a one-line entry in the start()
routing table.
"""
from __future__ import annotations

import logging
import os
from typing import Optional

from .base import SessionHandle, SessionTransport, TransportError

logger = logging.getLogger("cli_pulse.transports.multiplex")


# argv[0] basenames that should be routed through CodexExecTransport.
# Kept minimal — when in doubt, use the PTY path (it's the historical
# default and what spawners are written for).
_CODEX_EXEC_BINARIES = {"codex"}


class MultiplexTransport(SessionTransport):
    def __init__(
        self,
        pty_transport: SessionTransport,
        codex_exec_transport: SessionTransport,
    ) -> None:
        self._pty = pty_transport
        self._codex = codex_exec_transport

    # ── routing helpers ──────────────────────────────────────

    def _transport_for_argv(self, argv: list[str]) -> SessionTransport:
        if argv:
            base = os.path.basename(argv[0])
            if base in _CODEX_EXEC_BINARIES:
                return self._codex
        return self._pty

    def _transport_for_handle(self, handle: SessionHandle) -> SessionTransport:
        # Probe each inner transport by attempting `_payload`. The one
        # that doesn't raise owns the handle. Fall through with a
        # diagnostic raise rather than silently picking wrong.
        try:
            self._codex._payload(handle)  # type: ignore[attr-defined]
            return self._codex
        except (TransportError, AttributeError):
            pass
        try:
            self._pty._payload(handle)  # type: ignore[attr-defined]
            return self._pty
        except (TransportError, AttributeError):
            pass
        raise TransportError("handle does not match any registered inner transport")

    # ── SessionTransport surface ─────────────────────────────

    def start(
        self,
        session_id: str,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> SessionHandle:
        inner = self._transport_for_argv(argv)
        if inner is self._codex:
            logger.info(
                "multiplex.start session=%s routing→codex_exec (argv0=%s)",
                session_id, argv[0] if argv else "<empty>",
            )
        return inner.start(session_id, argv, env, cwd)

    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        return self._transport_for_handle(handle).write_stdin(handle, data)

    def read_stdout(self, handle: SessionHandle, max_bytes: int = 4096) -> bytes:
        return self._transport_for_handle(handle).read_stdout(handle, max_bytes)

    def interrupt(self, handle: SessionHandle) -> None:
        self._transport_for_handle(handle).interrupt(handle)

    def terminate(self, handle: SessionHandle) -> None:
        self._transport_for_handle(handle).terminate(handle)

    def is_alive(self, handle: SessionHandle) -> bool:
        return self._transport_for_handle(handle).is_alive(handle)

    def wait(self, handle: SessionHandle, timeout: Optional[float] = None) -> Optional[int]:
        return self._transport_for_handle(handle).wait(handle, timeout)

    def close(self, handle: SessionHandle) -> None:
        self._transport_for_handle(handle).close(handle)
