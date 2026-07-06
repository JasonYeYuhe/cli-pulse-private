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
import os
import sys
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

from local_approvals import ApprovalRegistry
from local_events import EventBroker
from local_executor import LocalExecutor
from ansi_sanitizer import strip as _ansi_strip
from provider_spawners import augmented_path
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

# v-next P1-2: per-session bounded ring of recent RAW (un-stripped,
# redacted) output, returned by `get_tail_snapshot` so a terminal opened
# (or re-opened) mid-session repaints current screen state. 64 KB is
# enough for a full screenful of TUI chrome + scrollback the renderer
# replays into xterm.js.
_RAW_RING_CAP_BYTES = 64 * 1024


def _env_float(name: str, default: float) -> float:
    try:
        return float(os.environ.get(name) or default)
    except (TypeError, ValueError):
        return float(default)


def _sanitize_path_in(text: str, path: str | None) -> str:
    """Replace occurrences of the absolute `path` in `text` with its
    basename, so a working-directory path can't leak through a spawn-error
    string into logs or cloud events (v-next P1-1, codex review). No-op when
    `path` is falsy."""
    if not path:
        return text
    return text.replace(path, os.path.basename(path.rstrip("/")) or "<cwd>")


# v-next P1-6: managed-session lifetime caps (monotonic seconds). A
# forgotten / orphaned session keeps its CLI authenticated and able to
# spend API quota indefinitely — the tick reaper bounds that. Idle =
# no stdin/stdout activity; max-age is a hard backstop (also ≈ the
# injected OAuth token's lifetime, after which the session can't re-auth
# anyway). Both overridable via env for ops.
_SESSION_IDLE_TIMEOUT_S = _env_float("HELPER_SESSION_IDLE_TIMEOUT_S", 30 * 60)
_SESSION_MAX_AGE_S = _env_float("HELPER_SESSION_MAX_AGE_S", 8 * 60 * 60)

# Server-side row CHECK is `length(payload) <= 4096`. Keep the helper's
# per-event cap a hair under so a UTF-8 boundary fix (see
# `_safe_truncate_utf8`) can't push a payload over.
_EVENT_PAYLOAD_CAP_CHARS = 4000

# `kind='info'` carries lifecycle detail (spawn-failure reason, exit
# code, "child gone" hint). We bound it harder than stdout because info
# rows are inherently short — anything longer has likely sucked in a
# stack trace we'd rather elide.
_INFO_PAYLOAD_CAP_CHARS = 1024


def _known_provider_names() -> list[str]:
    """v1.15: list every provider the spawner registry knows about.

    Used in error messages when the manager rejects an unknown provider
    so the operator log shows what's available. Falls back to the
    legacy single-provider list when the spawner package isn't
    importable.
    """
    try:
        from provider_spawners import all_provider_names
        return all_provider_names()
    except ImportError:
        return ["claude"]


class _LegacyArgvParamsShim:
    """Minimal stand-in passed to `ProviderSpawner.argv()` from the
    backward-compat `_argv_for(provider)` helper. Concrete spawners
    only read `params.extra_env`, which is empty here.
    """

    extra_env: dict[str, str] = {}


