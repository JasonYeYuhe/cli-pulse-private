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

import os
import shutil
from typing import Any


class CodexSpawner:
    name = "codex"

    def argv(self, params: Any) -> list[str]:  # noqa: ARG002
        override = os.environ.get("CLI_PULSE_CODEX_ARGV0")
        if override:
            tokens = override.split()
            if tokens:
                return tokens
        return ["codex"]

    def env_overrides(self, params: Any) -> dict[str, str]:  # noqa: ARG002
        # No Codex-specific env required for the spawn. The iOS picker
        # may want to forward a model preference in the future via
        # `params.extra_env`, which the manager already merges.
        return {}

    def is_available(self) -> bool:
        override = os.environ.get("CLI_PULSE_CODEX_ARGV0")
        if override:
            tokens = override.split()
            if tokens and (
                shutil.which(tokens[0]) is not None
                or os.path.isabs(tokens[0]) and os.access(tokens[0], os.X_OK)
            ):
                return True
        return shutil.which("codex") is not None

    def supports_remote_approval(self) -> bool:
        # Codex inline-prompts approvals in stdout — no hook
        # protocol the helper can translate to `remote_pending_approvals`
        # in v1.15. Defer until upstream exposes a structured channel
        # OR we build a TUI-pattern detector (significant scope).
        return False
