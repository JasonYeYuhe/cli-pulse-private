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
_WARN_PREFIX = "⚠ "
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
    # Background drainer thread for `current_proc.stderr`. Without this,
    # any codex stderr emission > pipe buffer (64KB on Linux, 16-64KB
    # dynamic on macOS) blocks codex on write(2) and the reader never
    # sees stdout EOF — turn deadlocks until the helper is killed.
    stderr_drainer_thread: Optional[threading.Thread] = None
    # Accumulating stderr collected by the drainer thread, capped at
    # 32KB. Read once in reader's finally block after the drainer has
    # finished. Always cleared at the start of a turn.
    stderr_buf: bytearray = field(default_factory=bytearray)
    # Watchdog Timer that SIGTERMs the proc after `_TURN_TIMEOUT_SEC`.
    # Replaces the previous in-reader-loop deadline check, which was
    # ineffective on silent network hangs because `for raw_line in
    # proc.stdout:` blocks indefinitely waiting for data that never
    # arrives. Armed at spawn, cancelled in reader's finally.
    timeout_timer: Optional[threading.Timer] = None
    # Set by `_timeout_kill` when the watchdog fires. Reader's finally
    # consults this so it can emit a precise "codex turn timed out"
    # marker instead of a misleading "exit code -15".
    timed_out: bool = False
    # Set by `interrupt()` under lock when a turn is killed via SIGINT.
    # Reader's finally consults this so it can emit "codex turn
    # cancelled" instead of "codex exec failed: exit code -2", which
    # made the user's own cancel look like a codex bug (P1-D).
    cancel_pending: bool = False
    # Mutex protecting `output_queue` + `pending_prompts` + `current_proc`
    # + `stderr_buf` writes by the drainer.
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
        # Fresh stderr buffer + flags for this turn.
        s.stderr_buf.clear()
        s.timed_out = False
        s.cancel_pending = False
        # Stderr drainer must start BEFORE the reader so the codex
        # process can never block on a full stderr pipe.
        s.stderr_drainer_thread = threading.Thread(
            target=self._stderr_drainer,
            args=(s, s.current_proc),
            name=f"codex-exec-stderr-{s.session_id[:8]}",
            daemon=True,
        )
        s.stderr_drainer_thread.start()
        # Arm watchdog Timer (P1-C). Fires after _TURN_TIMEOUT_SEC if
        # still alive — reader's finally cancels this on normal exit.
        s.timeout_timer = threading.Timer(
            self._TURN_TIMEOUT_SEC,
            self._timeout_kill,
            args=(s, s.current_proc),
        )
        s.timeout_timer.daemon = True
        s.timeout_timer.start()
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
        -s read-only "<prompt>"`. The `-s read-only` policy makes
        Codex's shell-execution channel deny anything beyond filesystem
        reads, which matches a chat-style use case where the model
        shouldn't be running mutating commands without an approval UI
        we don't have yet.

        Subsequent turns use the `resume` subcommand: `codex exec resume
        --json --skip-git-repo-check <thread_id> "<prompt>"`. Note that
        `resume` does NOT accept `-s/--sandbox` or `--color` — passing
        them yields `error: unexpected argument`. Resume inherits the
        sandbox policy from the original session, which is why we set
        it on turn 1 specifically. Stdout is a pipe → Codex auto-
        disables color, so we don't need `--color never`.

        Empirically verified against codex 0.130.x.

        The `"--"` is the POSIX end-of-options sentinel and is placed
        BEFORE every variable positional argument (prompt on first
        turn; thread_id + prompt on resume). Without it, any value
        starting with a dash — a user prompt like
        `--sandbox=danger-full-access`, or a thread_id corrupted via
        on-disk session state — would be parsed by Codex CLI's `clap`
        argument parser as a flag and could override the `-s read-only`
        policy we pin here, yielding a sandbox escape.
        """
        binary = os.environ.get("CLI_PULSE_CODEX_ARGV0", "codex").split()
        if not binary:
            binary = ["codex"]
        common_flags = ["--json", "--skip-git-repo-check"]
        if s.thread_id:
            return [*binary, "exec", "resume", *common_flags, "--", s.thread_id, prompt]
        # First turn: also pin the sandbox so resume inherits it.
        return [*binary, "exec", *common_flags, "-s", "read-only", "--", prompt]

    # ── stderr drainer + pipe cleanup ────────────────────────

    def _stderr_drainer(
        self,
        s: _CodexExecState,
        proc: subprocess.Popen,
    ) -> None:
        """Drain `proc.stderr` into `s.stderr_buf` until EOF.

        Runs on its own daemon thread, started by `_maybe_flush_next_turn`
        before the reader. Without this, a verbose stderr (> pipe-buffer
        size; 64KB Linux, 16-64KB macOS) blocks codex on `write(2)` and
        the reader never sees stdout EOF — the entire turn deadlocks.

        Buffer is capped at 32KB; anything past that tail-rotates so a
        runaway stderr can't OOM the helper. Reader's finally block reads
        the buffer lock-free AFTER waiting for proc death + joining this
        thread, so the bytearray is guaranteed stable at read time.
        """
        try:
            assert proc.stderr is not None
            while True:
                chunk = proc.stderr.read(4096)
                if not chunk:
                    break
                with s.lock:
                    s.stderr_buf.extend(chunk)
                    overflow = len(s.stderr_buf) - 32 * 1024
                    if overflow > 0:
                        del s.stderr_buf[:overflow]
        except Exception as exc:  # noqa: BLE001
            logger.debug(
                "codex_exec stderr drainer ended session=%s: %s",
                s.session_id, exc,
            )

    def _timeout_kill(
        self,
        s: _CodexExecState,
        proc: subprocess.Popen,
    ) -> None:
        """Watchdog target — SIGTERM the proc if still alive when the
        Timer fires. Sets `s.timed_out` so the reader's finally block
        can emit a clear `codex turn timed out` marker instead of a
        generic `exit code -15`.

        Race with normal exit is benign: signal to a dead pgid yields
        ProcessLookupError (caught); a flag set redundantly does no
        harm because the reader clears it after consumption.
        """
        try:
            if proc.poll() is not None:
                return
            with s.lock:
                s.timed_out = True
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                pass
        except Exception as exc:  # noqa: BLE001
            logger.debug(
                "codex_exec timeout_kill swallowed exc session=%s: %s",
                s.session_id, exc,
            )

    @staticmethod
    def _close_proc_pipes(proc: subprocess.Popen) -> None:
        """Idempotently close `proc.stdout` and `proc.stderr` fds.

        Without this, each turn leaks one stdout fd + one stderr fd
        because `subprocess.Popen` file-objects are GC-finalized at
        unpredictable points. Long sessions (100+ turns) can exhaust
        the helper's ulimit. Tolerates already-closed streams."""
        for stream in (proc.stdout, proc.stderr):
            if stream is None:
                continue
            try:
                stream.close()
            except Exception:  # noqa: BLE001 — best-effort close
                pass

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

        Turn timeout is enforced externally by the `_timeout_kill`
        watchdog Timer armed in `_maybe_flush_next_turn` (P1-C). The
        previous in-loop `if time.time() > deadline` check was a no-op
        on silent network hangs because `for raw_line in proc.stdout:`
        blocks indefinitely waiting for data that never arrives.
        """
        agent_text_emitted = False
        try:
            assert proc.stdout is not None
            for raw_line in proc.stdout:
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
                if not isinstance(event, dict):
                    # JSON parsed but is a primitive (null / true / number /
                    # string) or array. _handle_event calls .get() and would
                    # AttributeError on these, crashing the reader thread
                    # silently. Drop with a warning so Codex CLI schema
                    # drift is visible in the helper log.
                    logger.warning(
                        "codex_exec dropping non-object JSON line session=%s: %r",
                        s.session_id, line[:120],
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
            # Cleanup order is load-bearing — see DEV_PLAN_v1.18.2.md
            # Gemini CRITICAL fix:
            #   ① disarm watchdog Timer (idempotent if already fired)
            #   ② reap the process (forces stderr EOF)
            #   ③ join drainer (now instant since EOF reached)
            #   ④ read stderr_buf lock-free (drainer is dead)
            #   ⑤ consume per-turn flags under lock
            #   ⑥ pick marker
            #   ⑦ close fds (P1-A: avoid fd leak per turn)
            #   ⑧ release current_proc slot under lock + flush next
            with s.lock:
                timer = s.timeout_timer
            if timer is not None:
                timer.cancel()
            try:
                rc = proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                rc = proc.wait()
            # Drainer should have exited on stderr EOF when the proc
            # died. join(1.0) is a bounded safety belt — if it ever
            # times out, the daemon thread is still safe to leave alive
            # because the helper exit doesn't depend on it.
            with s.lock:
                drainer = s.stderr_drainer_thread
            if drainer is not None:
                drainer.join(timeout=1.0)
            # Now safe to read the buffer without a lock (drainer dead).
            stderr_text = bytes(s.stderr_buf).decode("utf-8", errors="replace")
            with s.lock:
                timed_out = s.timed_out
                cancel = s.cancel_pending
                thread_captured = s.thread_id is not None
                s.timed_out = False
                s.cancel_pending = False
            # Marker precedence (DEV_PLAN_v1.18.2.md decision table):
            #   timed_out > cancel > failure path > happy path.
            primary_failure = False
            if timed_out:
                self._enqueue(
                    s, f"{_ERROR_PREFIX}codex turn timed out\n".encode("utf-8")
                )
                primary_failure = True
            elif cancel:
                self._enqueue(
                    s, f"{_ERROR_PREFIX}codex turn cancelled\n".encode("utf-8")
                )
                primary_failure = True
            elif not agent_text_emitted and rc != 0:
                detail = stderr_text.strip() or f"exit code {rc}"
                self._enqueue(
                    s, f"{_ERROR_PREFIX}codex exec failed: {detail[:500]}\n".encode("utf-8")
                )
                primary_failure = True
            elif not agent_text_emitted and rc == 0:
                # Edge: codex exited cleanly but emitted no agent text
                # (corrupt JSONL, unsupported event types, etc.). Tell
                # the user so they don't stare at silence.
                self._enqueue(
                    s, f"{_WARN_PREFIX}codex exited without reply\n".encode("utf-8")
                )
                primary_failure = True
            # Session-reset append (P1-E + Gemini SHOULD_FIX 2): if the
            # turn ended on any non-happy path AND no thread_id was ever
            # captured this session, the next prompt will silently start
            # a new conversation. Warn explicitly.
            if primary_failure and not thread_captured:
                self._enqueue(
                    s,
                    f"{_WARN_PREFIX}Session reset — your next prompt will start "
                    "a new conversation\n".encode("utf-8"),
                )
            # Explicitly close pipes so fds are released NOW rather
            # than at GC time (P1-A).
            self._close_proc_pipes(proc)
            # Flush next pending turn if any.
            with s.lock:
                if s.current_proc is proc:
                    s.current_proc = None
                self._maybe_flush_next_turn(s)
            logger.info(
                "codex_exec turn ended session=%s rc=%s thread_id=%s "
                "timed_out=%s cancelled=%s",
                s.session_id, rc, s.thread_id, timed_out, cancel,
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
                    # Prefix EVERY line. The Codex conversation-preview
                    # formatter splits on `\n` and applies its
                    # `shouldKeep` heuristic per-line; without a per-
                    # line `•` marker, lines after the first only
                    # survive via the prose-shape fallback (alnum>=8),
                    # which can drop short replies, code-block
                    # terminators, etc.
                    lines = text.splitlines() or [""]
                    prefixed = "".join(f"{_AGENT_PREFIX}{line}\n" for line in lines)
                    self._enqueue(s, prefixed.encode("utf-8"))
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
            # Signal the reader's finally to emit a "cancelled" marker
            # rather than a generic "exec failed: exit code -2" (P1-D).
            # Lock-guarded so it can't race with the next-turn spawn
            # that clears the flag.
            if proc is not None and proc.poll() is None:
                s.cancel_pending = True
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
