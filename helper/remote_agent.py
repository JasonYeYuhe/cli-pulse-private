"""Managed remote-agent sessions — iter 1 of "Sessions Input".

Phase 1 (shipped in v1.11.0/44) only delivered remote APPROVALS through the
hook (`remote_hook.py`). iter 1 of Phase 2 adds **managed sessions** — the
helper actually spawns the provider CLI under a PTY so the app can:

  * Send free-text prompts via `RemoteCommandKind.prompt`.
  * Stop the session via `RemoteCommandKind.stop`.
  * Interrupt (SIGINT-equivalent) via `RemoteCommandKind.interrupt`.
  * Approve a permission request inline because the request's
    `session_id` matches the managed session row (the hook reads
    `CLI_PULSE_REMOTE_SESSION_ID` we set on the child env so this binding
    works without Claude having to know about us).

What this module does NOT do:

  * Spawn `codex` or `shell`. Codex/shell adapters remain Phase-2 stubs.
    The new `remote_app_request_session_start` RPC rejects providers
    other than `claude` server-side.
  * Upload stdout/stderr event tail. The cap is 4 KB / row and the
    plumbing is here, but iter 1 deliberately does not call
    `remote_helper_post_event` for stdout/stderr — only lifecycle
    `status` rows. Tail-streaming UI is a separate iter.
  * ConPTY (Windows). `RemoteAgentManager` accepts the transport via
    dependency injection; the cli-pulse-desktop track will plug in the
    Windows transport against the same protocol (see
    `helper/transports/conpty.py`).

Privacy / security posture (unchanged from Phase 1):
  * Default OFF. The helper RPCs are gated by
    `_remote_authenticate_helper_gated`. If the user toggles Remote
    Control off mid-session, `remote_helper_pull_commands` raises and
    the manager catches → no further dispatch happens until the user
    re-enables.
  * Free-text prompt payload is whatever the user typed; we do NOT
    filter or transform it before write_stdin. If the user typed a
    high-risk shell command, Claude Code's own permission prompt fires
    when Claude tries to run it, and that prompt round-trips through
    the existing hook → remote-approval surface. (Shell provider is
    deferred and MUST add a high-risk filter on the prompt payload
    before it ships.)
"""
from __future__ import annotations

import json
import logging
import sys
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

from local_executor import LocalExecutor
from redaction import redact
from transports import SessionHandle, SessionTransport, TransportError

logger = logging.getLogger("cli_pulse.remote_agent")


# Maximum number of bytes to stash in the per-session stdout buffer before
# we discard the oldest. Even with the iter-2 batched uploader landing
# events ≤ 4 KB / row every ~0.5 s, this cap is the safety net for
# transient upload failures (network blip, gate flip mid-cycle): the
# batcher's payloads stay buffered locally until upload succeeds, but
# we never let a single session balloon manager memory.
_STDOUT_BUFFER_CAP_BYTES = 64 * 1024

# Server-side row CHECK is `length(payload) <= 4096`. Keep the helper's
# per-event cap a hair under so a UTF-8 boundary fix (see
# `_safe_truncate_utf8`) can't push a payload over.
_EVENT_PAYLOAD_CAP_CHARS = 4000

# `kind='info'` carries lifecycle detail (spawn-failure reason, exit
# code, "child gone" hint). We bound it harder than stdout because info
# rows are inherently short — anything longer has likely sucked in a
# stack trace we'd rather elide.
_INFO_PAYLOAD_CAP_CHARS = 1024


@dataclass
class SessionStartParams:
    """Inputs for `RemoteAgentManager.spawn_session`. All snake_case."""

    session_id: str
    provider: str                              # Always 'claude' in iter 1
    cwd: str = ""                              # Helper-resolvable path; '' → CWD
    cwd_hmac: str | None = None
    client_label: str | None = None
    extra_env: dict[str, str] = field(default_factory=dict)


