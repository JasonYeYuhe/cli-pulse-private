"""Generic shell-session adapter — Phase 2+ placeholder.

Reserved for non-provider sessions (plain bash/zsh under helper supervision).
There is no permission-hook protocol for plain shells; if remote approval is
ever wanted there it would be helper-mediated (e.g. wrap dangerous commands
with a confirm-via-cloud check). Not part of Phase 1.
"""
from __future__ import annotations

from typing import Any

from .base import AdapterDecision, ParsedHookInput, ProviderAdapter


class ShellAdapter(ProviderAdapter):
    """Placeholder. See module docstring."""

    provider = "shell"

    def parse_hook_input(self, raw: dict[str, Any], cwd_hmac: str | None) -> ParsedHookInput:  # noqa: ARG002
        raise NotImplementedError("ShellAdapter is reserved for a later phase")

    def emit_hook_output(self, decision: AdapterDecision, parsed: ParsedHookInput) -> dict[str, Any]:  # noqa: ARG002
        return {}