@dataclass
class SessionStartParams:
    """Inputs for `RemoteAgentManager.spawn_session`. All snake_case."""

    session_id: str
    provider: str                              # 'claude' | 'codex' | 'gemini'
    cwd: str = ""                              # Helper-resolvable path; '' → CWD
    cwd_hmac: str | None = None
    client_label: str | None = None
    extra_env: dict[str, str] = field(default_factory=dict)
    # R0 (S3/S5): the session's `realtime_private` from the cloud start payload
    # (migrate_v0.61). `True` → mirror to the PRIVATE `pterm:` topic; `False`
    # (public) or `None` (UNKNOWN — pre-v0.61 payload / local session) → do NOT
    # broadcast and do NOT mint (the local gate that keeps a fleet-wide
    # default-ON producer from hammering mint-realtime-token with 403s — Gemini #2).
    realtime_private: bool | None = None


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
    # v-next P1-2: bounded ring of recent RAW redacted output for
    # `get_tail_snapshot` (reattach repaint). Appended on the executor
    # thread in `_post_stdout_chunk` → no lock needed.
    raw_ring: bytearray = field(default_factory=bytearray)
    # v-next P1-6: monotonic timestamp of the last stdout/stdin activity,
    # for the idle-session reaper. Initialized to spawn time.
    last_activity_at: float = 0.0


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
        event_broker: EventBroker | None = None,
        approval_registry: ApprovalRegistry | None = None,
        local_helper_socket_path: str | None = None,
        claude_token_resolver: Callable[[], str | None] | None = None,
        broadcast_publisher: Any = None,
    ) -> None:
        self.helper_config = helper_config
        self.rpc_caller = rpc_caller
        # R0 (B2): optional terminal-broadcast producer
        # (realtime_broadcast.TerminalBroadcastPublisher). When None (the
        # default, and the shipped state — the
        # `remote_realtime_broadcast_enabled` gate is off), the helper behaves
        # exactly as today: stdout goes to the DB-event path only, NOTHING is
        # broadcast. When wired, redacted raw bytes are ALSO submitted to the
        # publisher, which streams private sessions to `pterm:<id>`.
        self._broadcast_publisher = broadcast_publisher
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
        # Phase 3 Iter 2B: optional broker / registry for the local
        # streaming + approval surface. Both default to None so
        # existing tests construct managers without ceremony; when
        # supplied, the manager publishes session lifecycle + PTY
        # output to the broker and registers per-session capability
        # tokens for hook-driven approvals.
        self._event_broker = event_broker
        self._approval_registry = approval_registry
        self._local_helper_socket_path = local_helper_socket_path
        # v-next P0-A: resolves a FRESH claude OAuth access token at spawn
        # time (read file-first creds → refresh if expired → persist). When
        # None (default — existing tests, unpaired callers), claude auth
        # injection is DISABLED and the spawn behaves exactly as before; the
        # production daemon wires this to
        # `claude_oauth.resolve_fresh_claude_access_token`. Injected (not
        # imported) so tests stay hermetic — a test never touches real creds
        # or the network unless it opts in with its own resolver.
        self._claude_token_resolver = claude_token_resolver

    @staticmethod
    def _default_transport() -> SessionTransport:
        if sys.platform == "win32":
            raise NotImplementedError(
                "Windows ConPTY transport — implemented in cli-pulse-desktop track"
            )
        # Lazy import so the helper package can still be imported on a
        # Windows host (the desktop track may want to import this module
        # for typing / discovery without instantiating the manager).
        # v1.17: wrap PosixPty + CodexExec in a multiplex so Codex
        # sessions bypass the ratatui TUI entirely (see
        # transports/codex_exec.py docstring for the full story).
        # v-next P0-B: the former GeminiExecTransport is deleted — the
        # gemini provider spawns `agy`, which routes to the PTY path like
        # claude. Only PosixPty + CodexExec remain.
        from transports.posix_pty import PosixPtyTransport
        from transports.codex_exec import CodexExecTransport
        from transports.multiplex import MultiplexTransport
        return MultiplexTransport(
            pty_transport=PosixPtyTransport(),
            codex_exec_transport=CodexExecTransport(),
        )

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

        # v1.15: per-provider spawner registry. Returns None for unknown
        # providers (legacy `_argv_for` only knew `claude`); the
        # registry is a superset that lets us add Codex/Gemini without
        # touching this method again.
        spawner = self._spawner_for(params.provider)
        if spawner is None:
            logger.warning(
                "spawn_session: provider %s has no registered spawner "
                "(known: %s)",
                params.provider,
                ", ".join(_known_provider_names()),
            )
            return False
        argv = spawner.argv(params)

        # Phase 3 Iter 2B: register the session in the approval registry
        # BEFORE spawn so the env we pass to the child carries a valid
        # capability token. PID is unknown at this point — we update it
        # below once Popen returns.
        capability_token: str | None = None
        if self._approval_registry is not None:
            try:
                capability_token = self._approval_registry.register_session(
                    params.session_id, claude_pid=None,
                )
            except Exception as exc:  # noqa: BLE001 — registry is best-effort
                logger.warning(
                    "approval registry register_session(%s) failed: %s",
                    params.session_id, exc,
                )
                capability_token = None

        env = self._build_env(params, capability_token=capability_token)
        # v1.35: apply the spawner's provider-specific env overrides. This
        # was never wired before — `env_overrides` existed but nothing
        # merged it — so Codex's CODEX_HOME pin (and RUST_BACKTRACE) reach
        # the child only via this line. `env_removals` returns keys the
        # transport DELETES after the parent-env merge (Codex's on-plan
        # OPENAI_API_KEY scrub). Mirrors the Swift manager's envPatch glue.
        # Fail-soft via getattr so the ultra-old legacy claude fallback
        # spawner (no env_removals) still spawns.
        try:
            env.update(spawner.env_overrides(params) or {})
        except Exception as exc:  # noqa: BLE001 — overrides must not break spawn
            logger.warning("env_overrides(%s) failed: %s", params.provider, exc)
        try:
            env_remove = frozenset(
                getattr(spawner, "env_removals", lambda _p: set())(params) or ()
            )
        except Exception as exc:  # noqa: BLE001 — removals must not break spawn
            logger.warning("env_removals(%s) failed: %s", params.provider, exc)
            env_remove = frozenset()
        cwd = params.cwd or None  # POSIX transport interprets None as inherit

        # v-next P0-A: resolve + inject a fresh provider auth token. For
        # claude this hands the child a current OAuth token over an
        # inherited fd (leak-safe). `auth_fd` is closed in the `finally`
        # below once the child owns its own inherited copy.
        auth_fd, env = self._inject_provider_auth(params, env)
        try:
            start_kwargs: dict[str, Any] = dict(
                session_id=params.session_id, argv=argv, env=env, cwd=cwd,
            )
            if auth_fd is not None:
                start_kwargs["pass_fds"] = (auth_fd,)
            if env_remove:
                start_kwargs["env_remove"] = env_remove
            handle = self.transport.start(**start_kwargs)
        except TransportError as exc:
            # Status payload MUST be exactly `'errored'` for the SQL
            # gate to transition `remote_sessions.status`. Spawn-failure
            # detail (binary missing, PATH resolution miss, fork
            # exhaustion) lands in a separate redacted `kind='info'`
            # event so the app can surface "Failed to spawn: claude not
            # found" without a status-string regression. See
            # `_post_info` for the redaction posture.
            # v-next P1-1 (codex review): a bad cwd makes Popen raise an
            # error whose string embeds the ABSOLUTE path — sanitize it to
            # the basename before it reaches logs OR the cloud `info` event.
            detail = _sanitize_path_in(str(exc), cwd)
            logger.warning(
                "spawn_session(%s): transport.start raised: %s",
                params.session_id, detail,
            )
            # Drop the registry slot so a stale capability token doesn't
            # outlive the failed spawn — there's no PTY to defend now.
            if self._approval_registry is not None:
                try:
                    self._approval_registry.unregister_session(params.session_id)
                except Exception:
                    pass
            self._post_status(params.session_id, "errored")
            self._post_info(
                params.session_id, f"spawn failed: {detail}"
            )
            return False
        finally:
            # The child (if it launched) inherited its own copy of the
            # auth read-end; close ours so the fd doesn't leak in the
            # daemon. Runs on both the success and spawn-failure paths.
            if auth_fd is not None:
                try:
                    os.close(auth_fd)
                except OSError:
                    pass

        _spawn_mono = time.monotonic()
        self._sessions[params.session_id] = _ManagedSession(
            params=params, handle=handle, spawned_at=_spawn_mono,
            last_activity_at=_spawn_mono,
        )
        # Update the registry's recorded Claude PID so descent
        # verification on hook ingress can compare against it.
        if self._approval_registry is not None:
            child_pid = self._extract_pid(handle)
            if child_pid is not None and child_pid > 0:
                try:
                    self._approval_registry.update_session_pid(
                        params.session_id, child_pid,
                    )
                except Exception as exc:  # noqa: BLE001
                    logger.warning(
                        "approval registry update_session_pid(%s) failed: %s",
                        params.session_id, exc,
                    )
        # Publish session_started so any subscriber (e.g. the macOS
        # row that already had a stream open) gets the lifecycle
        # event without a separate poll. Best-effort.
        if self._event_broker is not None:
            try:
                self._event_broker.publish({
                    "event": "session_started",
                    "session_id": params.session_id,
                    "provider": params.provider,
                    "client_label": params.client_label,
                })
            except Exception as exc:  # noqa: BLE001
                logger.debug("broker session_started publish failed: %s", exc)
        # v-next P1-1: log only the cwd BASENAME, never the full absolute
        # path (it can contain a user/project name — keep logs privacy-safe).
        _cwd_log = os.path.basename(cwd.rstrip("/")) if cwd else "<inherit>"
        logger.info(
            "spawn_session(%s): provider=%s cwd=%s",
            params.session_id, params.provider, _cwd_log,
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
        # Cancel any pending approvals + drop capability token so a
        # rogue late hook can't ride a stopped session's id.
        if self._approval_registry is not None:
            try:
                self._approval_registry.unregister_session(session_id)
            except Exception as exc:  # noqa: BLE001
                logger.warning("registry unregister(%s) failed: %s", session_id, exc)
        if self._event_broker is not None:
            try:
                self._event_broker.publish({
                    "event": "session_stopped",
                    "session_id": session_id,
                })
            except Exception as exc:  # noqa: BLE001
                logger.debug("broker session_stopped publish failed: %s", exc)
        # R0 (B2): flush any coalesced chunks for this session so the final
        # output (e.g. the last line before the prompt returns) isn't lost to
        # the coalescing window on teardown. No-op when the producer is absent.
        if self._broadcast_publisher is not None:
            try:
                self._broadcast_publisher.flush(session_id)
                # Purge per-session token/denial/retry state AFTER the final
                # flush so the long-lived daemon's dicts stay bounded.
                forget = getattr(self._broadcast_publisher, "forget", None)
                if callable(forget):
                    forget(session_id)
            except Exception as exc:  # noqa: BLE001
                logger.debug("broadcast flush(%s) failed: %s", session_id, exc)
        self._sessions.pop(session_id, None)

    def interrupt_session(self, session_id: str) -> None:
        return self._dispatch(self._interrupt_session_impl, session_id)

    def _interrupt_session_impl(self, session_id: str) -> None:
        """Send SIGINT-equivalent to the foreground process group."""
        sess = self._sessions.get(session_id)
        if sess is None:
            return
        self.transport.interrupt(sess.handle)
        sess.last_activity_at = time.monotonic()  # P1-6: user activity

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
        sess.last_activity_at = time.monotonic()  # P1-6 idle reaper
        return True

    # ── v1.30.x in-app terminal: raw keystroke + window resize ──────────
    # These power the xterm.js terminal (DEVID). All dispatched through the
    # single-writer executor (like every other mutation), so the per-session
    # state stays serialized with the tick/drain — no extra lock.

    # Cap on a single raw-input frame (paste/keystroke). Generous for paste,
    # bounded so a buggy/malicious local client can't OOM the helper.
    _MAX_RAW_INPUT_BYTES = 1024 * 1024  # 1 MB

    def send_input_raw(self, session_id: str, payload_base64: str) -> bool:
        return self._dispatch(self._send_input_raw_impl, session_id, payload_base64)

    def _send_input_raw_impl(self, session_id: str, payload_base64: str) -> bool:
        """Write raw bytes to the child's stdin VERBATIM — no CR/LF mangling
        (unlike write_to_session, which CR-terminates prompts). For the
        xterm.js terminal, where each keystroke / control byte (0x03 Ctrl-C,
        arrow ESC sequences, paste) must reach the PTY untouched."""
        sess = self._sessions.get(session_id)
        if sess is None:
            logger.warning("send_input_raw(%s): no live session", session_id)
            return False
        import base64
        try:
            raw = base64.b64decode(payload_base64, validate=True)
        except Exception as exc:  # noqa: BLE001
            logger.warning("send_input_raw(%s): bad base64: %s", session_id, exc)
            return False
        if len(raw) > self._MAX_RAW_INPUT_BYTES:
            logger.warning("send_input_raw(%s): payload %d bytes exceeds cap — rejected",
                           session_id, len(raw))
            return False
        if not raw:
            return True
        written = self.transport.write_stdin(sess.handle, raw)
        if written > 0:
            sess.last_activity_at = time.monotonic()  # P1-6 idle reaper
        return written > 0

    def resize_session(self, session_id: str, rows: int, cols: int) -> bool:
        return self._dispatch(self._resize_session_impl, session_id, rows, cols)

    def _resize_session_impl(self, session_id: str, rows: int, cols: int) -> bool:
        """Forward an xterm.js window-size change to the PTY (SIGWINCH)."""
        sess = self._sessions.get(session_id)
        if sess is None:
            return False
        self.transport.resize(sess.handle, rows, cols)
        sess.last_activity_at = time.monotonic()  # P1-6: user presence
        return True

    def local_get_tail_snapshot(
        self, session_id: str, max_bytes: int = 8192
    ) -> dict[str, Any] | None:
        return self._dispatch(self._local_get_tail_snapshot_impl, session_id, max_bytes)

    def _tail_snapshot_bytes(
        self, session_id: str, max_bytes: int
    ) -> bytes | None:
        """Raw REDACTED tail of the per-session ring — shared by the local UDS
        snapshot and the R0 cloud `tail_snapshot` broadcast. Returns None for an
        unknown session. Re-redacts the ASSEMBLED tail (review M3: a secret
        straddling a chunk boundary could survive the per-chunk write-time
        redact — cheap here since snapshots are infrequent). Marks the (re)attach
        as presence so an attached-but-quiet session outlives the idle reaper
        (P1-6). Must be called on the single-writer executor thread (reads
        `raw_ring`, written by `_post_stdout_chunk` on the same thread)."""
        sess = self._sessions.get(session_id)
        if sess is None:
            return None
        sess.last_activity_at = time.monotonic()
        try:
            n = int(max_bytes)
        except (TypeError, ValueError):
            n = 8192
        n = max(1, min(n, _RAW_RING_CAP_BYTES))
        tail = bytes(sess.raw_ring[-n:])
        return redact(tail.decode("utf-8", "replace")).encode("utf-8", "replace")

    def _local_get_tail_snapshot_impl(
        self, session_id: str, max_bytes: int
    ) -> dict[str, Any] | None:
        """v-next P1-2: return the tail of the per-session RAW redacted
        output ring (base64) so a terminal opened/re-opened mid-session
        repaints current screen state. Returns None for an unknown session
        so the UDS layer can map it to `session_not_found`. The tail may
        begin mid-escape-sequence; xterm.js drops an incomplete leading
        sequence, and the app can request the full 64 KB for a clean
        repaint."""
        tail = self._tail_snapshot_bytes(session_id, max_bytes)
        if tail is None:
            return None
        import base64
        return {"bytes_base64": base64.b64encode(tail).decode("ascii")}

    def _handle_tail_snapshot(
        self, session_id: str, payload: str
    ) -> tuple[bool, str]:
        """R0 (S3): cloud `tail_snapshot` command — the iOS/Android warm-resume
        path (the client waits ~2 s for a `tail_snapshot_result` broadcast on
        resubscribe). Broadcasts the RAW-redacted ring tail on the PRIVATE
        `pterm:` topic via the SAME publisher + event allowlist the stdout
        stream uses. Gated exactly like the stdout stream: only a PRIVATE session
        broadcasts (Gemini #2 local gate). For a public/unknown session, or when
        no producer is wired, it's a no-op SUCCESS — the client just falls back
        to its 2 s timeout drain (not an error). Runs on the dispatcher (= the
        single-writer executor) thread, so reading the ring is race-free."""
        if session_id not in self._sessions:
            return False, "session not running on this helper"
        sess = self._sessions.get(session_id)
        if sess is None:
            return False, "session not running on this helper"
        if (
            self._broadcast_publisher is None
            or sess.params.realtime_private is not True
        ):
            return True, ""   # nothing to broadcast — not an error
        try:
            max_bytes = int(payload) if payload and payload.strip() else 8192
        except (TypeError, ValueError):
            max_bytes = 8192
        tail = self._tail_snapshot_bytes(session_id, max_bytes)
        if tail:
            try:
                self._broadcast_publisher.submit(
                    session_id, "tail_snapshot_result", tail
                )
            except Exception as exc:  # noqa: BLE001
                logger.debug("tail_snapshot broadcast failed: %s", exc)
        return True, ""

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
        local = self._tick_local_impl()
        # v-next review (H1): the reaper terminates LIVE children, and
        # transport.close() can block up to ~4 s (SIGTERM→grace→SIGKILL) on
        # the single-writer executor. Run it ONLY on the 1 Hz full tick (where
        # network I/O is already expected), NOT on the 5 Hz `tick_local`, so a
        # reap can't stall concurrent keystrokes / start / stop for seconds.
        reaped = self._reap_overlong_sessions()
        local["commands_processed"] = processed
        local["sessions_reaped"] = reaped
        return local

    def tick_local(self) -> dict[str, int]:
        return self._dispatch(self._tick_local_impl)

    def _tick_local_impl(self) -> dict[str, int]:
        """v-next P1-5: the FAST half of a tick — local PTY drain + child-exit
        observation only, WITHOUT the Supabase command poll OR the (blocking)
        idle reaper. The daemon calls this on the sub-second active-session
        cadence and the full `tick()` (which adds the remote poll + reaper) at
        ~1 Hz. Both operations here are non-blocking: the drain is a
        non-blocking read, and `_observe_exits` only closes ALREADY-dead
        children (close() short-circuits when `proc.poll()` is not None)."""
        drained = self._drain_running_sessions_stdout()
        exited = self._observe_exits()
        return {
            "commands_processed": 0,
            "sessions_exited": exited,
            "bytes_drained": drained,
            "sessions_reaped": 0,
        }

    def has_active_sessions(self) -> bool:
        """True when ≥1 managed session is live. Read WITHOUT the executor —
        the daemon loop calls this every cycle only to pick its sleep
        cadence (P1-5), so a benign stale read just shifts the cadence by
        one tick. CPython dict truthiness is a single atomic read."""
        return bool(self._sessions)

    def managed_child_pids(self) -> set[int]:
        """Best-effort set of live child pids for currently-managed sessions
        (v1.38.1). The Machine tab's suspend guard consults this so a user
        can't freeze a managed session they're driving from the app.

        Read WITHOUT the executor (a benign stale read at most misses a
        just-spawned/just-reaped pid — the guard is belt-and-suspenders, and
        the real IPC-deadlock hazard is already bounded by per-session PTY read
        threads). NOTE: this returns the helper's DIRECT child pid per session;
        a grandchild (e.g. `claude` under a shell wrapper) is not covered, so
        this is defense-in-depth, not a hard guarantee. Never raises."""
        pids: set[int] = set()
        for sess in list(self._sessions.values()):
            try:
                pid = self._extract_pid(sess.handle)
            except Exception:  # noqa: BLE001 — one bad handle must not break the set
                pid = None
            if isinstance(pid, int) and pid > 0:
                pids.add(pid)
        return pids

    def stop_all_sessions(self, reason: str = "control_disabled") -> int:
        return self._dispatch(self._stop_all_sessions_impl, reason)

    def _stop_all_sessions_impl(self, reason: str) -> int:
        """v-next P1-6: stop EVERY managed session immediately (e.g. local
        control toggled OFF) so API spend / orphan PTYs are bounded right
        away instead of waiting for the idle/max-age reaper. Returns the
        count stopped. Unlike `shutdown`, the manager stays usable."""
        if not self._sessions:
            return 0
        n = len(self._sessions)
        logger.info("stopping all %d managed session(s) (%s)", n, reason)
        for sid in list(self._sessions.keys()):
            try:
                # review L3: post the "stopped" info AFTER the stop succeeds —
                # otherwise a stop-failure leaves a premature "stopped" event
                # in the cloud log while the session keeps running.
                self._stop_session_impl(sid)
                self._post_info(sid, f"session stopped ({reason})")
            except Exception as exc:  # noqa: BLE001 — best-effort teardown
                logger.warning("stop_all_sessions(%s) failed: %s", sid, exc)
        return n

    def _reap_overlong_sessions(self) -> int:
        """v-next P1-6: stop sessions past the idle timeout or max age so a
        forgotten / orphaned managed session can't keep a CLI authenticated
        and spending API quota indefinitely. Returns the count reaped.
        Runs on the executor thread (via `_tick_impl`) so it shares the
        single-writer lock with spawn/stop/drain."""
        if not self._sessions:
            return 0
        now = time.monotonic()
        # Snapshot the reap list BEFORE mutating `_sessions` in the stop call.
        reap: list[tuple[str, str]] = []
        for sid, sess in self._sessions.items():
            if now - sess.spawned_at > _SESSION_MAX_AGE_S:
                reap.append((sid, "max_age"))
            elif now - sess.last_activity_at > _SESSION_IDLE_TIMEOUT_S:
                reap.append((sid, "idle"))
        for sid, reason in reap:
            logger.info("reaping managed session %s (%s cap)", sid, reason)
            try:
                # review L3: info AFTER a successful stop (see _stop_all_sessions_impl).
                self._stop_session_impl(sid)
                self._post_info(sid, f"session auto-stopped ({reason} limit reached)")
            except Exception as exc:  # noqa: BLE001 — reap is best-effort
                logger.warning("reap(%s) failed: %s", sid, exc)
        return len(reap)

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
                # Iter 2B fix (Codex review on PR #18 manual test):
                # previously the dispatcher called the impl
                # unconditionally and stamped (True, "") regardless
                # of whether the session was actually owned by this
                # helper process. After a helper restart the macOS
                # app still saw the old session in remoteSessions
                # (its Supabase row outlived the previous helper
                # process), the row's device_id matched, and the
                # remote-queue path repeatedly stopped a session
                # that didn't exist — with `complete_command` rows
                # marked `delivered`, telling the app the no-op
                # succeeded and obscuring the stale-row bug. Now
                # the dispatcher checks ownership and reports
                # `failed` when the helper has no PTY for the
                # supplied session_id. The matching client-side fix
                # in `shouldRouteSessionLocally` no longer routes
                # these stale rows to the local UDS path either, so
                # a stale stop falls through to here and is
                # honestly surfaced as a failure.
                if session_id not in self._sessions:
                    ok, err = False, "session not running on this helper"
                else:
                    self._stop_session_impl(session_id)
                    ok, err = True, ""
            elif kind == "interrupt":
                # Same fail-closed posture as stop above. An
                # interrupt for a session this helper doesn't own
                # is a user-visible no-op; reporting it as
                # `delivered` would mask the stale row.
                if session_id not in self._sessions:
                    ok, err = False, "session not running on this helper"
                else:
                    self._interrupt_session_impl(session_id)
                    ok, err = True, ""
            elif kind == "tail_snapshot":
                # R0 (S3): serve the iOS/Android warm-resume snapshot over the
                # PRIVATE broadcast topic. get_tail_snapshot was local-UDS-only
                # before this — so cloud resume ALWAYS hit the 2 s degraded path.
                ok, err = self._handle_tail_snapshot(session_id, payload)
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
        # R0 (S3): None = UNKNOWN privacy (fail-closed: no broadcast). Only a
        # literal JSON `true`/`false` sets it; a missing or non-bool value stays
        # None so a public session is never inferred and re-broadcast.
        realtime_private: bool | None = None
        try:
            obj = json.loads(payload) if payload else {}
            if isinstance(obj, dict):
                provider = str(obj.get("provider") or "claude")
                cwd_hmac_v = obj.get("cwd_hmac")
                cwd_hmac = str(cwd_hmac_v) if cwd_hmac_v else None
                client_label_v = obj.get("client_label")
                client_label = str(client_label_v) if client_label_v else None
                rp_v = obj.get("realtime_private")
                realtime_private = rp_v if isinstance(rp_v, bool) else None
        except (json.JSONDecodeError, TypeError, ValueError):
            return False, "invalid start payload"

        # v1.15: any provider with a registered spawner is acceptable.
        # `_spawn_session_impl` does the actual `_spawner_for` lookup and
        # rejects unknown ones with a `kind='info'` event; here we only
        # surface the gate-level rejection text, which the SQL gate
        # uses to flip the row to `errored`.
        if self._spawner_for(provider) is None:
            return (
                False,
                f"provider {provider!r} not supported on this helper "
                f"(known: {', '.join(_known_provider_names())})",
            )

        # cwd_basename is metadata-only — we don't try to resolve it to
        # a full path because that would require the helper to know
        # about the user's project layout, which is outside Phase 1's
        # privacy posture. Spawn at $HOME (or PWD if HOME is unset).
        params = SessionStartParams(
            session_id=session_id,
            provider=provider,
            cwd="",
            cwd_hmac=cwd_hmac,
            client_label=client_label,
            realtime_private=realtime_private,
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
            # Cancel pending approvals + publish session_stopped so
            # streaming subscribers see the lifecycle without a
            # separate poll.
            if self._approval_registry is not None:
                try:
                    self._approval_registry.unregister_session(session_id)
                except Exception as exc:  # noqa: BLE001
                    logger.debug(
                        "registry unregister on exit(%s) failed: %s",
                        session_id, exc,
                    )
            if self._event_broker is not None:
                try:
                    self._event_broker.publish({
                        "event": "session_stopped",
                        "session_id": session_id,
                        "exit_code": code,
                    })
                except Exception as exc:  # noqa: BLE001
                    logger.debug(
                        "broker session_stopped publish failed: %s", exc,
                    )
            # R0 (2026-07-03 review): mirror the explicit-stop teardown — flush
            # the final coalesced broadcast chunk, then purge the per-session
            # token/denial/retry caches. Child-exit is the MOST COMMON end path
            # (/exit, Ctrl-D, CLI crash); without this the RealtimeTokenClient
            # dicts violated their "bounded to LIVE sessions" contract on the
            # long-lived daemon.
            if self._broadcast_publisher is not None:
                try:
                    self._broadcast_publisher.flush(session_id)
                    forget = getattr(self._broadcast_publisher, "forget", None)
                    if callable(forget):
                        forget(session_id)
                except Exception as exc:  # noqa: BLE001
                    logger.debug(
                        "broadcast flush on exit(%s) failed: %s", session_id, exc,
                    )
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
        """Start a new managed session on behalf of the local macOS
        app. The UDS server submits this through the executor (so this
        body always runs on the writer thread); we generate the session
        id here, spawn the PTY, and return the id back for the client
        to track.

        v1.15: name kept as `local_start_claude_session` for
        back-compat with HelperKit / Swift call sites, but the
        `payload['provider']` is now honored — Claude was the only
        v1.13/v1.14 option, but this path accepts the full registry
        (claude / codex / gemini) and forwards the choice to
        `SessionStartParams`. Codex review 2026-05-08 caught the
        previous hardcoded-claude bug.

        Note: we do NOT round-trip through Supabase to "create the
        pending row" first, because that's the latency the local
        path exists to avoid. `_spawn_session_impl` still calls
        `remote_helper_register_session` (best-effort) so iOS / Watch
        viewers see the session row appear via existing remote_app
        list paths within the next sync cycle. If the helper is
        offline, the session still works locally; the row simply
        doesn't propagate.
        """
        # v-next P0-A: warm the claude OAuth token cache HERE, on the UDS
        # connection thread, BEFORE dispatching onto the single-writer
        # executor. The (possibly network-bound) refresh then runs off the
        # executor, so the executor-side `_inject_provider_auth` is a cache
        # hit and a slow refresh never freezes other live sessions.
        self._prewarm_claude_auth(payload.get("provider") if isinstance(payload, dict) else None)
        return self._dispatch(self._local_start_claude_session_impl, payload)

    def _prewarm_claude_auth(self, provider: Any) -> None:
        """Resolve (and cache) the claude OAuth token off the executor.
        Best-effort + never raises — the executor-side resolve repeats the
        call (cache hit) and the real injection happens there."""
        if not isinstance(provider, str) or provider.lower() != "claude":
            return
        if self._claude_token_resolver is None:
            return
        try:
            self._claude_token_resolver()
        except Exception as exc:  # noqa: BLE001 — prewarm is best-effort
            logger.debug("claude auth prewarm failed (non-fatal): %s", exc)

    def _local_start_claude_session_impl(
        self, payload: dict[str, Any]
    ) -> dict[str, Any]:
        session_id = str(uuid.uuid4())
        client_label = payload.get("client_label")
        cwd_hmac = payload.get("cwd_hmac")
        # v1.15: read provider from payload (defaulting to claude for
        # callers older than v1.15 that omit the field). The UDS
        # server has already validated it against the spawner
        # registry; here we just plumb it through.
        provider = payload.get("provider") or "claude"
        if not isinstance(provider, str) or not provider:
            provider = "claude"
        # v-next P1-1: real working directory. The UDS server has already
        # validated it (absolute + existing dir); '' / missing → inherit the
        # daemon's dir (prior behaviour). Local-only — never sent to the cloud.
        cwd = payload.get("cwd")
        params = SessionStartParams(
            session_id=session_id,
            provider=provider,
            cwd=cwd if isinstance(cwd, str) and cwd else "",
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
        """Backwards-compatible alias retained for older callers + tests.

        Use `_spawner_for(...)` for new code. v1.15+: argv resolution
        lives in `helper/provider_spawners/<provider>.py`. Honors the
        same env-override knobs (`CLI_PULSE_<PROVIDER>_ARGV0`).
        """
        spawner = self._spawner_for(provider)
        if spawner is None:
            return None
        # Pass a None-equivalent params shim — the legacy `_argv_for`
        # caller had no params at all. Concrete spawners only read
        # `params.extra_env`, which gracefully reads as empty for the
        # legacy shim.
        return list(spawner.argv(_LegacyArgvParamsShim()))

    def _spawner_for(self, provider: str):
        """v1.15: resolve a `ProviderSpawner` for the given provider
        name. Returns None for unknown providers; caller logs +
        info-events.
        """
        # Lazy import — keeps this module importable on hosts where the
        # spawner package isn't on the path (e.g. legacy tests using
        # `sys.path = ['helper']` with no package init traversal).
        try:
            from provider_spawners import get_spawner
        except ImportError:  # pragma: no cover — defensive
            return self._legacy_claude_spawner_for(provider)
        return get_spawner(provider)

    def _legacy_claude_spawner_for(self, provider: str):
        """Fallback used only when the `helper.provider_spawners`
        package is not importable (extremely old test rigs). Returns a
        minimal anonymous spawner-shaped object that exposes argv()
        and reproduces the pre-v1.15 behavior for the `claude`
        provider.
        """
        if provider != "claude":
            return None

        class _LegacyClaudeSpawner:
            name = "claude"

            def argv(self, params):  # noqa: ARG002
                return list(RemoteAgentManager.CLAUDE_ARGV)

            def env_overrides(self, params):  # noqa: ARG002
                return {}

            def is_available(self):
                return True

            def supports_remote_approval(self):
                return True

        return _LegacyClaudeSpawner()

    def _build_env(
        self,
        params: SessionStartParams,
        *,
        capability_token: str | None = None,
    ) -> dict[str, str]:
        """Build the subset of env vars the manager controls. Posix
        transport merges this with `os.environ` so PATH / TERM survive.
        """
        env: dict[str, str] = {}
        env.update(params.extra_env or {})
        # v-next P0-C: launchd's minimal PATH omits /opt/homebrew/bin (agy)
        # and ~/.local/bin (claude), so the child can't exec the provider
        # binary. Append the common install dirs (same set the availability
        # probe searches). Base on a caller-supplied extra_env PATH when
        # present (so an explicit override is respected), else the daemon's
        # PATH. The POSIX transport merges this onto os.environ.
        env["PATH"] = augmented_path(env.get("PATH") or None)
        # Critical binding: `remote_hook.py` prefers this over Claude's
        # raw hook session_id when creating permission requests, so an
        # inline approve from the Sessions UI lands on the row matching
        # this managed session. After UUID validation only.
        env["CLI_PULSE_REMOTE_SESSION_ID"] = params.session_id
        # Phase 3 Iter 2B: when running on a helper that exposes the
        # local UDS fast path, pass the socket path + per-session
        # capability token so the hook prefers the same-Mac approval
        # surface over Supabase. The hook script reads these on
        # startup; if any are missing or the UDS isn't reachable, the
        # hook silently falls back to the existing Supabase remote
        # path. **Capability token is intentionally NOT logged.**
        if capability_token and self._local_helper_socket_path:
            env["CLI_PULSE_LOCAL_SESSION_ID"] = params.session_id
            env["CLI_PULSE_LOCAL_HOOK_TOKEN"] = capability_token
            env["CLI_PULSE_LOCAL_HELPER_SOCK"] = self._local_helper_socket_path
        return env

    def _inject_provider_auth(
        self, params: SessionStartParams, env: dict[str, str]
    ) -> tuple[int | None, dict[str, str]]:
        """Resolve + inject a fresh provider auth token for the child.

        Returns ``(auth_fd, env)``. For claude — when a token resolver is
        configured and yields a token — prefers passing the token over an
        INHERITED read-only pipe fd (`CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR`)
        so the raw token never lands in the child's env (and thus not in
        `ps eww` nor any tool subprocess claude itself spawns). `auth_fd`
        is the read-end the CALLER must close after `transport.start`
        returns — the child keeps its own inherited copy. Falls back to the
        `CLAUDE_CODE_OAUTH_TOKEN` env var if the fd plumbing fails, and to
        no injection ``(None, env)`` for non-claude providers or when no
        token resolves. NEVER raises — auth resolution must not break a
        spawn (a missing token just yields the pre-existing 401 behaviour).
        The token is NEVER logged.
        """
        if (params.provider or "").lower() != "claude":
            return None, env
        resolver = self._claude_token_resolver
        if resolver is None:
            return None, env
        try:
            token = resolver()
        except Exception as exc:  # noqa: BLE001 — resolution is best-effort
            logger.warning(
                "claude token resolve failed (spawning without injection): %s", exc
            )
            return None, env
        if not token:
            logger.info(
                "no claude OAuth token resolved; spawning without auth injection (may 401)"
            )
            return None, env
        env = dict(env)
        # Prefer the leak-safe FD path: write the token into a pipe, hand
        # the read-end to the child (inheritable + pass_fds), and tell
        # claude which fd to read. The token is in the pipe buffer (108
        # bytes ≪ pipe capacity) so the write never blocks.
        r: int | None = None
        try:
            r, w = os.pipe()
            try:
                os.write(w, token.encode("utf-8"))
            finally:
                os.close(w)
            os.set_inheritable(r, True)
            env["CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR"] = str(r)
            return r, env
        except OSError as exc:
            # If the pipe opened but a later step failed, close the read
            # end too — otherwise it leaks into the long-lived daemon.
            if r is not None:
                try:
                    os.close(r)
                except OSError:
                    pass
            logger.warning(
                "claude token FD plumbing failed; falling back to env var: %s", exc
            )
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
            return None, env

    @staticmethod
    def _extract_pid(handle: SessionHandle) -> int | None:
        """Best-effort PID extraction from a transport handle.

        POSIX transport stashes a `subprocess.Popen` on `handle.payload`;
        we read `.pid` from there. The Windows ConPTY transport (cli-
        pulse-desktop) will need a parallel accessor, but that track
        doesn't run the local approval surface in this iteration.
        """
        payload = getattr(handle, "payload", None)
        if payload is None:
            return None
        # PosixPty state exposes the long-lived child as `proc`. The
        # exec-mode transports (CodexExec / GeminiExec, v1.17 / v1.19)
        # store the per-turn subprocess as `current_proc` and have no
        # `proc` attribute, so this used to silently return None for
        # all exec sessions — breaking PID-based descent verification
        # in the approval hook. Fall back to `current_proc` so both
        # transport families register.
        proc = getattr(payload, "proc", None) or getattr(payload, "current_proc", None)
        if proc is None:
            return None
        pid = getattr(proc, "pid", None)
        if isinstance(pid, int) and pid > 0:
            return pid
        return None

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
        # Mirror the lifecycle change onto the local broker so a
        # subscribed macOS row updates without waiting for the next
        # snapshot poll. Best-effort.
        if self._event_broker is not None:
            try:
                self._event_broker.publish({
                    "event": "session_status",
                    "session_id": session_id,
                    "status": status,
                })
            except Exception as exc:  # noqa: BLE001
                logger.debug("broker session_status publish failed: %s", exc)

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
        # v1.16.2: strip ANSI / VT control sequences before everything
        # else. Without this, raw PTY bytes (CSI cursor moves, OSC
        # titles, DECSCUSR `\x1b[0 q`) are uploaded to Supabase and
        # surface as garbage like `[0 q [0 q` on remote viewers (notably
        # the iOS app whose CLIPulseCore can't be hot-fixed independently
        # of an App Store build). Local-fast-path consumers also benefit
        # — the macOS app's client-side AnsiSanitizer becomes a defence
        # layer instead of the only line of defence. Strip BEFORE
        # redact() because some control sequences could otherwise hide
        # token-shape patterns from the secret detector.
        # output_delta (SessionsTab preview + cloud / remote / iOS): strip ANSI
        # THEN redact. Strip BEFORE redact() because some control sequences could
        # otherwise hide token-shape patterns from the secret detector.
        stripped_redacted = redact(_ansi_strip(text))
        capped = stripped_redacted[:_EVENT_PAYLOAD_CAP_CHARS]
        # output_raw (v1.30.x in-app terminal, Phase 1b): un-stripped so the
        # ANSI/VT escapes survive and xterm.js renders the real TUI; still
        # redacted (defense-in-depth). Computed INDEPENDENTLY of `capped`: a
        # chunk that is PURE control sequences (screen clear `\x1b[2J`, cursor
        # moves, color-only) strips to empty → `capped` empty, but the terminal
        # MUST still receive those escapes or its TUI breaks. So we must NOT let
        # an empty output_delta short-circuit output_raw (agy review 2026-06-19).
        #
        # FAIL CLOSED on ANSI-interleaved secrets (codex review): a token split
        # by VT escapes (`sk-ant-…\x1b[31m…token`) survives a naive
        # `redact(text)` because the escape hides the token shape from the
        # matcher — and the raw stream is RETAINED + replayable via
        # get_tail_snapshot. So if stripping ANSI reveals a secret the raw
        # pass missed, store the stripped+redacted form instead: sacrifice
        # color fidelity for that one chunk to guarantee the secret can't leak
        # (into either the live output_raw event or the ring). Normal chunks
        # (and non-split secrets) keep their ANSI.
        raw_redacted = redact(text)
        if _ansi_strip(raw_redacted) != stripped_redacted:
            raw_full = stripped_redacted   # fail closed
        else:
            raw_full = raw_redacted
        raw_payload = raw_full[:_EVENT_PAYLOAD_CAP_CHARS]
        if not capped and not raw_payload:
            return False
        # v-next P1-2: append the RAW redacted bytes to the per-session ring
        # (bounded, lock-free — this runs on the single-writer executor) so
        # `get_tail_snapshot` can repaint a terminal opened mid-session. Also
        # mark activity for the idle reaper (P1-6). Use the full un-capped
        # fail-closed payload so a long chunk isn't truncated to the per-event
        # cap before it reaches the ring.
        sess = self._sessions.get(session_id)
        if sess is not None:
            ring_bytes = raw_full.encode("utf-8", "replace")
            if ring_bytes:
                sess.raw_ring.extend(ring_bytes)
                overflow = len(sess.raw_ring) - _RAW_RING_CAP_BYTES
                if overflow > 0:
                    del sess.raw_ring[:overflow]
                # R0 (B2/S3): ALSO stream these already-redacted raw bytes to the
                # PRIVATE `pterm:` broadcast topic — but ONLY for a session the
                # start payload marked private (Gemini #2 local gate). Skipping
                # public/unknown sessions HERE means zero mint calls + zero HTTP
                # for them, so a fleet-wide default-ON producer can't hammer
                # mint-realtime-token with 403s (never rely on the 403→backoff as
                # the public filter). Reuses the SAME redact-at-write path as the
                # ring/in-app terminal — the broadcast never sees un-redacted bytes.
                if (
                    self._broadcast_publisher is not None
                    and sess.params.realtime_private is True
                ):
                    # Guard like the sibling broker publishes: a producer fault
                    # must never break the redacted DB-event path below.
                    try:
                        self._broadcast_publisher.submit(
                            session_id, "stdout", bytes(ring_bytes)
                        )
                    except Exception as exc:  # noqa: BLE001
                        logger.debug("broadcast submit failed: %s", exc)
            sess.last_activity_at = time.monotonic()
        # Mirror to the local broker BEFORE the cloud post — keeps the same-Mac
        # UI snappy even if Supabase is briefly throttled / offline. The broker
        # delivers output_delta only to redacted-preview subscribers and
        # output_raw only to `raw=True` subscribers (the terminal window).
        if self._event_broker is not None:
            if capped:
                try:
                    self._event_broker.publish({
                        "event": "output_delta",
                        "session_id": session_id,
                        "payload": capped,
                    })
                except Exception as exc:  # noqa: BLE001
                    logger.debug("broker output_delta publish failed: %s", exc)
            # LOCAL BROKER ONLY — output_raw is NEVER `_post_event`-ed to the cloud.
            if raw_payload:
                try:
                    self._event_broker.publish({
                        "event": "output_raw",
                        "session_id": session_id,
                        "payload": raw_payload,
                    })
                except Exception as exc:  # noqa: BLE001
                    logger.debug("broker output_raw publish failed: %s", exc)
        # Cloud post only when there's stripped content — never upload an empty
        # payload (pure-ANSI chunk), and never upload the raw stream.
        if capped:
            return self._post_event(session_id, "stdout", capped)
        return True
