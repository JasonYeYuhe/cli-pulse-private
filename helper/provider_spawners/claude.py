"""
Claude Code spawner — extracted from `RemoteAgentManager` in v1.15.

Behaviour preserved verbatim from the pre-refactor inline path:

* argv = ["claude"]; PATH-resolved at exec time
* No env overrides today (env merging happens in `_build_env` higher up)
* Approval hook is the only first-class remote-approval flow we have
  (`claude-pre-tool-use` → `remote_hook.py` → `remote_pending_approvals`)

Override the binary path via `CLI_PULSE_CLAUDE_ARGV0` env var on the
helper host if the user has Claude installed somewhere unusual
(e.g. `/Users/me/.claude/local/claude`). Whitespace-separated for
multi-token argv0; first token is the binary, rest are flags prepended
in front of the manager's argv.
"""

from __future__ import annotations

import os
import shutil
from typing import Any


class ClaudeSpawner:
    name = "claude"

    def argv(self, params: Any) -> list[str]:  # noqa: ARG002
        override = os.environ.get("CLI_PULSE_CLAUDE_ARGV0")
        if override:
            tokens = override.split()
            if tokens:
                return tokens
        return ["claude"]

    def env_overrides(self, params: Any) -> dict[str, str]:  # noqa: ARG002
        # Claude has no provider-specific env beyond what the manager
        # already injects (CLI_PULSE_REMOTE_SESSION_ID, capability
        # token). Keep the hook here for future env knobs.
        return {}

    def is_available(self) -> bool:
        # Honor the env override above for the availability check too,
        # so a user with a non-PATH claude install can still see the
        # provider light up in the app.
        override = os.environ.get("CLI_PULSE_CLAUDE_ARGV0")
        if override:
            tokens = override.split()
            if tokens and (
                shutil.which(tokens[0]) is not None
                or os.path.isabs(tokens[0]) and os.access(tokens[0], os.X_OK)
            ):
                return True
        return shutil.which("claude") is not None

    def supports_remote_approval(self) -> bool:
        # Claude has the `claude-pre-tool-use` hook protocol that the
        # helper translates into `remote_pending_approvals`. Codex and
        # Gemini don't (yet).
        return True