@dataclass
class _ManagedSession:
    """Per-session runtime bookkeeping owned by `RemoteAgentManager`."""

    params: SessionStartParams
    handle: SessionHandle
    spawned_at: float
    # iter-2: hold the un-uploaded tail in memory while the batcher fills.
    # On each tick we add freshly-read PTY bytes to the batcher and only
    # drain into `stdout_buffer` if the upload itself failed (so the
    # next tick can retry).
    stdout_buffer: bytearray = field(default_factory=bytearray)
    stdout_batcher: "EventBatcher" = field(default_factory=lambda: EventBatcher())
    # Per-session monotonic counter so `seq` is dense and ordered within
    # a session lifetime. Resets to 0 on every new spawn. After a helper
    # restart a fresh session can collide with stale rows for a deleted
    # session that shared the same id — but the schema doesn't enforce
    # uniqueness on `(session_id, seq)`, and the app pages by the
    # bigserial `id` column (not `seq`), so collisions don't break
    # ordering. The counter still gives the helper a deterministic seq
    # within one session, which is what the index `idx_remote_session_events
    # _session(session_id, seq)` is sized for.
    event_seq: int = 0
    last_status_posted: str = "running"   # 'running' | 'stopped' | 'errored'


class EventBatcher:
    """Coalesce small terminal-output chunks into ≤ 4 KB rows.

    Provider event rows are capped server-side (see migrate_v0.26 row
    CHECK). Reserved for iter 2's tail-streaming UI; iter 1 holds it as
    a no-op buffer so callers can drop their bytes here without
    branching every site.
    """

    def __init__(self, flush_bytes: int = 3500, max_idle_s: float = 0.5) -> None:
        self.flush_bytes = flush_bytes
        self.max_idle_s = max_idle_s
        self._buf: list[str] = []
        self._size: int = 0
        self._first_at: float | None = None

    def add(self, chunk: str) -> str | None:
        if not chunk:
            return None
        self._buf.append(chunk)
        self._size += len(chunk.encode("utf-8", errors="replace"))
        if self._first_at is None:
            self._first_at = time.monotonic()
        if self._size >= self.flush_bytes:
            return self.drain()
        return None

    def due(self) -> bool:
        if self._first_at is None:
            return False
        return (time.monotonic() - self._first_at) >= self.max_idle_s

    def drain(self) -> str | None:
        if not self._buf:
            return None
        joined = "".join(self._buf)
        self._buf.clear()
        self._size = 0
        self._first_at = None
        return joined[:4096]


