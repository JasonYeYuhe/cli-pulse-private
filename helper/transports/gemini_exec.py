"""Gemini `gemini -p … -o stream-json` transport — v1.19+.

Mirrors `CodexExecTransport`'s subprocess-per-turn architecture: each
user prompt spawns a fresh `gemini` subprocess in headless mode
(`--prompt`), reads newline-delimited JSON events on stdout, and
queues plain-text lines for the iPhone transcript view.

Why subprocess-per-turn for Gemini (matches codex's v1.17 carve-out):

  * Gemini CLI's interactive mode renders a TUI with banner / status
    bar / input prompt — same class of problem codex's ratatui had
    when fed through our PTY-on-tiny-window pipeline. The transcript
    formatter can't reliably reassemble a TUI render into chat
    messages.
  * `-o stream-json` gives us structured events: `init` (session
    metadata), `message` (user/assistant/system content; partial
    chunks carry `delta:true`), `tool_call` / `tool_result`,
    `result` (final status + usage stats). No ANSI parsing, no
    cursor-position heuristics.
  * Cancel + timeout via SIGINT/SIGTERM to the process group instead
    of "type some escape sequence and hope the TUI honors it."

First-turn argv:
    gemini --skip-trust -p "<prompt>" -o stream-json \\
           --approval-mode default

Subsequent turns (resume the most-recent session in this CWD):
    gemini --skip-trust -p "<prompt>" -o stream-json \\
           --approval-mode default --resume latest

Gemini CLI's `--resume` accepts `"latest"` or an index — NOT the UUID
session_id captured from the `init` event. Sessions are scoped to the
current working directory + project, so "latest" reliably picks up the
session we just spawned as long as no other gemini process intervenes
(unlikely while a managed session is in progress).

Event schema parsed (gemini-cli 0.41.x):

    {"type":"init", "timestamp":..., "session_id":"<uuid>",
     "model":"gemini-2.5-flash" | "gemini-3.1-pro-preview" | ...}
    {"type":"message", "role":"user", "content":"<echo>"}    # we drop
    {"type":"message", "role":"assistant", "content":"<chunk>",
     "delta":true}                                           # accumulate
    {"type":"message", "role":"system", "content":"<info>"}  # rare; emit
    {"type":"tool_call", "name":"...", ...}                   # surface name
    {"type":"tool_result", ...}                                # surface briefly
    {"type":"thought", "content":"..."}                       # drop
    {"type":"result", "status":"success", "stats":{"total_tokens":N,
     "input_tokens":N, "output_tokens":N, "cached":N, ...}}
    {"type":"result", "status":"error", "error":{"message":"..."}}

Trade-offs vs PTY:

  * No token-by-token streaming on screen. Deltas are buffered in
    memory and the full assistant reply emits in one chunk on
    `result`. Same UX trade-off codex made — see codex_exec module
    docstring for the rationale.
  * No inline tool-approval prompts. We pin `--approval-mode default`
    by default; the `CLI_PULSE_GEMINI_YOLO=1` opt-in (already wired
    through `provider_spawners/gemini.py`) swaps to `--approval-mode
    yolo` for users who explicitly accept that risk.
  * Subprocess fork cost (~50–80ms on M-series). Negligible.

What this transport is NOT:

  * Not a screen emulator. We don't need one — stream-json gives us
    structured text directly.
  * Not concurrent on a single session. Turns are serialised through
    the same `pending_prompts` deque codex_exec uses.
  * Not responsible for advertising Gemini in the provider picker —
    that lives in `provider_spawners/gemini.py` + iOS UI. This file
    only owns the wire protocol once the manager has decided to spawn
    "gemini".
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

logger = logging.getLogger("cli_pulse.transports.gemini_exec")


# Marker glyphs — same convention as codex_exec for downstream
# transcript-formatter compatibility (CodexConversationPreviewFormatter +
# GeminiConversationPreviewFormatter both look for these).
_USER_PREFIX = "› "
_AGENT_PREFIX = "• "
_INFO_PREFIX = "ℹ "
_ERROR_PREFIX = "✗ "
_WARN_PREFIX = "⚠ "
_WORKING = "• Working…\n"


@dataclass
class _GeminiExecState:
    """All per-session runtime state for a Gemini exec-mode session.

    Owned by the SessionHandle's payload. The transport's stateless
    methods always look up state via `_payload(handle)`.
    """
    session_id: str
    base_env: dict[str, str]
    cwd: Optional[str]
    # Conversation continuity. Set after the first `init` event;
    # informational only (resume uses `latest`, not this UUID).
    gemini_session_id: Optional[str] = None
    # True once we've issued at least one successful turn — used to
    # decide whether to pass `--resume latest` on subsequent turns.
    has_prior_turn: bool = False
    # Bytes user has typed but not yet flushed (no newline seen yet).
    input_buf: bytearray = field(default_factory=bytearray)
    # Pending prompts buffered while a turn is in progress.
    pending_prompts: deque = field(default_factory=deque)
    # Output ready for `read_stdout` to drain. Bytes (not str).
    output_queue: deque = field(default_factory=deque)
    # Current in-flight subprocess (None if idle).
    current_proc: Optional[subprocess.Popen] = None
    # Background reader thread for `current_proc.stdout`.
    reader_thread: Optional[threading.Thread] = None
    # Background drainer thread for `current_proc.stderr`. Without
    # this, any gemini stderr emission > pipe buffer (64KB Linux,
    # 16-64KB dynamic on macOS) blocks gemini on write(2) and the
    # reader never sees stdout EOF — turn deadlocks until kill.
    stderr_drainer_thread: Optional[threading.Thread] = None
    # Accumulating stderr collected by the drainer, capped at 32KB.
    stderr_buf: bytearray = field(default_factory=bytearray)
    # Watchdog Timer that SIGTERMs the proc after `_TURN_TIMEOUT_SEC`.
    timeout_timer: Optional[threading.Timer] = None
    # Set by `_timeout_kill` when the watchdog fires.
    timed_out: bool = False
    # Set by `interrupt()` / `terminate()` so the reader's finally can
    # emit "gemini turn cancelled" instead of "exit code -2".
    cancel_pending: bool = False
    # Pending usage marker captured from the `result` event. Emitted
    # AFTER the agent text in the reader's finally so the transcript
    # reads "• reply" → "ℹ usage:" instead of the reverse (the result
    # event arrives in-stream BEFORE the reader exits, so this lets us
    # defer emission until after the agent_text_buffer flush).
    pending_usage_line: Optional[bytes] = None
    # Mutex protecting `output_queue` + `pending_prompts` +
    # `current_proc` + `stderr_buf` writes.
    lock: threading.Lock = field(default_factory=threading.Lock)
    # True once `close()` has been called. Subsequent operations no-op.
    closed: bool = False
    # Banner emitted on session start.
    banner_emitted: bool = False


class GeminiExecTransport(SessionTransport):
    """SessionTransport that drives Gemini via `gemini -p … -o stream-json`.

    Lifecycle differs from `PosixPtyTransport`:
      * `start()` does NOT spawn a subprocess — the "session" is
        logical; subprocesses fire only at turn-flush time.
      * `write_stdin` accumulates input; on newline it spawns
        `gemini -p …`, reader thread parses stream-json + queues
        output bytes.
      * `read_stdout` drains the per-session output queue.
      * `interrupt` SIGINTs the current turn (if any).
      * `close` SIGKILLs + cleans up.

    Thread safety: each session has its own lock + reader thread. The
    transport itself is stateless beyond a class constant, so a single
    instance is safe to share across all Gemini sessions.
    """

    # Default timeout for a single gemini turn. Long-form replies can
    # take 30+ s. Kill after this many seconds.
    _TURN_TIMEOUT_SEC: float = 180.0

    # ── lifecycle ────────────────────────────────────────────

    def start(
        self,
        session_id: str,
        argv: list[str],
        env: Optional[dict[str, str]] = None,
        cwd: Optional[str] = None,
    ) -> SessionHandle:
        # `argv` from the spawner is `["gemini"]` (the interactive
        # form). We ignore it — exec mode builds its own argv at
        # turn-flush time. Verify it's non-empty so a buggy spawner
        # produces a clean error rather than a mystery crash.
        if not argv:
            raise TransportError("argv must not be empty")

        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        state = _GeminiExecState(
            session_id=session_id,
            base_env=merged_env,
            cwd=cwd,
        )
        banner = (
            f"{_INFO_PREFIX}Gemini exec-mode session started — "
            "type a message to begin.\n"
        )
        state.output_queue.append(banner.encode("utf-8"))
        state.banner_emitted = True

        logger.info(
            "gemini_exec.start session=%s cwd=%s",
            session_id, cwd or "<inherit>",
        )
        return SessionHandle(session_id=session_id, payload=state)

    @staticmethod
    def _payload(handle: SessionHandle) -> _GeminiExecState:
        if not isinstance(handle.payload, _GeminiExecState):
            raise TransportError("handle was not produced by GeminiExecTransport")
        return handle.payload

    # ── stdin (input handling) ───────────────────────────────

    def write_stdin(self, handle: SessionHandle, data: bytes) -> int:
        """Accumulate input. Flush on newline / carriage return."""
        s = self._payload(handle)
        if s.closed:
            return 0
        if not data:
            return 0
        with s.lock:
            s.input_buf.extend(data)
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
                del s.input_buf[: nl + 1]
                if line:
                    prompts.append(line)
            for prompt in prompts:
                s.pending_prompts.append(prompt)
            self._maybe_flush_next_turn(s)
        return len(data)

    def _maybe_flush_next_turn(self, s: _GeminiExecState) -> None:
        """If idle and a prompt is pending, spawn the next gemini
        invocation. Caller must hold `s.lock`."""
        if s.closed:
            return
        if s.current_proc is not None and s.current_proc.poll() is None:
            return
        if not s.pending_prompts:
            return
        prompt = s.pending_prompts.popleft()
        argv = self._build_exec_argv(s, prompt)
        echo = f"{_USER_PREFIX}{prompt}\n".encode("utf-8")
        s.output_queue.append(echo)
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
            err = f"{_ERROR_PREFIX}gemini spawn failed: {exc}\n".encode("utf-8")
            s.output_queue.append(err)
            s.current_proc = None
            logger.warning(
                "gemini_exec spawn failed session=%s: %s",
                s.session_id, exc,
            )
            return
        s.stderr_buf.clear()
        s.timed_out = False
        s.cancel_pending = False
        s.stderr_drainer_thread = threading.Thread(
            target=self._stderr_drainer,
            args=(s, s.current_proc),
            name=f"gemini-exec-stderr-{s.session_id[:8]}",
            daemon=True,
        )
        s.stderr_drainer_thread.start()
        s.timeout_timer = threading.Timer(
            self._TURN_TIMEOUT_SEC,
            self._timeout_kill,
            args=(s, s.current_proc),
        )
        s.timeout_timer.daemon = True
        s.timeout_timer.start()
        s.reader_thread = threading.Thread(
            target=self._reader_loop,
            args=(s, s.current_proc, prompt),
            name=f"gemini-exec-reader-{s.session_id[:8]}",
            daemon=True,
        )
        s.reader_thread.start()
        logger.info(
            "gemini_exec turn started session=%s pid=%s prompt_chars=%d resume=%s",
            s.session_id, s.current_proc.pid, len(prompt), s.has_prior_turn,
        )

    def _build_exec_argv(self, s: _GeminiExecState, prompt: str) -> list[str]:
        """Construct the gemini argv for one turn.

        First turn (no prior turn captured):
            gemini --skip-trust -o stream-json \\
                   --approval-mode <mode> -p "<prompt>"

        Subsequent turns:
            same + --resume latest

        `--skip-trust` bypasses the per-CWD trust prompt that
        otherwise blocks headless mode. `-o stream-json` emits one
        JSON object per event on stdout (parsed by `_reader_loop`).
        `--approval-mode default` is the safe baseline; the
        `CLI_PULSE_GEMINI_YOLO=1` env var (forwarded by
        `provider_spawners/gemini.py`) swaps to `yolo`.

        `-p <prompt>` MUST appear LAST with the prompt immediately
        following: gemini's CLI parses `-p` as a flag-with-value where
        the next argv element is consumed as the value. Inserting a
        `--` sentinel between `-p` and the prompt makes gemini complain
        "Not enough arguments following: p". A prompt starting with
        `--anything` cannot be misparsed because `-p` has already
        claimed it as its string value, not as another flag.
        """
        binary = os.environ.get("CLI_PULSE_GEMINI_ARGV0", "gemini").split()
        if not binary:
            binary = ["gemini"]

        approval_mode = "default"
        if s.base_env.get("CLI_PULSE_GEMINI_YOLO") in ("1", "true", "yes"):
            approval_mode = "yolo"

        # Model selection: pin via env if set, else let gemini default.
        # Tests use CLI_PULSE_GEMINI_MODEL=gemini-2.5-flash to keep
        # quota separate from the pro model.
        model_flags: list[str] = []
        model = s.base_env.get("CLI_PULSE_GEMINI_MODEL", "").strip()
        if model:
            model_flags = ["-m", model]

        common = [
            "--skip-trust",
            "-o", "stream-json",
            "--approval-mode", approval_mode,
            *model_flags,
        ]
        if s.has_prior_turn:
            return [*binary, *common, "--resume", "latest", "-p", prompt]
        # First turn — no --resume.
        return [*binary, *common, "-p", prompt]

    # ── stderr drainer + pipe cleanup ────────────────────────

    def _stderr_drainer(
        self,
        s: _GeminiExecState,
        proc: subprocess.Popen,
    ) -> None:
        """Drain proc.stderr until EOF. Without this, verbose stderr
        deadlocks the turn (same risk pattern codex_exec hit)."""
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
                "gemini_exec stderr drainer ended session=%s: %s",
                s.session_id, exc,
            )

    def _timeout_kill(
        self,
        s: _GeminiExecState,
        proc: subprocess.Popen,
    ) -> None:
        """Watchdog target — SIGTERM the proc if still alive when the
        Timer fires."""
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
                "gemini_exec timeout_kill swallowed exc session=%s: %s",
                s.session_id, exc,
            )

    @staticmethod
    def _close_proc_pipes(proc: subprocess.Popen) -> None:
        """Idempotently close proc.stdout + proc.stderr fds. Without
        this, each turn leaks one stdout fd + one stderr fd at GC time."""
        for stream in (proc.stdout, proc.stderr):
            if stream is None:
                continue
            try:
                stream.close()
            except Exception:  # noqa: BLE001
                pass

    # ── reader thread (stream-json → output queue) ──────────

    def _reader_loop(
        self,
        s: _GeminiExecState,
        proc: subprocess.Popen,
        prompt: str,  # noqa: ARG002 — kept for tracing
    ) -> None:
        """Read stream-json from proc.stdout, parse, queue output.

        Gemini delta semantics: assistant `message` events carry a
        `delta:true` field and partial `content`. We accumulate
        deltas in a local buffer and emit ONCE at end-of-turn so the
        transcript view sees a coherent reply (matches codex's
        single-chunk-per-turn UX choice). Token-by-token streaming
        would require coordinating with the GeminiConversationPreview
        Formatter on partial-line handling — deferred to a future
        round.
        """
        agent_text_buffer: list[str] = []
        turn_failed_emitted = False
        try:
            assert proc.stdout is not None
            for raw_line in proc.stdout:
                line = raw_line.strip()
                if not line:
                    continue
                try:
                    event = json.loads(line)
                except json.JSONDecodeError:
                    logger.debug(
                        "gemini_exec dropping non-JSON line session=%s: %r",
                        s.session_id, raw_line[:120],
                    )
                    continue
                if not isinstance(event, dict):
                    logger.warning(
                        "gemini_exec dropping non-object JSON line session=%s: %r",
                        s.session_id, line[:120],
                    )
                    continue
                handler_result = self._handle_event(s, event, agent_text_buffer)
                if handler_result == "turn_failed":
                    turn_failed_emitted = True
        except Exception as exc:  # noqa: BLE001
            logger.warning(
                "gemini_exec reader crashed session=%s: %s",
                s.session_id, exc,
            )
            self._enqueue(s, f"{_ERROR_PREFIX}reader crashed: {exc}\n".encode("utf-8"))
        finally:
            # Cleanup order (mirrors codex_exec — same risk class):
            #   ① disarm watchdog Timer
            #   ② reap process (forces stderr EOF)
            #   ③ join drainer (instant after EOF)
            #   ④ read stderr_buf lock-free
            #   ⑤ consume per-turn flags under lock
            #   ⑥ emit accumulated agent text if any
            #   ⑦ pick failure marker if applicable
            #   ⑧ close fds (P1-A: avoid fd leak per turn)
            #   ⑨ release current_proc slot + flush next
            with s.lock:
                timer = s.timeout_timer
            if timer is not None:
                timer.cancel()
            try:
                rc = proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                rc = proc.wait()
            with s.lock:
                drainer = s.stderr_drainer_thread
            if drainer is not None:
                drainer.join(timeout=1.0)
            with s.lock:
                stderr_text = bytes(s.stderr_buf).decode(
                    "utf-8", errors="replace"
                )
                timed_out = s.timed_out
                cancel = s.cancel_pending
                s.timed_out = False
                s.cancel_pending = False

            # Emit accumulated agent text (if any) BEFORE the failure
            # markers, so the transcript shows partial output even
            # when the turn timed out / failed mid-stream.
            agent_text_emitted = False
            if agent_text_buffer:
                joined = "".join(agent_text_buffer)
                lines = joined.splitlines() or [""]
                prefixed = "".join(f"{_AGENT_PREFIX}{line}\n" for line in lines)
                self._enqueue(s, prefixed.encode("utf-8"))
                agent_text_emitted = True

            # Emit deferred usage line AFTER the agent text so the
            # transcript reads "• reply" then "ℹ usage:" in natural
            # order. Consume + clear under lock.
            with s.lock:
                usage_line = s.pending_usage_line
                s.pending_usage_line = None
            if usage_line is not None and agent_text_emitted:
                self._enqueue(s, usage_line)

            # Marker precedence: timed_out > cancel > turn_failed
            # (suppress dup) > failure path > happy path.
            primary_failure = False
            if timed_out:
                self._enqueue(
                    s, f"{_ERROR_PREFIX}gemini turn timed out\n".encode("utf-8")
                )
                primary_failure = True
            elif cancel:
                self._enqueue(
                    s, f"{_ERROR_PREFIX}gemini turn cancelled\n".encode("utf-8")
                )
                primary_failure = True
            elif turn_failed_emitted:
                # `_handle_event` already surfaced the gemini-side
                # error. Skip the generic `exit code` marker but
                # still track for session-reset append below.
                primary_failure = True
            elif not agent_text_emitted and rc != 0:
                detail = stderr_text.strip() or f"exit code {rc}"
                self._enqueue(
                    s, f"{_ERROR_PREFIX}gemini exec failed: {detail[:500]}\n".encode("utf-8")
                )
                primary_failure = True
            elif not agent_text_emitted and rc == 0:
                self._enqueue(
                    s, f"{_WARN_PREFIX}gemini exited without reply\n".encode("utf-8")
                )
                primary_failure = True
            else:
                # Happy path: mark this session as having captured a
                # prior turn so subsequent turns use --resume latest.
                with s.lock:
                    s.has_prior_turn = True
            self._close_proc_pipes(proc)
            with s.lock:
                if s.current_proc is proc:
                    s.current_proc = None
                self._maybe_flush_next_turn(s)
            logger.info(
                "gemini_exec turn ended session=%s rc=%s gemini_sid=%s "
                "timed_out=%s cancelled=%s",
                s.session_id, rc, s.gemini_session_id, timed_out, cancel,
            )

    def _handle_event(
        self,
        s: _GeminiExecState,
        event: dict,
        agent_text_buffer: list[str],
    ) -> str:
        """Translate one stream-json event from gemini into bytes on
        the output queue (or into the agent_text_buffer for assistant
        deltas). Returns one of:
            "ok"          — handled, no special downstream signal
            "turn_failed" — `result` arrived with status=error
        """
        ev_type = event.get("type")
        if ev_type == "init":
            sid = event.get("session_id")
            model = event.get("model")
            if isinstance(sid, str) and sid:
                with s.lock:
                    if s.gemini_session_id is None:
                        s.gemini_session_id = sid
                        logger.info(
                            "gemini_exec session_id captured session=%s gemini_sid=%s model=%s",
                            s.session_id, sid, model,
                        )
        elif ev_type == "message":
            role = event.get("role")
            if role == "user":
                # We already echoed the user prompt in
                # _maybe_flush_next_turn — drop the gemini echo to
                # avoid duplicates.
                return "ok"
            content = event.get("content")
            if not isinstance(content, str) or not content:
                return "ok"
            if role == "assistant":
                # Delta accumulation — emit at end of turn.
                agent_text_buffer.append(content)
            elif role == "system":
                # Rare — but if gemini wants to tell the user
                # something out-of-band, surface it.
                self._enqueue(
                    s, f"{_INFO_PREFIX}{content[:300]}\n".encode("utf-8")
                )
        elif ev_type == "tool_call":
            # Drop — Gemini runs many internal tool calls per prompt
            # (file reads, searches, etc.) and surfacing each one
            # spams the transcript. The assistant reply already
            # summarizes what was done. Re-introduce with a filter
            # (e.g. only user-facing tool kinds) if a clear UX need
            # appears in v1.19.x usage data.
            return "ok"
        elif ev_type == "tool_result":
            # Same reasoning as tool_call — drop.
            return "ok"
        elif ev_type == "thought":
            # Drop — the assistant's reasoning chain isn't part of
            # the transcript surface.
            return "ok"
        elif ev_type == "result":
            status = event.get("status")
            if status == "error":
                err = (event.get("error") or {}).get("message") or "turn failed"
                self._enqueue(
                    s, f"{_ERROR_PREFIX}{err[:300]}\n".encode("utf-8")
                )
                return "turn_failed"
            # status == "success" — defer usage emission until after
            # the agent text so the transcript reads in the natural
            # order: reply then stats. The reader's finally block
            # consumes pending_usage_line after the agent_text_buffer
            # flush.
            stats = event.get("stats") or {}
            it = stats.get("input_tokens") or 0
            ot = stats.get("output_tokens") or 0
            cached = stats.get("cached") or 0
            if it or ot or cached:
                bits = [f"{it} in", f"{ot} out"]
                if cached:
                    bits.append(f"{cached} cached")
                with s.lock:
                    s.pending_usage_line = (
                        f"{_INFO_PREFIX}usage: {' / '.join(bits)}\n"
                    ).encode("utf-8")
        # Any other event types silently consumed.
        return "ok"

    @staticmethod
    def _enqueue(s: _GeminiExecState, data: bytes) -> None:
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
            buf = bytearray()
            while s.output_queue and len(buf) < max_bytes:
                head = s.output_queue.popleft()
                if len(buf) + len(head) <= max_bytes:
                    buf.extend(head)
                else:
                    take = max_bytes - len(buf)
                    buf.extend(head[:take])
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
            s.pending_prompts.clear()
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
                    "gemini_exec interrupt failed session=%s: %s",
                    s.session_id, exc,
                )

    def terminate(self, handle: SessionHandle) -> None:
        s = self._payload(handle)
        if s.closed:
            return
        with s.lock:
            proc = s.current_proc
            s.pending_prompts.clear()
            if proc is not None and proc.poll() is None:
                s.cancel_pending = True
        if proc is not None and proc.poll() is None:
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                pass
            except OSError as exc:
                logger.warning(
                    "gemini_exec terminate failed session=%s: %s",
                    s.session_id, exc,
                )

    # ── lifecycle queries ────────────────────────────────────

    def is_alive(self, handle: SessionHandle) -> bool:
        s = self._payload(handle)
        if s.closed:
            return False
        return True

    def wait(self, handle: SessionHandle, timeout: Optional[float] = None) -> Optional[int]:
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
            timer = s.timeout_timer
        if timer is not None:
            timer.cancel()
        if proc is not None and proc.poll() is None:
            try:
                pgid = os.getpgid(proc.pid)
                os.killpg(pgid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError, OSError):
                pass
        logger.info("gemini_exec.close session=%s", s.session_id)
