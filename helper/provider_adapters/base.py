"""Provider-adapter interface for Remote Agent Sessions.

Adapters convert a provider's permission-hook input into a redacted upload
payload, then translate the user's remote decision back into the provider's
hook output format.
"""
from __future__ import annotations

import abc
from dataclasses import dataclass, field
from typing import Any


# Risk tiers used to gate auto-approval and UI emphasis.
# - low:    read-only / safe metadata (Read, Glob, Grep, web fetch of public docs)
# - medium: file edits / writes inside cwd, common dev shell commands
# - high:   destructive shell (rm/mv outside cwd, sudo, network exfil), Always-Allow
class AdapterRisk:
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"

    ALL = (LOW, MEDIUM, HIGH)


@dataclass
class ParsedHookInput:
    """Normalised, redacted view of a provider hook input."""

    provider: str                              # claude | codex
    tool_name: str                             # e.g. Bash, Read, Edit
    summary: str                               # short, single line, ≤ 512
    payload: dict[str, Any] = field(default_factory=dict)  # redacted, JSON-safe
    risk: str = AdapterRisk.MEDIUM
    cwd_basename: str = ""
    cwd_hmac: str | None = None


@dataclass
class AdapterDecision:
    """Cross-provider decision result."""

    decision: str                              # approve | deny | fallback
    scope: str = "once"                        # once | alwaysSession
    reason: str = ""                           # human-readable, optional


class ProviderAdapter(abc.ABC):
    """Interface implemented by ClaudeAdapter / CodexAdapter / ShellAdapter."""

    provider: str = ""

    @abc.abstractmethod
    def parse_hook_input(self, raw: dict[str, Any], cwd_hmac: str | None) -> ParsedHookInput:
        """Convert raw provider stdin JSON to a ParsedHookInput."""

    @abc.abstractmethod
    def emit_hook_output(self, decision: AdapterDecision, parsed: ParsedHookInput) -> dict[str, Any]:
        """Build the provider-specific hook output JSON for stdout."""

    def emit_local_fallback(self, parsed: ParsedHookInput, reason: str) -> dict[str, Any]:
        """Hook output that asks the local CLI to handle the prompt itself.

        Used when the remote decision channel is unavailable, times out, or the
        request is high-risk and we choose to fail closed. Default is shared
        across providers but may be overridden.
        """
        return self.emit_hook_output(
            AdapterDecision(decision="fallback", scope="once", reason=reason),
            parsed,
        )
