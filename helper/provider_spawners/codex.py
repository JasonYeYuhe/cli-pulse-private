"""
Codex CLI (OpenAI) spawner — v1.15.

Codex CLI 0.128.x uses an interactive PTY-based REPL by default. argv
without subcommand opens the chat UI; `codex exec` is the headless
one-shot mode (not used by managed sessions).

Approval surface:
    Codex prompts inline in the TUI (`Run this command? [Y/n]`-style);
    there is no first-class hook protocol equivalent to Claude's
    `claude-pre-tool-use`. Until that lands, the iOS spawn picker MUST
    surface "no remote approve for Codex — be at the Mac, or run with
    --full-auto" so the user is not surprised.

Override the binary path via `CLI_PULSE_CODEX_ARGV0` if needed (same
shape as the Claude override).
"""

from __future__ import annotations

from typing import Any

from .base import BaseSpawner


class CodexSpawner(BaseSpawner):
    name = "codex"
    binary = "codex"
    argv0_env = "CLI_PULSE_CODEX_ARGV0"

    # argv / is_available / supports_remote_approval (False — Codex
    # inline-prompts in its TUI, no hook protocol the helper can
    # translate) inherited verbatim from BaseSpawner.

    def env_overrides(self, params: Any) -> dict[str, str]:  # noqa: ARG002
        # v1.16 §2.1 defensive hardening: enable Rust backtrace by default
        # so when Codex's TUI panics on startup with the dreaded exit_code=101
        # we can capture WHY in stderr instead of seeing only the bare exit.
        # User can override by setting RUST_BACKTRACE=0 in their shell
        # profile (which is read by the parent helper's env-merge step).
        return {
            "RUST_BACKTRACE": "1",
        }
