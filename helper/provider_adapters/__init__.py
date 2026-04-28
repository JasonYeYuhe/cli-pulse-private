"""Provider adapters for Remote Agent Sessions / Remote Approvals.

Each adapter knows how to:
  * parse the provider's hook input (PermissionRequest format)
  * build a redacted, minimised summary + payload for upload
  * classify the risk level (low / medium / high)
  * emit the provider-specific hook decision JSON to stdout

Phase 1 only ClaudeAdapter is fully implemented. CodexAdapter and ShellAdapter
are stubs whose interfaces are exercised by tests so a Phase 2 implementor has
a clear contract to fill in.
"""
from __future__ import annotations

from .base import ProviderAdapter, AdapterDecision, AdapterRisk, ParsedHookInput
from .claude import ClaudeAdapter
from .codex import CodexAdapter
from .shell import ShellAdapter

__all__ = [
    "ProviderAdapter",
    "AdapterDecision",
    "AdapterRisk",
    "ParsedHookInput",
    "ClaudeAdapter",
    "CodexAdapter",
    "ShellAdapter",
    "adapter_for",
]


def adapter_for(provider: str) -> ProviderAdapter:
    """Return the adapter instance for a provider name.

    Raises ValueError for unknown providers.
    """
    key = (provider or "").strip().lower()
    if key == "claude":
        return ClaudeAdapter()
    if key == "codex":
        return CodexAdapter()
    if key == "shell":
        return ShellAdapter()
    raise ValueError(f"unknown provider for remote approval: {provider!r}")
