"""
Cursor CLI spawner — H-F1 (v1.22).

Cursor's headless terminal agent binary is `cursor-agent` (distinct from
the `cursor` editor launcher). It is increasingly run multi-instance
across worktrees, so Swarm View must cover it day one (user Q5 sign-off,
2026-05-16). The registry name is the user-facing `cursor`; the resolved
binary is `cursor-agent`.

Approval surface:
    cursor-agent runs with its own auto/ask permission model in the
    terminal; no first-class hook protocol the helper can translate, so
    `supports_remote_approval()` stays False (inherited). v1.22 value is
    observability (worktree tagging + heartbeat), not remote approve.

Override the binary via `CLI_PULSE_CURSOR_ARGV0` — required for users
whose Cursor CLI is installed under a non-PATH or differently-named
path; whitespace-tokenized like the other provider overrides.
"""

from __future__ import annotations

from .base import BaseSpawner


class CursorSpawner(BaseSpawner):
    name = "cursor"
    binary = "cursor-agent"
    argv0_env = "CLI_PULSE_CURSOR_ARGV0"
