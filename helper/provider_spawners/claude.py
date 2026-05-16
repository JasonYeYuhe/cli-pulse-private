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

from .base import BaseSpawner


class ClaudeSpawner(BaseSpawner):
    name = "claude"
    binary = "claude"
    argv0_env = "CLI_PULSE_CLAUDE_ARGV0"

    # argv / env_overrides ({}) / is_available inherited verbatim from
    # BaseSpawner — Claude has no provider-specific env beyond what the
    # manager injects (CLI_PULSE_REMOTE_SESSION_ID, capability token).

    def supports_remote_approval(self) -> bool:
        # Claude has the `claude-pre-tool-use` hook protocol that the
        # helper translates into `remote_pending_approvals`. The other
        # providers don't (yet) — see each module's docstring.
        return True
