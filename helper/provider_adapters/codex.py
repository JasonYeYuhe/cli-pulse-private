"""Codex CLI approval-hook adapter (M2).

Codex's hooks are Claude-compatible (verified v0.144 against
learn.chatgpt.com/docs/hooks): the same `hook_event_name`-tagged stdin, the same
`PreToolUse` / `PermissionRequest` events, and the same `hookSpecificOutput`
output wrapper. So `CodexAdapter` reuses `ClaudeAdapter`'s parse (risk classify +
redaction) and `PermissionRequest` emit verbatim, overriding ONLY the one real
difference:

  * Codex `PreToolUse.permissionDecision` is **allow | deny ONLY** — there is no
    "ask" value (Claude has allow|deny|ask|defer). A Codex PreToolUse abstains by
    emitting NO output (empty stdout, exit 0) → "Codex uses the normal approval
    flow." So an EXTERNAL (fail-open) Codex PreToolUse emits the empty-abstain
    sentinel `{}` instead of Claude's "ask"; a MANAGED one still denies.

`PermissionRequest` output is byte-identical to Claude (allow/deny, abstain via
empty output), so it is inherited unchanged. Always-Allow (`updatedInput` /
`permissionUpdates`) stays intentionally unexposed, same as Claude Phase 1.
"""
from __future__ import annotations

from typing import Any

from .base import AdapterDecision, ParsedHookInput
from .claude import ClaudeAdapter


class CodexAdapter(ClaudeAdapter):
    """Claude-compatible Codex adapter. See module docstring for the one diff."""

    provider = "codex"

    # Codex-worded fallback message (the inherited Claude one names "the local
    # Claude permission prompt" — wrong provider for a Codex session). Review: codex.
    _UNAVAILABLE_MSG = (
        "Remote approval unavailable. If this keeps happening, "
        "open CLI Pulse → Settings → Privacy and turn off "
        "Remote Control; Codex's local approval prompt will then "
        "run on your next attempt."
    )

    def _emit_pre_tool_use(
        self, decision: AdapterDecision, parsed: ParsedHookInput
    ) -> dict[str, Any]:
        # Codex PreToolUse has no "ask" — allow|deny only, abstain via empty
        # output. So an EXTERNAL (fail-open) fallback ABSTAINS (`{}` → the
        # `_emit` empty sentinel writes nothing → Codex's normal approval flow),
        # never a hard deny that would brick a hand-launched terminal Codex.
        out: dict[str, Any] = {"hookEventName": "PreToolUse"}
        if decision.decision == "approve":
            out["permissionDecision"] = "allow"
        elif decision.decision == "deny":
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = decision.reason or "Denied remotely via CLI Pulse"
        elif parsed.fail_open:
            return {}  # external + channel down → abstain → local approval flow
        else:
            # managed fallback → fail CLOSED (deny)
            out["permissionDecision"] = "deny"
            out["permissionDecisionReason"] = decision.reason or self._UNAVAILABLE_MSG
        return {"hookSpecificOutput": out}