class RemoteAgentManager:
    """Owns the live PTY-managed sessions for one helper daemon.

    `transport` is injected so the cli-pulse-desktop track can plug in
    `ConPtyTransport` later. The manager itself does not import `pty`,
    `termios`, or `fcntl`.

    Lifecycle:
      * `tick()` is called once per daemon cycle; it polls commands,
        dispatches them, and drains stdout from running children.
      * `shutdown()` is called once on SIGTERM / SIGHUP; it terminates
        every running session and posts a final 'stopped' status event.
    """

    # Tunable: argv[0] for the claude provider. Resolved via PATH at
    # spawn time (POSIX execvp). Override via env so users on uncommon
    # installs can point at e.g. `/Users/me/.claude/local/claude`.
    CLAUDE_ARGV = ["claude"]

    def __init__(
        self,
        helper_config: Any,
        rpc_caller: Callable[..., Any],
        transport: SessionTransport | None = None,
        executor: LocalExecutor | None = None,
    ) -> None:
        self.helper_config = helper_config
        self.rpc_caller = rpc_caller
        if transport is None:
            transport = self._default_transport()
        self.transport = transport
        self._sessions: dict[str, _ManagedSession] = {}
        # Phase 3 Iter 1: when an executor is supplied, every public
        # mutation method submits its work onto it and waits for the
        # result. The daemon poll loop and the local UDS server then
        # share a single writer thread, eliminating races on
        # `_sessions` and the per-session counters. When `executor` is
        # None (existing tests, ad-hoc callers), the methods run
        # inline and behave exactly as they did before.
        self._executor = executor

    @staticmethod
    def _default_transport() -> SessionTransport:
        if sys.platform == "win32":
            raise NotImplementedError(
                "Windows ConPTY transport — implemented in cli-pulse-desktop track"
            )
        # Lazy import so the helper package can still be imported on a
        # Windows host (the desktop track may want to import this module
        # for typing / discovery without instantiating the manager).
        from transports.posix_pty import PosixPtyTransport
        return PosixPtyTransport()

    # ── executor routing ─────────────────────────────────────

    def _dispatch(self, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Any:
        """Route mutation `fn` through the single-writer executor when
        present, else run inline. Public methods call this; internal
        helpers (already on the executor thread when one exists) call
        the `_*_impl` methods directly to avoid recursive submit.
        """
        if self._executor is None:
            return fn(*args, **kwargs)
        return self._executor.submit_and_wait(fn, *args, **kwargs)

    # ── lifecycle ────────────────────────────────────────────

    def spawn_session(self, params: SessionStartParams) -> bool:
        return self._dispatch(self._spawn_session_impl, params)

    def _spawn_session_impl(self, params: SessionStartParams) -> bool:
        """Spawn the provider CLI under the configured transport.

        Returns True on success, False if the spawn failed (transport
        already logged + raised). The caller is responsible for
        completing the queued `start` command appropriately.
        """
        if params.session_id in self._sessions:
            logger.warning(
                "session %s already running — skipping respawn", params.session_id
            )
            return True

        argv = self._argv_for(params.provider)
        if argv is None:
            logger.warning(
                "spawn_session: provider %s is not supported in iter 1",
                params.provider,
            )
            return False

        env = self._build_env(params)
        cwd = params.cwd or None  # POSIX transport interprets None as inherit

        try:
            handle = self.transport.start(
                session_id=params.session_id, argv=argv, env=env, cwd=cwd,
            )
        except TransportError as exc:
            # Status payload MUST be exactly `'errored'` for the SQL
            # gate to transition `remote_sessions.status`. Spawn-failure
            # detail (binary missing, PATH resolution miss, fork
            # exhaustion) lands in a separate redacted `kind='info'`
            # event so the app can surface "Failed to spawn: claude not
            # found" without a status-string regression. See
            # `_post_info` for the redaction posture.
            logger.warning(
                "spawn_session(%s): transport.start raised: %s",
                params.session_id, exc,
            )
            self._post_status(params.session_id, "errored")
            self._post_info(
                params.session_id, f"spawn failed: {exc}"
            )
            return False

        self._sessions[params.session_id] = _ManagedSession(
            params=params, handle=handle, spawned_at=time.monotonic(),
        )
        logger.info(
            "spawn_session(%s): provider=%s cwd=%s",
            params.session_id, params.provider, cwd or "<inherit>",
        )

        # Server-side: register the session row so the app sees status='running'
        # immediately. The row was created with status='pending' by the
        # `remote_app_request_session_start` RPC; this UPSERT bumps it to
        # running. v0.30 ownership check: same (user, device) → safe.
        try:
            self.rpc_caller(
                "remote_helper_register_session",
                {
                    "p_device_id": self.helper_config.device_id,
                    "p_helper_secret": self.helper_config.helper_secret,
                    "p_session_id": params.session_id,
                    "p_provider": params.provider,
                    "p_cwd_basename": (
                        params.cwd.rsplit("/", 1)[-1] if params.cwd else ""
                    )[:255],
                    "p_cwd_hmac": params.cwd_hmac,
                    "p_client_label": params.client_label,
                },
            )
        except Exception as exc:
            # Spawn succeeded; registration is a best-effort UI hint. The
            # session is still usable (commands will keep flowing), but
            # the app may not see status='running' until the next cycle's
            # status event lands.
            logger.warning(
                "register_session(%s) after spawn failed: %s",
                params.session_id, exc,
            )
        return True

    def stop_session(self, session_id: str) -> None:
        return self._dispatch(self._stop_session_impl, session_id)

    def _stop_session_impl(self, session_id: str) -> None:
        """Terminate the child and close transport resources."""
        sess = self._sessions.get(session_id)
        if sess is None:
            return
        try:
            self.transport.terminate(sess.handle)
        finally:
            self.transport.close(sess.handle)
        # Post BEFORE removing the session entry so `_next_seq` still
        # finds the per-session counter; otherwise the lifecycle event
        # would land with seq=0 (the missing-session fallback) instead
        # of the next dense value (Phase 2 P0).
        self._post_status(session_id, "stopped")
        self._sessions.pop(session_id, None)

    def interrupt_session(self, session_id: str) -> None:
        return self._dispatch(self._interrupt_session_impl, session_id)

    def _interrupt_session_impl(self, session_id: str) -> None:
        """Send SIGINT-equivalent to the foreground process group."""
        sess = self._sessions.get(session_id)
        if sess is None:
            return
        self.transport.interrupt(sess.handle)

    def write_to_session(self, session_id: str, payload: str) -> bool:
        return self._dispatch(self._write_to_session_impl, session_id, payload)

    def _write_to_session_impl(self, session_id: str, payload: str) -> bool:
        """Write the user's typed text to the child's stdin and submit
        it. Returns True if the child accepted the bytes, False if the
        child is gone (in which case the caller should mark the command
        failed).

        Submit semantics: Claude Code's TUI is a raw-mode application
        that enables bracketed-paste mode (CSI ?2004h) and treats LF
        ('\\n') as "more text being pasted," not as Enter. Sending
        "hello\\n" causes the chars to render in the input field but
        Claude never submits to its API. The Enter key in raw mode is
        Carriage Return (CR, '\\r'), so we normalize the trailing
        terminator to '\\r' here. This also works for codex's TUI and
        for line-buffered shell modes (the shell's icrnl termios
        setting will map CR back to LF on the way in).
        """
        sess = self._sessions.get(session_id)
        if sess is None:
            logger.warning("write_to_session(%s): no live session — child likely exited", session_id)
            return False
        # Cap mirrors the column CHECK on `remote_session_commands.payload`.
        body = payload[:8192].encode("utf-8", errors="replace")
        # Normalize trailing terminator to CR. Replace a single trailing
        # LF if the caller already added one; do nothing if CR is already
        # there; append CR otherwise.
        if body.endswith(b"\r\n"):
            body = body[:-2] + b"\r"
        elif body.endswith(b"\n"):
            body = body[:-1] + b"\r"
        elif not body.endswith(b"\r"):
            body = body + b"\r"
        logger.info(
            "write_to_session(%s): writing %d bytes (payload chars=%d)",
            session_id, len(body), len(payload),
        )
        written = self.transport.write_stdin(sess.handle, body)
        if written <= 0:
            logger.warning(
                "write_to_session(%s) wrote 0 bytes — child likely exited",
                session_id,
            )
            return False
        logger.info("write_to_session(%s): wrote %d bytes ok", session_id, written)
        return True

    def shutdown(self) -> None:
        return self._dispatch(self._shutdown_impl)

    def _shutdown_impl(self) -> None:
        """Terminate every running session. Idempotent. Safe to call
        from a signal handler — uses no async primitives.
        """
        if not self._sessions:
            return
        logger.info("shutting down %d managed session(s)", len(self._sessions))
        for session_id in list(self._sessions.keys()):
            try:
                self._stop_session_impl(session_id)
            except Exception as exc:
                logger.warning("shutdown(%s) failed: %s", session_id, exc)

    # ── per-cycle ────────────────────────────────────────────

    def tick(self, max_commands: int = 10) -> dict[str, int]:
        return self._dispatch(self._tick_impl, max_commands)

    def _tick_impl(self, max_commands: int = 10) -> dict[str, int]:
        """One daemon cycle. Pulls commands, dispatches, drains stdout,
        observes child exits.

        Returns counters for tests / logging:
          * commands_processed
          * sessions_exited
          * bytes_drained
        """
        processed = self._poll_and_dispatch_commands(max_commands=max_commands)
        drained = self._drain_running_sessions_stdout()
        exited = self._observe_exits()
        return {
            "commands_processed": processed,
            "sessions_exited": exited,
            "bytes_drained": drained,
        }

    def _poll_and_dispatch_commands(self, max_commands: int = 10) -> int:
        try:
            result = self.rpc_caller(
                "remote_helper_pull_commands",
                {
                    "p_device_id": self.helper_config.device_id,
                    "p_helper_secret": self.helper_config.helper_secret,
                    "p_max": max_commands,
                },
            )
        except Exception as exc:
            # Includes the gate-off path: when the user disables Remote
            # Control, _remote_authenticate_helper_gated returns null and
            # the RPC raises "Device not found or unauthorized". We want
            # the daemon to keep running; on next cycle we'll try again,
            # and once the user re-enables, dispatching resumes.
            logger.debug("pull_commands skipped: %s", exc)
            return 0

        if not isinstance(result, list):
            return 0

        if result:
            logger.info("pulled %d command(s) from queue", len(result))
        for cmd in result:
            if not isinstance(cmd, dict):
                continue
            self._dispatch_one(cmd)
        return len(result)

    def _dispatch_one(self, cmd: dict[str, Any]) -> None:
        cmd_id = cmd.get("id")
        kind = cmd.get("kind") or ""
        session_id = cmd.get("session_id") or ""
        payload = cmd.get("payload") or ""
        if not cmd_id:
            return

        # Per-command dispatch observability. Plaintext payload is NOT
        # logged; only its length, so a careless reader of the helper
        # log doesn't see what the user typed. session_id+cmd_id is
        # enough to correlate with remote_session_commands rows.
        logger.info(
            "dispatch kind=%s session=%s cmd=%s payload_chars=%d",
            kind, session_id, cmd_id, len(payload),
        )

        ok: bool
        err: str
        try:
            if kind == "start":
                ok, err = self._handle_start(session_id, payload)
            elif kind == "prompt":
                ok, err = self._handle_prompt(session_id, payload)
            elif kind == "stop":
                self._stop_session_impl(session_id)
                ok, err = True, ""
            elif kind == "interrupt":
                self._interrupt_session_impl(session_id)
                ok, err = True, ""
            else:
                ok, err = False, f"unknown command kind: {kind!r}"
        except Exception as exc:
            logger.warning("dispatch %s/%s crashed: %s", kind, session_id, exc)
            ok, err = False, str(exc)[:200]

        try:
            self.rpc_caller(
                "remote_helper_complete_command",
                {
                    "p_device_id": self.helper_config.device_id,
                    "p_helper_secret": self.helper_config.helper_secret,
                    "p_command_id": cmd_id,
                    "p_status": "delivered" if ok else "failed",
                    "p_error": err or None,
                },
            )
            logger.info(
                "complete_command cmd=%s kind=%s session=%s status=%s%s",
                cmd_id, kind, session_id,
                "delivered" if ok else "failed",
                f" err={err}" if err else "",
            )
        except Exception as exc:
            logger.warning("complete_command(%s) failed: %s", cmd_id, exc)

    def _handle_start(self, session_id: str, payload: str) -> tuple[bool, str]:
        # Validate session_id is a UUID we can use as the env-var binding.
        try:
            uuid.UUID(session_id)
        except (ValueError, AttributeError, TypeError):
            return False, "invalid session_id"

        # Payload was set by the app in `remote_app_request_session_start`
        # as a JSON object with provider + cwd_basename + cwd_hmac +
        # client_label. We deliberately do NOT extract `cwd_basename`
        # here — iter 1 doesn't resolve a basename to a full path
        # (that's a privacy-posture call, see the spawn block below)
        # so the field is metadata-only on the SQL side and unused
        # in the manager.
        cwd_hmac: str | None = None
        client_label: str | None = None
        provider = "claude"
        try:
            obj = json.loads(payload) if payload else {}
            if isinstance(obj, dict):
                provider = str(obj.get("provider") or "claude")
                cwd_hmac_v = obj.get("cwd_hmac")
                cwd_hmac = str(cwd_hmac_v) if cwd_hmac_v else None
                client_label_v = obj.get("client_label")
                client_label = str(client_label_v) if client_label_v else None
        except (json.JSONDecodeError, TypeError, ValueError):
            return False, "invalid start payload"

        if provider != "claude":
            return False, f"provider {provider!r} not supported in iter 1"

        # iter 1: spawn at $HOME (or PWD if HOME is unset). cwd_basename
        # is metadata-only — we don't try to resolve it to a full path
        # because that would require the helper to know about the user's
        # project layout, which is outside Phase 1's privacy posture.
        params = SessionStartParams(
            session_id=session_id,
            provider=provider,
            cwd="",
            cwd_hmac=cwd_hmac,
            client_label=client_label,
        )
        ok = self._spawn_session_impl(params)
        return ok, "" if ok else "spawn failed"

    def _handle_prompt(self, session_id: str, payload: str) -> tuple[bool, str]:
        if not session_id:
            return False, "prompt requires session_id"
        if session_id not in self._sessions:
            return False, "session not running on this helper"
        ok = self._write_to_session_impl(session_id, payload)
        return ok, "" if ok else "child exited"

    # ── stdout drain + exit observation (iter 1: no upload) ────

    def _drain_running_sessions_stdout(self) -> int:
        """Read pending stdout from each running session, feed it into
        the per-session `EventBatcher`, and post any payload the
        batcher hands back as a `kind='stdout'` event (redacted, capped
        at `_EVENT_PAYLOAD_CAP_CHARS`).

        The PTY merges stdout/stderr by design (same slave fd in
        `PosixPtyTransport.start`), so a single `kind='stdout'`
        carries both. Splitting stderr is iter-3 work and would
        require abandoning the merged PTY for some streams.

        Failure mode: if the upload fails we drop the chunk on the
        floor. We deliberately do NOT re-buffer un-redacted bytes
        locally for retry — events are 7-day retention by design and
        re-stashing into `stdout_buffer` would amplify a long upload
        outage into unbounded memory growth.

        Returns total bytes drained from PTYs this tick (for logging
        / tests, not load shedding).
        """
        total = 0
        for session_id, sess in list(self._sessions.items()):
            try:
                chunk = self.transport.read_stdout(sess.handle, max_bytes=4096)
            except TransportError as exc:
                logger.warning("read_stdout(%s) failed: %s", session_id, exc)
                continue
            if chunk:
                # Decode tolerantly — a multi-byte UTF-8 character may
                # straddle the 4 KB read boundary; `errors="replace"`
                # picks the next chunk back up cleanly.
                text = chunk.decode("utf-8", errors="replace")
                total += len(chunk)
                payload = sess.stdout_batcher.add(text)
                if payload is not None:
                    self._post_stdout_chunk(session_id, payload)

            # Even when we didn't read anything this tick, an idle
            # batcher may have stale bytes from the prior tick that
            # are now past `max_idle_s`. Flush proactively so
            # interactive output (a few words at a time) doesn't sit
            # half a second behind the user's expectations.
            if sess.stdout_batcher.due():
                payload = sess.stdout_batcher.drain()
                if payload is not None:
                    self._post_stdout_chunk(session_id, payload)
        return total

    def _observe_exits(self) -> int:
        exited = 0
        for session_id, sess in list(self._sessions.items()):
            if self.transport.is_alive(sess.handle):
                continue
            # Final stdout drain: the child may have written one last
            # batch on its way out (e.g. an error message before exit).
            # Force-flush whatever's still in the batcher BEFORE we
            # post the exit info, so the event ordering reads
            # naturally (last lines of output → exit code → status).
            self._flush_session_batcher(session_id, sess)

            code = self.transport.wait(sess.handle, timeout=0)
            self.transport.close(sess.handle)
            if code == 0:
                self._post_status(session_id, "stopped")
            else:
                # Status payload MUST be exactly `'errored'` for the SQL
                # gate. Exit code lands in a redacted info event so the
                # UI can render "exited code=2" without us hard-coding
                # the format into the status payload.
                code_label = (
                    f"exit_code={code}" if code is not None else "child gone"
                )
                logger.info(
                    "session %s exited with %s", session_id, code_label,
                )
                self._post_status(session_id, "errored")
                self._post_info(session_id, f"exited: {code_label}")
            self._sessions.pop(session_id, None)
            exited += 1
        return exited

    def _flush_session_batcher(
        self, session_id: str, sess: "_ManagedSession"
    ) -> None:
        """Force-drain a session's batcher and post the result. Used on
        exit observation so the last few lines of output reach the app
        before the lifecycle event lands.
        """
        chunk = sess.stdout_batcher.drain()
        if chunk:
            self._post_stdout_chunk(session_id, chunk)

    # ── local UDS entry points (Phase 3 Iter 1) ──────────────

    def local_start_claude_session(self, payload: dict[str, Any]) -> dict[str, Any]:
        """Start a new managed Claude session on behalf of the local
        macOS app. The UDS server submits this through the executor
        (so this body always runs on the writer thread); we generate
        the session id here, spawn the PTY, and return the id back
        for the client to track.

        Note: we do NOT round-trip through Supabase to "create the
        pending row" first, because that's the latency the local
        path exists to avoid. `_spawn_session_impl` still calls
        `remote_helper_register_session` (best-effort) so iOS / Watch
        viewers see the session row appear via existing remote_app
        list paths within the next sync cycle. If the helper is
        offline, the session still works locally; the row simply
        doesn't propagate.
        """
        return self._dispatch(self._local_start_claude_session_impl, payload)

    def _local_start_claude_session_impl(
        self, payload: dict[str, Any]
    ) -> dict[str, Any]:
        session_id = str(uuid.uuid4())
        client_label = payload.get("client_label")
        cwd_hmac = payload.get("cwd_hmac")
        params = SessionStartParams(
            session_id=session_id,
            provider="claude",
            cwd="",
            cwd_hmac=cwd_hmac if isinstance(cwd_hmac, str) else None,
            client_label=client_label if isinstance(client_label, str) else None,
        )
        ok = self._spawn_session_impl(params)
        return {
            "session_id": session_id,
            "ok": ok,
        }

    def local_list_sessions(self) -> list[dict[str, Any]]:
        """Snapshot of every live session this helper currently owns.

        This is the local fast path's analogue of `remote_app_list_sessions`,
        but scoped to *this* helper's in-memory state. Cross-device
        viewers (iOS / Watch) still rely on the Supabase-backed list.

        Each row carries the bare minimum the UI needs to render the
        session list: id, provider, client_label, spawn time,
        last_status_posted. No transcript, no environment, no PID.
        """
        return self._dispatch(self._local_list_sessions_impl)

    def _local_list_sessions_impl(self) -> list[dict[str, Any]]:
        rows: list[dict[str, Any]] = []
        for sid, sess in self._sessions.items():
            rows.append({
                "session_id": sid,
                "provider": sess.params.provider,
                "client_label": sess.params.client_label,
                "spawned_at_monotonic": sess.spawned_at,
                "status": sess.last_status_posted,
            })
        return rows

    def local_stop_session(self, session_id: str) -> dict[str, Any]:
        """Stop a managed session by id. Symmetric with
        `_handle_stop` on the Supabase path (both end up calling
        `_stop_session_impl`).
        """
        return self._dispatch(self._local_stop_session_impl, session_id)

    def _local_stop_session_impl(self, session_id: str) -> dict[str, Any]:
        present = session_id in self._sessions
        if present:
            self._stop_session_impl(session_id)
        return {"session_id": session_id, "stopped": present}

    def local_send_input(self, session_id: str, payload: str) -> dict[str, Any]:
        """Write `payload` to the stdin of a helper-owned managed
        session. Reuses the SAME `_write_to_session_impl` path the
        Supabase RPC went through in PR #10, so the existing CR /
        newline submit semantics (covered by
        `helper/test_remote_agent_submit.py`) are preserved without
        modification — that's the design contract.

        Returns:
            {"session_id": id, "written": bool}

        `written: False` means the helper does not own this session
        (id not in `_sessions`). The UDS server maps that to the
        wire-level `not_controllable` / `session_not_found` taxonomy
        based on whether the id is in the detected set.
        """
        return self._dispatch(self._local_send_input_impl, session_id, payload)

    def _local_send_input_impl(self, session_id: str, payload: str) -> dict[str, Any]:
        if session_id not in self._sessions:
            return {"session_id": session_id, "written": False}
        ok = self._write_to_session_impl(session_id, payload)
        return {"session_id": session_id, "written": ok}

    # ── helpers ──────────────────────────────────────────────

    def _argv_for(self, provider: str) -> list[str] | None:
        """Resolve argv for a provider. iter 1: claude only."""
        if provider == "claude":
            return list(self.CLAUDE_ARGV)
        return None

    def _build_env(self, params: SessionStartParams) -> dict[str, str]:
        """Build the subset of env vars the manager controls. Posix
        transport merges this with `os.environ` so PATH / TERM survive.
        """
        env: dict[str, str] = {}
        env.update(params.extra_env or {})
        # Critical binding: `remote_hook.py` prefers this over Claude's
        # raw hook session_id when creating permission requests, so an
        # inline approve from the Sessions UI lands on the row matching
        # this managed session. After UUID validation only.
        env["CLI_PULSE_REMOTE_SESSION_ID"] = params.session_id
        return env

    # ── event posting (iter 2: stdout + info + status) ─────────

    def _next_seq(self, session_id: str) -> int:
        """Per-session monotonic event seq. Falls back to `0` for
        events posted outside a session's lifetime (e.g. a spawn
        failure that never registered the session). The app pages by
        the bigserial `id` column, not `seq`, so the fallback value
        doesn't break ordering — `seq` here is purely a hint that
        helps SQL `idx_remote_session_events_session(session_id, seq)`
        scans on the helper-write side.
        """
        sess = self._sessions.get(session_id)
        if sess is None:
            return 0
        sess.event_seq += 1
        return sess.event_seq

    def _post_event(
        self, session_id: str, kind: str, payload: str
    ) -> bool:
        """Generic event poster. Returns True on success, False on RPC
        failure. Caller is responsible for redaction so a leak can't
        slip through by forgetting an inner wrap.

        Failure is non-fatal: we log at DEBUG (the gate-off path is
        the most common reason and we don't want to spam WARN every
        cycle a user has Remote Control disabled) and return False so
        the caller can decide whether to retain the data for retry.
        """
        try:
            self.rpc_caller(
                "remote_helper_post_event",
                {
                    "p_device_id": self.helper_config.device_id,
                    "p_helper_secret": self.helper_config.helper_secret,
                    "p_session_id": session_id,
                    "p_seq": self._next_seq(session_id),
                    "p_kind": kind,
                    "p_payload": payload[:_EVENT_PAYLOAD_CAP_CHARS],
                },
            )
            return True
        except Exception as exc:
            logger.debug(
                "post_event(%s, %s) failed: %s", session_id, kind, exc
            )
            return False

    def _post_status(self, session_id: str, status: str) -> None:
        """Post a lifecycle status event so the SQL gate transitions
        `remote_sessions.status`.

        **Payload MUST be exactly `'stopped'` or `'errored'`.** The gate
        in `remote_helper_post_event` only updates the row's status
        column on `p_kind='status'` AND `p_payload IN ('stopped',
        'errored')`. An earlier draft prefixed an `f"{status}: {detail}"`
        string, which silently kept errored sessions stuck on
        `pending`/`running` server-side. Lifecycle context goes via
        `_post_info` (separate `kind='info'` event with redaction).
        """
        if status not in ("stopped", "errored"):
            # Defensive: refuse to send anything that wouldn't trip the
            # SQL gate. Surfacing the typo as a noisy log is much
            # better than a silently stuck row.
            logger.warning(
                "post_status(%s) refused unknown status %r",
                session_id, status,
            )
            return
        self._post_event(session_id, "status", status)

    def _post_info(self, session_id: str, detail: str) -> bool:
        """Post a redacted, length-bounded `kind='info'` event with
        lifecycle context (spawn-failure reason, exit code, "child
        gone" hint, etc.) that complements but does NOT replace the
        bare-string `kind='status'` event the SQL gate keys on.

        Returns False (no-op) when `detail` is empty so callers can
        unconditionally invoke without a guard. RPC failures are
        non-fatal — the local process keeps running.
        """
        if not detail:
            return False
        redacted = redact(detail)
        if not redacted:
            return False
        return self._post_event(
            session_id, "info", redacted[:_INFO_PAYLOAD_CAP_CHARS]
        )

    def _post_stdout_chunk(self, session_id: str, text: str) -> bool:
        """Redact + post a tail of merged stdout/stderr for a managed
        session. PTY merges the streams (`stdout=stderr=slave_fd` in
        `PosixPtyTransport.start`) so iter 2 emits `kind='stdout'` for
        the combined stream — separating stderr would require a
        non-PTY pipe and is iter-3 work.

        Returns False on RPC failure or if `text` is empty after
        redaction; caller can re-stash the original (un-redacted) bytes
        on the per-session `stdout_buffer` if it wants to retry next
        tick. iter 2 chooses NOT to retry on failure: events are
        ephemeral by retention design (7-day cron prune) and re-stashing
        un-redacted bytes risks DoS-amplifying a long upload outage
        into unbounded memory growth.
        """
        if not text:
            return False
        redacted = redact(text)
        if not redacted:
            return False
        return self._post_event(
            session_id, "stdout", redacted[:_EVENT_PAYLOAD_CAP_CHARS]
        )
