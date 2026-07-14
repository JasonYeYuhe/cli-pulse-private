r"""tmux control-mode SessionTransport — the seam for controlling sessions that
run inside a tmux server (the "wrap" approach for EXTERNALLY-launched Claude/
Codex, per DEV_PLAN_2026-07-14_external_session_control.md M4).

Unlike PosixPtyTransport (which owns the PTY directly), this transport drives a
session running inside a **CLI-Pulse-owned tmux server** on a dedicated socket:

  * OUTPUT is read out-of-band from a persistent `tmux -C attach` control client:
    tmux emits `%output %<pane> <data>` lines; we un-escape and buffer the bytes
    so `read_stdout()` stays byte-exact and non-blocking (matches the ABC).
  * INPUT is injected with `send-keys -H <hex>` (raw bytes, exact) — so a remote
    keystroke or a whole pasted prompt lands in the session's stdin verbatim.
  * RESIZE/INTERRUPT/terminate map to `resize-window` / `send-keys C-c` /
    `kill-session`.

Because an EXTERNAL process (not the tmux server owner) can drive the socket, the
same transport also attaches to an ALREADY-running same-user tmux session (the
"free win" — pass an existing session name to `attach_existing`).

tmux control-mode escaping (empirically pinned, tmux 3.6): only a subset of bytes
are octal-escaped as `\ooo`; a literal backslash is doubled `\\`; CR/LF, printable
ASCII and UTF-8 pass through raw. So a `\` in the stream is ALWAYS either `\\`
(one backslash) or `\ooo` (one byte) — unambiguous regardless of which bytes tmux
chose to escape.

NOT for Windows (tmux is POSIX). The ConPTY/desktop track keeps its own path.
"""
from __future__ import annotations

import shutil
import subprocess
import threading
import time
from dataclasses import dataclass, field

from .base import SessionHandle, SessionTransport, TransportError


# --- control-mode byte (un)escaping ---------------------------------------

def unescape_control_output(data: bytes) -> bytes:
    """Reconstruct exact bytes from a tmux control-mode `%output` payload.

    `\\ooo` (backslash + exactly 3 octal digits) → that byte; `\\\\` → `\\`;
    everything else is literal. A lone trailing/invalid backslash is emitted
    verbatim (defensive — tmux never produces one).
    """
    out = bytearray()
    i = 0
    n = len(data)
    while i < n:
        b = data[i]
        if b == 0x5C and i + 1 < n:  # backslash
            nxt = data[i + 1]
            if nxt == 0x5C:          # \\  → \
                out.append(0x5C)
                i += 2
                continue
            if 0x30 <= nxt <= 0x37 and i + 3 < n \
               and 0x30 <= data[i + 2] <= 0x37 and 0x30 <= data[i + 3] <= 0x37:
                out.append(int(data[i + 1:i + 4], 8) & 0xFF)
                i += 4
                continue
        out.append(b)
        i += 1
    return bytes(out)


@dataclass
class _TmuxPayload:
    socket_path: str
    session: str
    control: subprocess.Popen  # persistent `tmux -C attach` client
    reader: threading.Thread | None = None
    buffer: bytearray = field(default_factory=bytearray)
    lock: threading.Lock = field(default_factory=threading.Lock)
    owns_session: bool = True   # False when we attached to a pre-existing session
    closed: bool = False


