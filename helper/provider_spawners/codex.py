"""
Codex CLI (OpenAI) spawner — v1.15.

Codex CLI 0.128.x uses an interactive PTY-based REPL by default. argv
without subcommand opens the chat UI; `codex exec` is the headless
one-shot mode (not used by managed sessions).

Approval surface:
    Codex prompts inline in the TUI (`Run this command? [Y/n]`-style);
    there is no first-class hook protocol equivalent to Claude's
    `claude-pre-tool-use`. Until that lands, the iOS spawn picker MUST
    surface "no remote approve for Codex — be at the Mac, or run with
    --full-auto" so the user is not surprised.

Override the binary path via `CLI_PULSE_CODEX_ARGV0` if needed (same
shape as the Claude override).

v1.35 on-plan (Swift↔Python parity with HelperKit `CodexSpawner`):
    Make a managed Codex session run on the user's CHATGPT PLAN, not the
    pay-per-token API. Codex is file-driven — it reads `~/.codex/auth.json`,
    honors `CODEX_HOME`, and self-refreshes its own token on launch — so we
    inject no token. We instead:
      - pin `CODEX_HOME=<home>/.codex` so codex reads the right dir even when
        launchd hands the daemon a drifted `HOME`; and
      - DELETE any inherited `OPENAI_API_KEY` so codex can't silently fall
        back to the billed API — but ONLY when the user has a VERIFIED
        ChatGPT login (`auth_mode == "chatgpt"` + a non-empty access/refresh
        token). For an api-key login or a missing/unreadable auth.json we
        DON'T scrub, leaving their own auth intact (no worse than today).
    The removal rides `env_removals` (the transport pops it AFTER merging the
    parent env, because a dict overlay can only add — mirrors Swift
    `ProviderEnvPatch.remove`).
"""

from __future__ import annotations

import json
from typing import Any, Callable

from .base import BaseSpawner, resolved_user_home


class CodexSpawner(BaseSpawner):
    name = "codex"
    binary = "codex"
    argv0_env = "CLI_PULSE_CODEX_ARGV0"

    # argv / is_available / supports_remote_approval (False — Codex
    # inline-prompts in its TUI, no hook protocol the helper can
    # translate) inherited verbatim from BaseSpawner.

    def env_overrides(self, params: Any) -> dict[str, str]:  # noqa: ARG002
        # v1.16 §2.1 defensive hardening: enable Rust backtrace by default
        # so when Codex's TUI panics on startup with the dreaded exit_code=101
        # we can capture WHY in stderr instead of seeing only the bare exit.
        # User can override by setting RUST_BACKTRACE=0 in their shell
        # profile (which is read by the parent helper's env-merge step).
        overrides: dict[str, str] = {"RUST_BACKTRACE": "1"}
        # v1.35: pin CODEX_HOME so codex reads the on-plan auth.json even when
        # a launchd HOME drifted. Skip entirely if the home is unresolvable
        # (root / bad pw_dir) — pinning off a bad home would be worse than the
        # inherited default. Mirrors Swift CodexSpawner.envPatch's guard.
        home = resolved_user_home()
        if home is not None:
            overrides["CODEX_HOME"] = f"{home}/.codex"
        return overrides

    def env_removals(self, params: Any) -> set[str]:  # noqa: ARG002
        # Scrub an inherited OPENAI_API_KEY so an on-plan managed Codex can't
        # fall back to the billed API — but ONLY when there's a verified
        # ChatGPT login AND a resolvable home (same guard as the CODEX_HOME
        # pin, so we never scrub while keying the auth check off a different
        # home than the pin). Mirrors Swift CodexSpawner.envPatch.remove.
        home = resolved_user_home()
        if home is not None and self.has_verified_chatgpt_auth(home):
            return {"OPENAI_API_KEY"}
        return set()

    def plan_auth_status(self, params: Any = None) -> str:  # noqa: ARG002
        # "on_plan" when a verified ChatGPT login exists (the scrub fires →
        # runs on the plan); "off_plan" when an api-key/other login means
        # codex would bill the API; "unknown" when the home is unresolvable.
        # Lets the picker warn before silently launching a billed session.
        # Mirrors Swift CodexSpawner.planAuthStatus.
        home = resolved_user_home()
        if home is None:
            return "unknown"
        return "on_plan" if self.has_verified_chatgpt_auth(home) else "off_plan"

    @staticmethod
    def has_verified_chatgpt_auth(
        home: str | None,
        file_loader: Callable[[str], bytes | None] | None = None,
    ) -> bool:
        """True iff ``<home>/.codex/auth.json`` is a verified ChatGPT-plan
        login: ``auth_mode == "chatgpt"`` AND a non-empty
        ``tokens.access_token``/flat ``access_token``/``tokens.refresh_token``.
        ``file_loader`` is injectable for tests. Mirrors Swift
        ``CodexSpawner.hasVerifiedChatGPTAuth`` (and the token shape
        ``system_collector._fetch_codex_usage`` already reads).
        """
        if not home or not home.startswith("/"):
            return False
        path = f"{home}/.codex/auth.json"

        def _default_loader(p: str) -> bytes | None:
            try:
                with open(p, "rb") as fh:
                    return fh.read()
            except OSError:
                return None

        load = file_loader or _default_loader
        raw = load(path)
        if not raw:
            return False
        try:
            outer = json.loads(raw)
        except (ValueError, TypeError):
            return False
        if not isinstance(outer, dict):
            return False
        if str(outer.get("auth_mode", "")).lower() != "chatgpt":
            return False
        tokens = outer.get("tokens")
        if isinstance(tokens, dict):
            if tokens.get("access_token") or tokens.get("refresh_token"):
                return True
        # Flat shape (some codex builds write the token at top level).
        if outer.get("access_token"):
            return True
        return False
