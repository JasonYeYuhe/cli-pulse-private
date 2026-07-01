"""
Gemini (Antigravity CLI = `agy`) spawner.

v-next P0-B: the legacy `gemini` CLI now hard-fails individual-tier
accounts with `IneligibleTierError` and points to the **Antigravity CLI
`agy`** (`/opt/homebrew/bin/agy`). The registry KEY stays `"gemini"`
(the app's managed-session provider namespace is independent of the
usage-tracking `ProviderKind` enum), but the spawned binary is now `agy`.

`agy` defaults to an interactive PTY TUI on a bare launch (proven
on-device 2026-06-20 under the helper's PosixPtyTransport: it stays
interactive and accepts typed stdin). Managed sessions carry NO seed
prompt at spawn — input flows via `send_input_raw` (in-app xterm.js
keystrokes) / `write_to_session` (remote submit) AFTER spawn — so the
argv is the bare `["agy"]`, mirroring `["claude"]`. basename `"agy"`
auto-routes to `PosixPtyTransport` (the gemini-specific exec transport
was deleted with this swap).

Approval surface:
    `agy` exposes `--dangerously-skip-permissions` (auto-approve all tool
    permission requests). There is no first-class hook protocol the
    helper can subscribe to.

    `params.extra_env` carries an optional `CLI_PULSE_GEMINI_YOLO=1` flag
    when an opt-in YOLO toggle ships in the picker. The translation —
    env var ⇒ `--dangerously-skip-permissions` argv flag — is here so the
    spawner is ready when the UI lands. Until then the env var is never
    set and `agy` prompts inline in its TUI.

Override the binary path via `CLI_PULSE_GEMINI_ARGV0` if `agy` lives
somewhere unusual (same shape as Claude/Codex overrides).
"""

from __future__ import annotations

from typing import Any

from .base import BaseSpawner


class GeminiSpawner(BaseSpawner):
    name = "gemini"
    binary = "agy"
    argv0_env = "CLI_PULSE_GEMINI_ARGV0"

    # env_overrides ({}) / is_available / supports_remote_approval
    # (False — same posture as Codex) inherited verbatim from
    # BaseSpawner.

    def argv(self, params: Any) -> list[str]:
        # Base handles argv0-override tokenization (and the compound
        # override + flag case the tests pin). Default → bare ["agy"].
        argv = super().argv(params)

        # Forward the yolo opt-in only if the spawn request explicitly
        # set it via env. Default OFF; the picker owns the consent UX.
        # agy's flag is --dangerously-skip-permissions (the legacy gemini
        # CLI used --yolo).
        extra_env = getattr(params, "extra_env", None) or {}
        if extra_env.get("CLI_PULSE_GEMINI_YOLO") in ("1", "true", "yes"):
            argv = argv + ["--dangerously-skip-permissions"]

        return argv

    def plan_auth_status(self, params: Any = None) -> str:  # noqa: ARG002
        # "on_plan" when `agy` is resolvable (managed Gemini runs on the
        # user's Gemini plan via agy's own OAuth — we never fall back to a
        # billed path); "unknown" otherwise (no agy ⇒ managed Gemini is
        # unavailable, so don't emit a false off-plan warning). Never
        # "off_plan". Mirrors Swift GeminiSpawner.planAuthStatus.
        return "on_plan" if self.is_available() else "unknown"
