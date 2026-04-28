"""Codex CLI PermissionRequest adapter — Phase 2 stub.

Codex hooks need the `codex_hooks` feature enabled. The PermissionRequest hook
output supports allow/deny but Codex does NOT currently expose
`updatedPermissions` / `updatedInput` as a usable capability, so Always Allow
is intentionally not implemented in Phase 1.

This stub raises NotImplementedError on parse_hook_input so a Phase 1 hook
invocation with --provider codex fails fast and visibly. emit_hook_output is
defined so a future implementor has a clear shape to fill in.
"""
from __future__ import annotations

from typing import Any

from .base import AdapterDecision, ParsedHookInput, ProviderAdapter


class CodexAdapter(ProviderAdapter):
    """Stub. See module docstring."""

    provider = "codex"

    def parse_hook_input(self, raw: dict[str, Any], cwd_hmac: str | None) -> ParsedHookInput:  # noqa: ARG002
        raise NotImplementedError(
            "CodexAdapter is Phase 2: enable codex_hooks and implement parse_hook_input"
        )

    def emit_hook_output(self, decision: AdapterDecision, parsed: ParsedHookInput) -> dict[str, Any]:  # noqa: ARG002
        # Shape for future Codex hook output. Kept intentionally minimal.
        if decision.decision == "approve":
            return {"permissionDecision": "allow"}
        if decision.decision == "deny":
            return {"permissionDecision": "deny"}
        return {"permissionDecision": "ask"}
