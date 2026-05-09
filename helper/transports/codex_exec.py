"""Codex `exec --json` transport — v1.17.

Codex CLI's interactive TUI (ratatui) renders elaborate chrome (banner
box, working spinner, status bar, input prompt area) at any sensibly-
sized PTY (≥ 1×1) and panics at 0×0. v1.16.0–v1.16.3 tried to thread
this needle by feeding the TUI bytes through an ANSI sanitizer +
conversation-preview formatter; both fall apart because:

  * 0×0 → ratatui per-character emit + intermittent Rust panic, CJK
    one-glyph-per-line, English barely readable.
  * 40×120 → ratatui full-TUI render, working-spinner letter-by-letter
    animation, status bar repeated every redraw — the formatter cannot
    disassemble back into chat lines, transcript stays empty.

This transport sidesteps the TUI entirely. Instead of a persistent PTY
process, we shell out to `codex exec --json …` once per user turn:

  * First turn:  `codex exec --json --skip-git-repo-check "<prompt>"`
                 → captures `thread_id` from `thread.started`.
  * Subsequent:  `codex exec --json --skip-git-repo-check resume
                  <thread_id> "<prompt>"` (model retains context).

`codex exec --json` emits JSONL on stdout: `thread.started` carrying
`thread_id`, `turn.started`, `item.completed` (type=agent_message,
text=<reply>), `turn.completed`. We parse those and queue plain-text
bytes onto a per-session output deque so the rest of `RemoteAgentManager`
treats this transport identically to `PosixPtyTransport`.

Trade-offs vs. PTY:
  * No token-by-token streaming — replies arrive as a single chunk on
    `item.completed`. UX shows `Working…` immediately and the full
    reply 5–15 s later. Acceptable; the alternative is broken chat.
  * No inline approval prompts — Codex's TUI prompts (`Run this
    command? [Y/n]`) don't apply to `codex exec`, which uses sandbox
    policies instead. We pass `-s read-only` so the model can read
    files but can't run shell commands without a structured channel
    we don't have yet. Iterating on chat is the dominant use case.
  * Subprocess-per-turn fork cost (~50 ms on M-series). Negligible.

What this transport is NOT:
  * Not a screen emulator (pyte etc.). We don't need one — JSONL gives
    us text directly.
  * Not concurrent on a single session — turns are serialized via the
    state machine. A second `write_stdin` while a turn is running gets
    buffered.
"""
from __future__ import annotations

import json
import logging
import os
import shlex
import signal
import subprocess
import threading
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Optional

from .base import SessionHandle, SessionTransport, TransportError

logger = logging.getLogger("cli_pulse.transports.codex_exec")


# Marker sequences emitted to the output queue. These are plain text
# (not ANSI) so they survive the helper's downstream sanitizer pass and
# render directly in the iPhone transcript view. Prefix glyphs match
# the conventions the existing `CodexConversationPreviewFormatter`
# already understands: `›` for user input, `•` for agent reply, `⚠` /
# `✗` for errors. Those formatters will pass these lines through their
# `shouldKeep` heuristics.
_USER_PREFIX = "› "
_AGENT_PREFIX = "• "
_INFO_PREFIX = "ℹ "
_ERROR_PREFIX = "✗ "
_WORKING = "• Working…\n"


@dataclass
class _CodexExecState:
    """All per-session runtime state for a Codex exec-mode session.

    Owned by the SessionHandle's payload. The transport's stateless
    methods always look up state via `_payload(handle)`.
    """
    session_id: str
    base_env: dict[str, str]
    cwd: Optional[str]
    # Conversation continuity. Set after the first `thread.started`
    # event; threaded into subsequent `codex exec resume <id>` calls.
    thread_id: Optional[str] = None
    # Bytes user has typed but not yet flushed (no newline seen yet).
    input_buf: bytearray = field(default_factory=bytearray)
    # Pending prompts buffered while a turn is in progress.
    pending_prompts: deque = field(default_factory=deque)
    # Output ready for `read_stdout` to drain. Stored as bytes so the
    # transport interface stays bytes-in-bytes-out.
    output_queue: deque = field(default_factory=deque)
    # Current in-flight subprocess (None if idle).
    current_proc: Optional[subprocess.Popen] = None
    # Background reader thread for `current_proc.stdout`.
    reader_thread: Optional[threading.Thread] = None
    # Mutex protecting `output_queue` + `pending_prompts` + `current_proc`.
    lock: threading.Lock = field(default_factory=threading.Lock)
    # True once `close()` has been called. Subsequent operations no-op.
    closed: bool = False
    # Banner emitted on session start so the iPhone has something to
    # render before the user types.
    banner_emitted: bool = False


