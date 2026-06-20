"""Transport protocol shared by every PTY backend.

`SessionTransport` is an ABC, not a `typing.Protocol`, because:
  * The methods carry stateful invariants (start before write, etc.) that
    are easier to encode + assert in concrete subclasses.
  * `RemoteAgentManager` constructs transports via dependency injection;
    treating them as a class hierarchy makes the swap mechanics obvious
    in the manager constructor.

`SessionHandle` is deliberately opaque. POSIX implementations stash a
`Popen` plus PTY master fd; the Windows desktop track will stash a
`PseudoConsoleHandle` plus pipe handles. Callers only pass it back to the
same transport that produced it.
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass, field
from typing import Any


class TransportError(RuntimeError):
    """Raised by transports for predictable failures (spawn failed, child
    exited unexpectedly, fd already closed). Helpers convert these into
    `failed` command completion + status='errored' events.
    """


@dataclass
class SessionHandle:
    """Opaque token returned by `start()`. Callers MUST NOT touch the
    `payload` field; only the transport that produced the handle inspects
    it. `session_id` is included so transports can label log lines and
    so `RemoteAgentManager` can index handles without keeping a parallel
    map.
    """
    session_id: str
    payload: Any = field(default=None, repr=False)


class SessionTransport(ABC):
    """Abstract PTY transport.

    Lifecycle:
        handle = transport.start(session_id, argv, env, cwd)
        transport.write_stdin(handle, b"prompt\n")
        chunk = transport.read_stdout(handle, max_bytes=4096)  # may be b''
        exit_code = transport.wait(handle)                     # blocking
        transport.interrupt(handle)                            # SIGINT
        transport.terminate(handle)                            # SIGTERM
        transport.close(handle)                                # release fds

    All methods MUST tolerate handles whose underlying child has already
    exited. They raise `TransportError` only for unrecoverable invariant
    breaches (e.g. write before start, double-close).
    """

    @abstractmethod
    def start(
        self,
        session_id: str,
        argv: list[str],
        env: dict[str, str] | None = None,
        cwd: str | None = None,
        *,
        pass_fds: tuple[int, ...] = (),
    ) -> SessionHandle:
        """Spawn the provider CLI under a PTY. Raises TransportError on
        spawn failure.

        argv[0] should be the absolute path to the executable; PATH is
        not searched (POSIX) by default. env defaults to the current
        process environment merged with required PTY vars.

        `pass_fds` (v-next P0-A): extra file descriptors to keep open
        across the child's exec (e.g. an inherited read-end carrying the
        claude OAuth token for CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR).
        Only the PTY transport honors this; the exec-mode transports
        (codex/gemini) inherit the default and ignore it — they are never
        spawned with auth fds. The CALLER owns the fd lifecycle (closes
        its own copy after start returns).
        """

    @abstractmethod
    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        """Write `data` to the child's stdin. Returns bytes actually
        written. Returns 0 if the child is gone (EPIPE caught
        internally). Never blocks long: writes are flushed to the master
        fd buffer; the child's read pacing is its problem.
        """

    @abstractmethod
    def read_stdout(self, handle: SessionHandle, max_bytes: int = 4096) -> bytes:
        """Non-blocking read of up to `max_bytes` from the master fd.
        Returns b"" when nothing is available (no exception). Returns
        b"" when EOF (child has exited and the buffer is drained).
        """

    @abstractmethod
    def interrupt(self, handle: SessionHandle) -> None:
        """Send SIGINT (POSIX) / Ctrl-C event (Windows) to the child's
        process group. No-op if the child has already exited.
        """

    @abstractmethod
    def terminate(self, handle: SessionHandle) -> None:
        """Send SIGTERM (POSIX) / TerminateProcess (Windows). No-op if
        the child has already exited. Does NOT block waiting for the
        child to actually go away — call `wait()` or `is_alive()` to
        observe.
        """

    @abstractmethod
    def is_alive(self, handle: SessionHandle) -> bool:
        """Return True if the child is still running."""

    @abstractmethod
    def wait(self, handle: SessionHandle, timeout: float | None = None) -> int | None:
        """Wait up to `timeout` seconds for the child to exit. Returns
        the exit code if it did, or None if it's still running. Pass
        `timeout=None` to block indefinitely. Pass `timeout=0` to poll.
        """

    @abstractmethod
    def close(self, handle: SessionHandle) -> None:
        """Release any fds / handles owned by this transport for
        `handle`. Idempotent — safe to call multiple times. Implies
        `terminate()` if the child is still alive.
        """

    # Concrete default (NOT abstract): v1.30.x in-app terminal window resize.
    # Only the PTY transport has a live TTY to resize; codex_exec / conpty
    # have no resizable window, so they inherit this no-op. Overrides
    # MUST be failure-soft — a resize must never kill the session.
    def resize(self, handle: SessionHandle, rows: int, cols: int) -> None:
        """Update the child's terminal window size. Default: no-op."""
        return None
