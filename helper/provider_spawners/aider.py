"""
Aider spawner — H-F1 (v1.22).

Aider (`aider-chat` on PyPI, binary `aider`) is a widely-used pair-
programming CLI. It runs an interactive REPL by default and is commonly
launched once per git worktree in swarm workflows — which is exactly the
v1.22 Swarm View use case, so it must be a first-class managed provider
from day one (user Q5 sign-off, 2026-05-16).

Approval surface:
    Aider auto-applies edits / runs commands per its own
    `--yes`/`--no-auto-commits`/confirmation settings; there is no
    first-class hook protocol equivalent to Claude's
    `claude-pre-tool-use`, so `supports_remote_approval()` stays False
    (inherited). Swarm value here is *observability* (worktree tagging +
    heartbeat rollup), not remote approve.

Override the binary via `CLI_PULSE_AIDER_ARGV0` (same shape as the
Claude/Codex/Gemini overrides).
"""

from __future__ import annotations

from .base import BaseSpawner


class AiderSpawner(BaseSpawner):
    name = "aider"
    binary = "aider"
    argv0_env = "CLI_PULSE_AIDER_ARGV0"
