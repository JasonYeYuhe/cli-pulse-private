"""
Provider-spawner registry for managed remote sessions (v1.15+).

Background: until v1.14 the helper hardcoded `claude` as the only
spawnable provider in `RemoteAgentManager`. Multi-CLI support
(Codex / Gemini / future) needs each provider's argv resolution,
capability detection, and approval-surface contract isolated in one
place each so the manager itself stays provider-agnostic.

This module exposes:

* `ProviderSpawner` — the protocol every provider implements.
* `get_spawner(name)` — registry lookup; returns None for unknown
  provider names so the caller can fail-soft.
* `available_providers()` — list of provider names whose binaries are
  on PATH. Helper uses this to advertise capabilities to the app via
  heartbeat.

Add a new provider (H-F1, v1.22): subclass `BaseSpawner` in a new module
in `helper/provider_spawners/` setting `name` / `binary` / `argv0_env`
(override a method only if the CLI genuinely diverges), then register
the instance in `_REGISTRY` below and re-export it in `__all__`. The
old per-provider copies of the argv0-override + `is_available` probe
were collapsed into `BaseSpawner` so this is now a ~10-line change.
"""

from __future__ import annotations

from typing import Protocol, runtime_checkable

# Re-export the provider classes so callers can do
#   from provider_spawners import ClaudeSpawner
# without knowing the per-provider module names. Relative imports
# (rather than `helper.provider_spawners.X`) so the package resolves
# both at runtime (helper invoked from inside `helper/`) and in CI
# (`pytest -q` from `helper/`).
from .aider import AiderSpawner
from .base import BaseSpawner
from .claude import ClaudeSpawner
from .codex import CodexSpawner
from .cursor import CursorSpawner
from .gemini import GeminiSpawner
from .opencode import OpenCodeSpawner


@runtime_checkable
class ProviderSpawner(Protocol):
    """Per-provider strategy for spawning the interactive REPL.

    `RemoteAgentManager` calls these in this order:

      1. `is_available()` at startup — to advertise capability map.
      2. `argv(params)` at spawn time — final argv passed to the
         transport.
      3. `env_overrides(params)` at spawn time — provider-specific env
         vars merged onto the manager's base env.
      4. `supports_remote_approval()` informational; today only Claude
         returns True (it has the `claude-pre-tool-use` hook). Codex
         and Gemini handle approvals inline in their TUI; the iOS
         spawn UI surfaces this so the user knows what they're getting.
    """

    name: str

    def argv(self, params) -> list[str]:
        ...

    def env_overrides(self, params) -> dict[str, str]:
        ...

    def is_available(self) -> bool:
        ...

    def supports_remote_approval(self) -> bool:
        ...


# Concrete registry. Add new providers here.
_REGISTRY: dict[str, ProviderSpawner] = {
    "claude": ClaudeSpawner(),
    "codex": CodexSpawner(),
    "gemini": GeminiSpawner(),
    # H-F1 (v1.22): swarm coverage of the next CLI wave from day one.
    "aider": AiderSpawner(),
    "opencode": OpenCodeSpawner(),
    "cursor": CursorSpawner(),
}


def get_spawner(name: str) -> ProviderSpawner | None:
    """Return the spawner for `name` or None if unknown.

    Caller is expected to log + reject unknown providers via the
    `info` event channel; this function is intentionally fail-soft
    rather than raising so the manager can keep handling other
    provider commands.
    """
    return _REGISTRY.get(name.lower())


def available_providers() -> list[str]:
    """Names of providers whose binary is on PATH and runnable.

    Used by `helper_heartbeat` to populate `devices.provider_availability`
    so the app's spawn picker can grey out unsupported providers
    instead of failing at spawn time.
    """
    return sorted(
        name for name, spawner in _REGISTRY.items() if spawner.is_available()
    )


def all_provider_names() -> list[str]:
    """All registered provider names, regardless of installation
    status. Useful for diagnostics (`helper status` / dev tooling).
    """
    return sorted(_REGISTRY.keys())


__all__ = [
    "ProviderSpawner",
    "BaseSpawner",
    "ClaudeSpawner",
    "CodexSpawner",
    "GeminiSpawner",
    "AiderSpawner",
    "OpenCodeSpawner",
    "CursorSpawner",
    "get_spawner",
    "available_providers",
    "all_provider_names",
]
