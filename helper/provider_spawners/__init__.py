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
from .base import BaseSpawner, augmented_path, resolved_user_home
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
      3b. `env_removals(params)` at spawn time — keys the transport
         DELETES after merging the parent env (a dict overlay can only
         add; Codex uses this to scrub `OPENAI_API_KEY` on-plan).
      4. `supports_remote_approval()` informational; today only Claude
         returns True (it has the `claude-pre-tool-use` hook). Codex
         and Gemini handle approvals inline in their TUI; the iOS
         spawn UI surfaces this so the user knows what they're getting.
      5. `plan_auth_status()` at hello time — "on_plan"/"off_plan"/
         "unknown", surfaced in `provider_plan_status` so the picker can
         warn before launching a billed managed session.
    """

    name: str

    def argv(self, params) -> list[str]:
        ...

    def env_overrides(self, params) -> dict[str, str]:
        ...

    def env_removals(self, params) -> set[str]:
        ...

    def is_available(self) -> bool:
        ...

    def supports_remote_approval(self) -> bool:
        ...

    def plan_auth_status(self, params=None) -> str:
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


def provider_plan_statuses() -> dict[str, str]:
    """Per-provider plan-auth status ("on_plan" / "off_plan") for the
    AVAILABLE providers — shipped in the UDS hello reply as
    `provider_plan_status` so the spawn picker can warn before silently
    launching an off-plan (billed) managed session (e.g. Codex with an
    api-key login). Omits "unknown" so indeterminate providers don't add
    a false warning (absent ⇒ no warning). Mirrors Swift
    `ProviderSpawnerRegistry.planAuthStatuses`.
    """
    out: dict[str, str] = {}
    for name, spawner in _REGISTRY.items():
        try:
            if not spawner.is_available():
                continue
            status = spawner.plan_auth_status()
        except Exception:  # noqa: BLE001 — one bad spawner must not break hello
            continue
        if status and status != "unknown":
            out[name] = status
    return out


__all__ = [
    "ProviderSpawner",
    "BaseSpawner",
    "augmented_path",
    "resolved_user_home",
    "ClaudeSpawner",
    "CodexSpawner",
    "GeminiSpawner",
    "AiderSpawner",
    "OpenCodeSpawner",
    "CursorSpawner",
    "get_spawner",
    "available_providers",
    "all_provider_names",
    "provider_plan_statuses",
]