class TmuxTransport(SessionTransport):
    """Drive a session inside a CLI-Pulse-owned tmux server via control mode."""

    def __init__(self, socket_path: str, tmux_bin: str | None = None,
                 default_cols: int = 120, default_rows: int = 30) -> None:
        self.socket_path = socket_path
        self.tmux_bin = tmux_bin or shutil.which("tmux") or "/opt/homebrew/bin/tmux"
        self.default_cols = default_cols
        self.default_rows = default_rows

    # -- tmux command helpers ----------------------------------------------

    def _tmux(self, *args: str, timeout: float = 5.0) -> subprocess.CompletedProcess:
        try:
            return subprocess.run(
                [self.tmux_bin, "-S", self.socket_path, *args],
                capture_output=True, timeout=timeout,
            )
        except (subprocess.SubprocessError, FileNotFoundError, PermissionError) as exc:
            raise TransportError(f"tmux command failed: {exc}") from exc

    def _control_client(self, session: str) -> subprocess.Popen:
        # stdin MUST stay open — it's control mode's command channel; on EOF the
        # client detaches (%exit) and output streaming stops.
        try:
            return subprocess.Popen(
                [self.tmux_bin, "-S", self.socket_path, "-C", "attach", "-t", session],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                bufsize=0,
            )
        except (FileNotFoundError, PermissionError, OSError) as exc:
            raise TransportError(f"failed to spawn tmux control client: {exc}") from exc

    def _spawn_reader(self, payload: _TmuxPayload) -> threading.Thread:
        def run() -> None:
            control: subprocess.Popen = payload.control
            assert control.stdout is not None
            try:
                for raw in control.stdout:  # newline-delimited control lines
                    line = raw.rstrip(b"\r\n")
                    if not line.startswith(b"%output "):
                        continue
                    # %output %<pane> <data>
                    parts = line.split(b" ", 2)
                    if len(parts) < 3:
                        continue
                    decoded = unescape_control_output(parts[2])
                    with payload.lock:
                        payload.buffer.extend(decoded)
            except Exception:
                # Defensive: ensure the reader thread never crashes daemon unhandled
                pass
        t = threading.Thread(target=run, name="tmux-ctl-reader", daemon=True)
        return t

    # -- SessionTransport API ----------------------------------------------

    def start(
        self,
        session_id: str,
        argv: list[str],
        env: dict[str, str] | None = None,
        cwd: str | None = None,
        *,
        pass_fds: tuple[int, ...] = (),   # ignored — tmux server spawns the child
        env_remove: frozenset[str] = frozenset(),
    ) -> SessionHandle:
        if not argv:
            raise TransportError("tmux start: empty argv")
        sanitized_session = session_id.replace(".", "_").replace(":", "_")
        cmd = ["new-session", "-d", "-s", sanitized_session,
               "-x", str(self.default_cols), "-y", str(self.default_rows)]
        if cwd:
            cmd += ["-c", cwd]
        # tmux -e KEY=VALUE sets per-session env (tmux 3.2+). env_remove is applied
        # by setting the key empty (best-effort — a tmux child can't truly unset an
        # inherited var; the wrap use-case relies on the user's own login env, so
        # managed auth-fd/api-key scrubbing is N/A here).
        for k in sorted(env_remove):
            cmd += ["-e", f"{k}="]
        if env:
            for k, v in env.items():
                cmd += ["-e", f"{k}={v}"]
        cmd += ["--", *argv]
        r = self._tmux(*cmd)
        if r.returncode != 0:
            raise TransportError(
                f"tmux new-session failed: {r.stderr.decode('utf-8', 'replace').strip()}"
            )
        return self._attach(sanitized_session, owns_session=True, label=session_id)

    def attach_existing(self, session_id: str, tmux_session_name: str) -> SessionHandle:
        """Attach control mode to an ALREADY-running same-user tmux session
        (the 'free win'). `session_id` is our label; `tmux_session_name` is the
        target inside the (possibly foreign) tmux server on `socket_path`."""
        sanitized_target = tmux_session_name.replace(".", "_").replace(":", "_")
        if self._tmux("has-session", "-t", sanitized_target).returncode != 0:
            raise TransportError(f"tmux session not found: {tmux_session_name}")
        return self._attach(sanitized_target, owns_session=False, label=session_id)

    def _attach(self, session: str, *, owns_session: bool, label: str | None = None) -> SessionHandle:
        control = self._control_client(session)
        payload = _TmuxPayload(
            socket_path=self.socket_path, session=session,
            control=control, reader=None, owns_session=owns_session,
        )
        reader = self._spawn_reader(payload)
        payload.reader = reader
        reader.start()
        return SessionHandle(session_id=label or session, payload=payload)

    @staticmethod
    def _p(handle: SessionHandle) -> _TmuxPayload:
        p = handle.payload
        if not isinstance(p, _TmuxPayload):
            raise TransportError("tmux transport: foreign or missing handle payload")
        return p

    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        if not data:
            return 0
        p = self._p(handle)
        if p.closed:
            return 0
        if not self.is_alive(handle):
            return 0
        # send raw bytes exactly: send-keys -H <hex hex ...>. Chunk so a huge
        # paste doesn't blow the argv limit.
        step = 512
        written = 0
        for off in range(0, len(data), step):
            chunk = data[off:off + step]
            hexes = [f"{b:02x}" for b in chunk]
            r = self._tmux("send-keys", "-t", p.session, "-H", *hexes)
            if r.returncode != 0:
                break
            written += len(chunk)
        return written

    def read_stdout(self, handle: SessionHandle, max_bytes: int = 4096) -> bytes:
        p = self._p(handle)
        with p.lock:
            if not p.buffer:
                return b""
            take = bytes(p.buffer[:max_bytes])
            del p.buffer[:max_bytes]
            return take

    def resize(self, handle: SessionHandle, rows: int, cols: int) -> None:
        p = self._p(handle)
        if p.closed:
            return
        c = max(1, min(int(cols), 32767))
        r = max(1, min(int(rows), 32767))
        # failure-soft: a resize must never kill the session.
        self._tmux("resize-window", "-t", p.session, "-x", str(c), "-y", str(r))

    def interrupt(self, handle: SessionHandle) -> None:
        p = self._p(handle)
        self._tmux("send-keys", "-t", p.session, "C-c")

    def terminate(self, handle: SessionHandle) -> None:
        p = self._p(handle)
        if p.owns_session:
            self._tmux("kill-session", "-t", p.session)

    def is_alive(self, handle: SessionHandle) -> bool:
        p = self._p(handle)
        if p.closed:
            return False
        return self._tmux("has-session", "-t", p.session).returncode == 0

    def wait(self, handle: SessionHandle, timeout: float | None = None) -> int | None:
        deadline = None if timeout is None else time.monotonic() + timeout
        while self.is_alive(handle):
            if deadline is not None and time.monotonic() >= deadline:
                return None
            time.sleep(0.05)
        # tmux drops the session when its command exits; an exact exit code isn't
        # recoverable after teardown, so report 0 (exited) for a clean gone-away.
        return 0

    def close(self, handle: SessionHandle) -> None:
        p = self._p(handle)
        if p.closed:
            return
        p.closed = True
        if p.owns_session:
            self._tmux("kill-session", "-t", p.session)
        try:
            if p.control.stdin:
                p.control.stdin.close()   # EOF → control client detaches
        except OSError:
            pass
        try:
            p.control.terminate()
            p.control.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            try:
                p.control.kill()
                p.control.wait(timeout=1.0)
            except OSError:
                pass
        except OSError:
            pass
        if p.reader:
            p.reader.join(timeout=1.0)
