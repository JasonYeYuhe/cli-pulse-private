"""RemoteAgentManager — Phase 1 skeleton.

Phase 1 only ships the approval-hook flow (see remote_hook.py). The PTY-managed
session, command polling loop, and event batching are sketched here so a Phase
2 implementor can fill them in against a fixed interface without redesigning
the public surface.

What lives here today:
  * RemoteAgentManager   — stub class with documented method signatures
  * SessionStartParams   — parameter dataclass for spawn_session
  * EventBatcher         — small helper used by both phases for capped tail upload

What is intentionally NOT done in Phase 1:
  * subprocess.Popen / pty.fork managed sessions
  * stdout/stderr tail batching loop
  * stop / interrupt signal forwarding
  * approval-only mode wiring (the hook itself is the one entry point right now)

The daemon does NOT instantiate this yet. Wiring it into cli_pulse_helper.py's
daemon loop is part of the Phase 2 task.
"""
from __future__ import annotations

import logging
import time
from dataclasses import dataclass, field
from typing import Any, Callable

logger = logging.getLogger("cli_pulse.remote_agent")


@dataclass
class SessionStartParams:
    """Inputs for RemoteAgentManager.spawn_session."""

    session_id: str
    provider: str                              # claude | codex | shell
    cwd: str                                   # full path; basename + hmac uploaded
    cwd_hmac: str | None = None
    client_label: str | None = None
    approval_only: bool = True                 # Phase 1 always True
    extra_env: dict[str, str] = field(default_factory=dict)


class EventBatcher:
    """Coalesce small terminal-output chunks into ≤ 4 KB rows.

    Provider event rows are capped server-side (see migrate_v0.26 row CHECK).
    The batcher flushes when buffered bytes reach `flush_bytes` or when more
    than `max_idle_s` have elapsed since the first un-flushed write.
    """

    def __init__(self, flush_bytes: int = 3500, max_idle_s: float = 0.5) -> None:
        self.flush_bytes = flush_bytes
        self.max_idle_s = max_idle_s
        self._buf: list[str] = []
        self._size: int = 0
        self._first_at: float | None = None

    def add(self, chunk: str) -> str | None:
        """Append `chunk` to the buffer. Returns a flushed payload if ready."""
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
        # Hard cap to row CHECK regardless of self.flush_bytes mis-config.
        return joined[:4096]


class RemoteAgentManager:
    """Phase 1 skeleton — does not actually spawn or supervise a session.

    Method signatures are stable so Phase 2 can fill in the bodies without
    reshaping helpers around them.
    """

    def __init__(self, helper_config: Any, rpc_caller: Callable[..., Any]) -> None:
        self.helper_config = helper_config
        self.rpc_caller = rpc_caller
        self._sessions: dict[str, SessionStartParams] = {}

    # ── lifecycle ─────────────────────────────────────────────

    def spawn_session(self, params: SessionStartParams) -> None:
        """Phase 2: PTY-fork the provider CLI; Phase 1: register-only.

        The Phase 1 implementation just registers the session with Supabase so
        an iOS/Mac client can see it appear. There is no actual subprocess.
        """
        if params.session_id in self._sessions:
            logger.warning("session %s already registered", params.session_id)
            return
        self._sessions[params.session_id] = params
        try:
            self.rpc_caller(
                "remote_helper_register_session",
                {
                    "p_device_id": self.helper_config.device_id,
                    "p_helper_secret": self.helper_config.helper_secret,
                    "p_session_id": params.session_id,
                    "p_provider": params.provider,
                    "p_cwd_basename": (params.cwd.rsplit("/", 1)[-1] if params.cwd else "")[:255],
                    "p_cwd_hmac": params.cwd_hmac,
                    "p_client_label": params.client_label,
                },
            )
        except Exception as exc:
            logger.warning("register_session(%s) failed: %s", params.session_id, exc)

    def stop_session(self, session_id: str) -> None:
        """Phase 2: send SIGTERM to the PTY child. Phase 1: drop registry entry."""
        self._sessions.pop(session_id, None)

    def interrupt_session(self, session_id: str) -> None:
        """Phase 2: send SIGINT to the foreground process group."""
        # Phase 1: no-op. Documented so Phase 2 implementor knows the contract.
        _ = self._sessions.get(session_id)

    # ── command polling ───────────────────────────────────────

    def poll_and_dispatch_commands(self, max_commands: int = 10) -> int:
        """Pull pending commands and return how many were processed.

        Phase 1 stub: pulls but does not actually act. Each command is
        immediately marked `failed` with a clear error so the app sees the
        Phase 1 boundary instead of silent black-holing.
        """
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
            logger.warning("pull_commands failed: %s", exc)
            return 0

        if not isinstance(result, list):
            return 0

        for cmd in result:
            cmd_id = cmd.get("id") if isinstance(cmd, dict) else None
            if not cmd_id:
                continue
            try:
                self.rpc_caller(
                    "remote_helper_complete_command",
                    {
                        "p_device_id": self.helper_config.device_id,
                        "p_helper_secret": self.helper_config.helper_secret,
                        "p_command_id": cmd_id,
                        "p_status": "failed",
                        "p_error": "managed-session execution is Phase 2; only approvals are wired in v1",
                    },
                )
            except Exception as exc:
                logger.warning("complete_command(%s) failed: %s", cmd_id, exc)

        return len(result)
