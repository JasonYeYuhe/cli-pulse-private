"""
OpenCode spawner — H-F1 (v1.22).

OpenCode (SST, binary `opencode`) is an open-source terminal AI coding
agent that shipped git-worktree-friendly parallel workflows in early
2026 — a core Swarm View target (user Q5 sign-off, 2026-05-16).

Approval surface:
    OpenCode handles tool permission inline in its own TUI; no Claude-
    style hook protocol the helper can translate to
    `remote_pending_approvals`, so `supports_remote_approval()` stays
    False (inherited). v1.22 value is worktree-tagged observability via
    the hook/heartbeat path, not remote approve.

Override the binary via `CLI_PULSE_OPENCODE_ARGV0`.
"""

from __future__ import annotations

from .base import BaseSpawner


class OpenCodeSpawner(BaseSpawner):
    name = "opencode"
    binary = "opencode"
    argv0_env = "CLI_PULSE_OPENCODE_ARGV0"
