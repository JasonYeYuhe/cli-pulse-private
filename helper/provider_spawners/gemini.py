"""
Gemini CLI (Google) spawner — v1.15.

Gemini CLI 0.38.x defaults to interactive PTY mode. `--prompt` /
`--prompt-interactive` exist for headless / seeded modes (not used by
managed sessions today; the manager will inject the seeded prompt via
PTY stdin write after spawn).

Approval surface:
    Gemini has an `--approval-mode` flag with values
    `default | auto_edit | yolo | plan` plus a `--yolo` shorthand.
    There is no first-class hook protocol the helper can subscribe to.

    `params.extra_env` is the wire that will carry an optional
    `CLI_PULSE_GEMINI_YOLO=1` flag when an opt-in YOLO toggle ships in
    the picker. The translation logic — env var ⇒ `--yolo` argv flag —
    is implemented here so the spawner is ready when the UI lands.

    Future picker work (NOT in v1.15): an explicit, per-spawn
    "Auto-approve all tools (yolo)" toggle so the user picks between
    failure modes:
      * default — every tool prompts in the TUI; user must walk to
                  the Mac to approve. Safe but blocks managed-session
                  UX.
      * yolo    — Gemini auto-approves everything. Risky but unblocks
                  remote use. Must require explicit per-spawn opt-in
                  (no remembered preference) when this UI exists.

    Until that UI ships, the env var is never set by any caller and
    Gemini runs in `default` mode.

Override the binary path via `CLI_PULSE_GEMINI_ARGV0` if needed (same
shape as Claude/Codex overrides).
"""

from __future__ import annotations

import os
import shutil
from typing import Any


class GeminiSpawner:
    name = "gemini"

    def argv(self, params: Any) -> list[str]:
        override = os.environ.get("CLI_PULSE_GEMINI_ARGV0")
        argv: list[str]
        if override:
            tokens = override.split()
            argv = tokens if tokens else ["gemini"]
        else:
            argv = ["gemini"]

        # Forward --yolo only if the iOS spawn request explicitly opted
        # in via env. Default OFF; the iOS picker is responsible for
        # the consent UX.
        extra_env = getattr(params, "extra_env", None) or {}
        if extra_env.get("CLI_PULSE_GEMINI_YOLO") in ("1", "true", "yes"):
            argv = argv + ["--yolo"]

        return argv

    def env_overrides(self, params: Any) -> dict[str, str]:  # noqa: ARG002
        return {}

    def is_available(self) -> bool:
        override = os.environ.get("CLI_PULSE_GEMINI_ARGV0")
        if override:
            tokens = override.split()
            if tokens and (
                shutil.which(tokens[0]) is not None
                or os.path.isabs(tokens[0]) and os.access(tokens[0], os.X_OK)
            ):
                return True
        return shutil.which("gemini") is not None

    def supports_remote_approval(self) -> bool:
        # No first-class hook protocol. Same posture as Codex.
        return False