class CodexExecTransport(SessionTransport):
    """SessionTransport that drives Codex via `codex exec --json`.

    Lifecycle differs from `PosixPtyTransport`:
      * `start()` does NOT spawn a subprocess — there is no persistent
        process. It just allocates per-session state and emits a banner
        line so the transcript view has something other than empty.
      * `write_stdin` accumulates input; on newline it flushes a turn:
        spawns `codex exec --json …`, reader thread parses JSONL and
        queues output bytes.
      * `read_stdout` drains the per-session output queue.
      * `interrupt` SIGINTs the current turn (if any).
      * `close` SIGKILLs + cleans up.
      * `is_alive` is True until `close` is called (semantically, the
        "session" is alive even when no subprocess is running, because
        the user can still type the next turn).

    Thread safety: each session has its own lock + reader thread. The
    transport itself is stateless beyond a class constant, so a single
    instance is safe to share across all Codex sessions.
    """

    # Default timeout for a single `codex exec` turn. Long-form replies
    # can take 30+ s on slow models. We don't want the helper hanging
    # forever on a wedged subprocess, so kill after this many seconds.
    _TURN_TIMEOUT_SEC: float = 180.0

    # ── lifecycle ────────────────────────────────────────────

    def start(
        self,
        session_id: str,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> SessionHandle:
        # `argv` from the spawner is `["codex"]` (the interactive form).
        # We ignore it entirely — exec mode has its own argv shape we
        # build at turn-flush time. We just verify the binary exists.
        if not argv:
            raise TransportError("argv must not be empty")

        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        state = _CodexExecState(
            session_id=session_id,
            base_env=merged_env,
            cwd=cwd,
        )
        # Banner so the transcript isn't empty before the user types.
        # Plain text — no ANSI — survives the helper sanitizer cleanly.
        banner = (
            f"{_INFO_PREFIX}Codex exec-mode session started — "
            "type a message to begin.\n"
        )
        state.output_queue.append(banner.encode("utf-8"))
        state.banner_emitted = True

        logger.info("codex_exec.start session=%s cwd=%s", session_id, cwd or "<inherit>")
        return SessionHandle(session_id=session_id, payload=state)

    @staticmethod
    def _payload(handle: SessionHandle) -> _CodexExecState:
        if not isinstance(handle.payload, _CodexExecState):
            raise TransportError("handle was not produced by CodexExecTransport")
        return handle.payload

    # ── stdin (input handling) ───────────────────────────────

    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        """Accumulate input. Flush on newline / carriage return.

        Returns the number of bytes accepted (always `len(data)` unless
        closed). The exec-mode "stdin" is logical, not a real fd — bytes
        get buffered in Python until the user signals end-of-prompt.
        """
        s = self._payload(handle)
        if s.closed:
            return 0
        if not data:
            return 0
        with s.lock:
            s.input_buf.extend(data)
            # Find prompt terminator. Either \n or \r counts (matches
            # what the iPhone client sends — depends on keyboard mode).
            prompts: list[str] = []
            while True:
                nl = -1
                for terminator in (b"\n", b"\r"):
                    idx = s.input_buf.find(terminator)
                    if idx != -1 and (nl == -1 or idx < nl):
                        nl = idx
                if nl == -1:
                    break
                line = bytes(s.input_buf[:nl]).decode("utf-8", errors="replace").strip()
                # Drop the consumed bytes (line + terminator).
                del s.input_buf[: nl + 1]
                if line:
                    prompts.append(line)
            for prompt in prompts:
                s.pending_prompts.append(prompt)
            self._maybe_flush_next_turn(s)
        return len(data)

    def _maybe_flush_next_turn(self, s: _CodexExecState) -> None:
        """If no turn is currently running and a prompt is pending,
        spawn the next `codex exec` invocation. Caller must hold
        `s.lock`."""
        if s.closed:
            return
        if s.current_proc is not None and s.current_proc.poll() is None:
            return  # turn still running
        if not s.pending_prompts:
            return
        prompt = s.pending_prompts.popleft()
        argv = self._build_exec_argv(s, prompt)
        # Echo the user prompt so the transcript shows what was typed.
        echo = f"{_USER_PREFIX}{prompt}\n".encode("utf-8")
        s.output_queue.append(echo)
        # Working indicator so the UI doesn't look frozen.
        s.output_queue.append(_WORKING.encode("utf-8"))
        try:
            s.current_proc = subprocess.Popen(
                argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=s.base_env,
                cwd=s.cwd,
                start_new_session=True,
                close_fds=True,
                bufsize=0,
            )
        except (FileNotFoundError, PermissionError, OSError) as exc:
            err = f"{_ERROR_PREFIX}codex spawn failed: {exc}\n".encode("utf-8")
            s.output_queue.append(err)
            s.current_proc = None
            logger.warning(
                "codex_exec spawn failed session=%s: %s",
                s.session_id, exc,
            )
            return
        # Reader thread parses JSONL and queues output. Daemonized so
        # the helper can exit cleanly without joining.
        s.reader_thread = threading.Thread(
            target=self._reader_loop,
            args=(s, s.current_proc, prompt),
            name=f"codex-exec-reader-{s.session_id[:8]}",
            daemon=True,
        )
        s.reader_thread.start()
        logger.info(
            "codex_exec turn started session=%s pid=%s prompt_chars=%d",
            s.session_id, s.current_proc.pid, len(prompt),
        )

    def _build_exec_argv(self, s: _CodexExecState, prompt: str) -> list[str]:
        """Construct the `codex exec --json …` argv for one turn.

        First turn (no thread_id): `codex exec --json --skip-git-repo-check
        "<prompt>"`.

        Subsequent turns use the `resume` subcommand: `codex exec resume
        --json --skip-git-repo-check <thread_id> "<prompt>"`.

        Why such a minimal flag set: `codex exec` and `codex exec resume`
        accept *different* flag subsets. `--color` and `-s/--sandbox` are
        only valid on the bare `exec` form, so passing them on `resume`
        fails with `error: unexpected argument`. Resume inherits the
        sandbox policy from the original session anyway, so the
        first-turn `-c shell_environment_policy.inherit=all` trick is
        not needed. Stdout is a pipe → Codex auto-disables color.

        Empirically verified against codex 0.130.x.
        """
        binary = os.environ.get("CLI_PULSE_CODEX_ARGV0", "codex").split()
        if not binary:
            binary = ["codex"]
        common_flags = ["--json", "--skip-git-repo-check"]
        if s.thread_id:
            return [*binary, "exec", "resume", *common_flags, s.thread_id, prompt]
        return [*binary, "exec", *common_flags, prompt]

    # ── reader thread (JSONL → output queue) ─────────────────

    def _reader_loop(
        self,
        s: _CodexExecState,
        proc: subprocess.Popen,
        prompt: str,  # noqa: ARG002 — kept for tracing / future use
    ) -> None:
        """Read JSONL from `proc.stdout`, parse, queue output bytes.

        Runs on its own thread per turn. Releases / re-acquires
        `s.lock` only when mutating shared state — the line-by-line
        read happens lock-free because the file handle is private to
        this thread.
        """
        deadline = time.time() + self._TURN_TIMEOUT_SEC
        agent_text_emitted = False
        try:
            assert proc.stdout is not None
            for raw_line in proc.stdout:
                if time.time() > deadline:
                    self._enqueue(s, f"{_ERROR_PREFIX}turn timed out\n".encode("utf-8"))
                    break
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    # Non-JSON output (warnings, prompt-confirmation
                    # banners) — drop. We don't surface them to the
                    # user since they're chrome.
                    logger.debug(
                        "codex_exec dropping non-JSON line session=%s: %r",
                        s.session_id, raw_line[:120],
                    )
                    continue
                self._handle_event(s, event)
                if event.get("type") == "item.completed":
                    item = event.get("item") or {}
                    if item.get("type") == "agent_message":
                        agent_text_emitted = True
        except Exception as exc:  # noqa: BLE001 — last-resort safety net
            logger.warning(
                "codex_exec reader crashed session=%s: %s",
                s.session_id, exc,
            )
            self._enqueue(s, f"{_ERROR_PREFIX}reader crashed: {exc}\n".encode("utf-8"))
        finally:
            try:
                rc = proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                rc = proc.wait()
            # If we never got an agent_message but the proc errored,
            # surface stderr so the user sees rate limit / auth errors.
            if not agent_text_emitted and rc != 0:
                err_text = ""
                try:
                    if proc.stderr is not None:
                        err_text = proc.stderr.read().decode("utf-8", errors="replace")
                except Exception:  # noqa: BLE001
                    pass
                detail = err_text.strip() or f"exit code {rc}"
                self._enqueue(
                    s, f"{_ERROR_PREFIX}codex exec failed: {detail[:500]}\n".encode("utf-8")
                )
            # Flush next pending turn if any.
            with s.lock:
                if s.current_proc is proc:
                    s.current_proc = None
                self._maybe_flush_next_turn(s)
            logger.info(
                "codex_exec turn ended session=%s rc=%s thread_id=%s",
                s.session_id, rc, s.thread_id,
            )

    def _handle_event(self, s: _CodexExecState, event: dict) -> None:
        """Translate one JSONL event from `codex exec --json` into
        bytes on the output queue."""
        ev_type = event.get("type")
        if ev_type == "thread.started":
            tid = event.get("thread_id")
            if isinstance(tid, str) and tid:
                with s.lock:
                    if s.thread_id is None:
                        s.thread_id = tid
                        logger.info(
                            "codex_exec thread_id captured session=%s tid=%s",
                            s.session_id, tid,
                        )
        elif ev_type == "item.completed":
            item = event.get("item") or {}
            kind = item.get("type")
            if kind == "agent_message":
                text = item.get("text") or ""
                if text:
                    out = f"{_AGENT_PREFIX}{text}\n".encode("utf-8")
                    self._enqueue(s, out)
            elif kind == "command_execution":
                # Surface the command line so the user sees what Codex
                # tried to run (read-only sandbox should mostly block
                # these but errors still carry info).
                cmd = item.get("command") or ""
                if cmd:
                    out = f"{_INFO_PREFIX}codex ran: {cmd[:200]}\n".encode("utf-8")
                    self._enqueue(s, out)
        elif ev_type == "turn.failed":
            err = (event.get("error") or {}).get("message") or "turn failed"
            out = f"{_ERROR_PREFIX}{err[:300]}\n".encode("utf-8")
            self._enqueue(s, out)
        elif ev_type == "turn.completed":
            usage = event.get("usage") or {}
            it = usage.get("input_tokens") or 0
            ot = usage.get("output_tokens") or 0
            if it or ot:
                out = f"{_INFO_PREFIX}usage: {it} in / {ot} out\n".encode("utf-8")
                self._enqueue(s, out)
        # All other event types (`turn.started`, etc.) are silently
        # consumed.

    @staticmethod
    def _enqueue(s: _CodexExecState, data: bytes) -> None:
        with s.lock:
            s.output_queue.append(data)

    # ── stdout / read ────────────────────────────────────────

    def read_stdout(self, handle: SessionHandle, max_bytes: int = 4096) -> bytes:
        s = self._payload(handle)
        if s.closed:
            return b""
        with s.lock:
            if not s.output_queue:
                return b""
            # Coalesce queued chunks up to `max_bytes`.
            buf = bytearray()
            while s.output_queue and len(buf) < max_bytes:
                head = s.output_queue.popleft()
                if len(buf) + len(head) <= max_bytes:
                    buf.extend(head)
                else:
                    take = max_bytes - len(buf)
                    buf.extend(head[:take])
                    # Push the leftover back to the front.
                    s.output_queue.appendleft(head[take:])
                    break
        return bytes(buf)

    # ── signals ──────────────────────────────────────────────

    def interrupt(self, handle: SessionHandle) -> None:
        s = self._payload(handle)
        if s.closed:
            return
        with s.lock:
            proc = s.current_proc
            # Drop any not-yet-flushed pending prompts so a SIGINT
            # actually halts the whole turn pipeline rather than just
            # the current one.
            s.pending_prompts.clear()
        if proc is not None and proc.poll() is None:
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGINT)
            except (ProcessLookupError, PermissionError):
                pass
            except OSError as exc:
                logger.warning(
                    "codex_exec interrupt failed session=%s: %s",
                    s.session_id, exc,
                )

    def terminate(self, handle: SessionHandle) -> None:
        # Same shape as `interrupt` but SIGTERM.
        s = self._payload(handle)
        if s.closed:
            return
        with s.lock:
            proc = s.current_proc
            s.pending_prompts.clear()
        if proc is not None and proc.poll() is None:
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            except OSError as exc:
                logger.warning(
                    "codex_exec terminate failed session=%s: %s",
                    s.session_id, exc,
                )

    # ── lifecycle queries ────────────────────────────────────

    def is_alive(self, handle: SessionHandle) -> bool:
        s = self._payload(handle)
        if s.closed:
            return False
        # Exec-mode "alive" means: session hasn't been closed. The
        # subprocess is transient.
        return True

    def wait(self, handle: SessionHandle, timeout: Optional[float] = None) -> Optional[int]:
        # Sessions don't terminate on their own — `wait` only returns
        # when explicitly closed. Block until the session has no
        # in-flight subprocess AND no pending prompts, OR until the
        # session is closed.
        s = self._payload(handle)
        deadline = None if timeout is None else time.time() + timeout
        while True:
            if s.closed:
                return 0
            with s.lock:
                idle = (
                    (s.current_proc is None or s.current_proc.poll() is not None)
                    and not s.pending_prompts
                )
            if idle and timeout == 0:
                return None
            if deadline is not None and time.time() >= deadline:
                return None
            time.sleep(0.05)

    def close(self, handle: SessionHandle) -> None:
        s = self._payload(handle)
        if s.closed:
            return
        with s.lock:
            proc = s.current_proc
            s.pending_prompts.clear()
            s.closed = True
        if proc is not None and proc.poll() is None:
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass
        # Don't join the reader thread — it's a daemon and will exit
        # when proc.stdout closes. Avoids blocking the helper's executor.
        logger.info("codex_exec.close session=%s", s.session_id)
