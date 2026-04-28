"""Claude Code PermissionRequest adapter.

Claude's official hook contract (PermissionRequest), per
https://code.claude.com/docs/en/hooks (verified 2026-04-28):

  stdin  → { "tool_name": str, "tool_input": {...}, "session_id": str, "cwd": str, ... }

  stdout → {
    "hookSpecificOutput": {
      "hookEventName": "PermissionRequest",
      "decision": {
        "behavior": "allow" | "deny",          // ← only these two values
        "message":  str | null                  // ← required for "deny"
      }
    }
  }

PermissionRequest does NOT support "ask" (that exists only on PreToolUse's
permissionDecision field, which is a different hook event). The docs do not
specify a fallback shape for "ask the user locally"; the only documented
fail-closed path is `behavior: "deny"` with a `message` explaining why.

Decisions therefore follow the docs exactly:

  - Remote approve   → behavior: "allow"
  - Remote deny      → behavior: "deny",  message: <user's deny reason>
  - Remote channel
    unavailable
    or timed out     → behavior: "deny",  message: "Remote approval
                                                    unavailable; please
                                                    retry locally"
  - High-risk
    fail-closed      → behavior: "deny",  message: "High-risk action
                                                    requires local approval"

Always-Allow / `permissionUpdates` is intentionally never emitted in Phase 1.
"""
from __future__ import annotations

import re
from typing import Any

from .base import AdapterDecision, AdapterRisk, ParsedHookInput, ProviderAdapter


# Tools that read state but don't change it. Approving these remotely is low
# risk — we still let the user approve, but we won't auto-deny them.
_LOW_RISK_TOOLS = {
    "Read", "Glob", "Grep", "WebFetch", "WebSearch",
    "TodoRead", "ListMcpResources",
}

# Shell command tokens that should always be HIGH risk regardless of content.
_HIGH_RISK_SHELL_TOKENS = (
    "rm -rf", "rm -fr", "sudo ", " sudo", "mkfs", "dd if=", " :(){ :|:& };:",
    "shutdown", "reboot", "killall", "chmod 777 /",
    "curl ", "wget ",                          # outbound (could be exfil)
    "ssh ", "scp ", "rsync ",
    "history -c", "kextload", "csrutil ",
)

_REDACT_PATTERNS = (
    # Provider API keys
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"AIza[0-9A-Za-z_\-]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    # AWS-style
    re.compile(r"AKIA[0-9A-Z]{12,}"),
    # Generic Bearer
    re.compile(r"Bearer\s+[A-Za-z0-9._\-]{16,}", re.IGNORECASE),
    # JWTs — three base64url segments separated by dots, header always begins
    # with `eyJ` (base64 of `{"`). Catches Supabase access tokens, Auth0
    # tokens, GCP id_tokens, Anthropic OAuth refresh tokens, etc. Targeted
    # rather than generic base64 because a wider \b[A-Za-z0-9+/=]{40,}\b
    # over-matches long file paths and project identifiers.
    re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
    # Long hex tokens (covers helper_secret-style values, MD5/SHA hashes,
    # un-dashed UUIDs).
    re.compile(r"\b[A-Fa-f0-9]{32,}\b"),
)

# Future work (Gemini review P3 #9): tool inputs like `cat .env` or
# `cat ~/.aws/credentials` will still pass through summary/payload because
# the *filename* itself is non-secret text. A v2 redactor should match
# sensitive filename patterns (.env, id_rsa, *.pem, credentials.json, ...)
# and strip the surrounding command. Tracked separately, not in Phase 1.


def _redact(text: str) -> str:
    out = text
    for pat in _REDACT_PATTERNS:
        out = pat.sub("«REDACTED»", out)
    return out


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def _classify_risk(tool_name: str, tool_input: dict[str, Any]) -> str:
    if tool_name in _LOW_RISK_TOOLS:
        return AdapterRisk.LOW
    if tool_name == "Bash":
        cmd = str(tool_input.get("command", ""))
        for tok in _HIGH_RISK_SHELL_TOKENS:
            if tok in cmd:
                return AdapterRisk.HIGH
        return AdapterRisk.MEDIUM
    # Edit / Write / MCP / etc — default medium. WebSearch is in low set above.
    return AdapterRisk.MEDIUM


def _summary_for(tool_name: str, tool_input: dict[str, Any]) -> str:
    """Build a short, single-line summary safe to show in remote UI."""
    if tool_name == "Bash":
        cmd = _redact(str(tool_input.get("command", "")))
        return _truncate(f"$ {cmd}", 256)
    if tool_name in ("Read", "Edit", "Write"):
        path = str(tool_input.get("file_path") or tool_input.get("path") or "")
        # Path becomes basename only — full path can leak project structure
        basename = path.rsplit("/", 1)[-1] if path else ""
        return _truncate(f"{tool_name} {basename}", 256)
    if tool_name in ("WebFetch", "WebSearch"):
        url = str(tool_input.get("url") or tool_input.get("query") or "")
        return _truncate(f"{tool_name} {url}", 256)
    # Generic fallback: tool name + a small set of redacted keys
    keys = sorted(k for k in tool_input.keys() if not k.startswith("_"))[:3]
    return _truncate(f"{tool_name}({', '.join(keys)})", 256)


class ClaudeAdapter(ProviderAdapter):
    """PermissionRequest adapter for Claude Code."""

    provider = "claude"

    def parse_hook_input(self, raw: dict[str, Any], cwd_hmac: str | None) -> ParsedHookInput:
        tool_name = str(raw.get("tool_name") or "").strip() or "Unknown"
        tool_input = raw.get("tool_input") or {}
        if not isinstance(tool_input, dict):
            tool_input = {}

        cwd = str(raw.get("cwd") or "")
        cwd_basename = cwd.rsplit("/", 1)[-1] if cwd else ""

        risk = _classify_risk(tool_name, tool_input)
        summary = _summary_for(tool_name, tool_input)

        # Minimised, REDACTED payload for upload. We deliberately drop large
        # fields and never include the transcript / message history.
        redacted_input: dict[str, Any] = {}
        for key, value in tool_input.items():
            if key.startswith("_"):
                continue
            if isinstance(value, str):
                redacted_input[key] = _truncate(_redact(value), 1024)
            elif isinstance(value, (int, float, bool)) or value is None:
                redacted_input[key] = value
            elif isinstance(value, (list, dict)):
                # Don't recurse — flatten to a length hint to keep payload small.
                redacted_input[key] = f"<{type(value).__name__} len={len(value)}>"
            else:
                redacted_input[key] = f"<{type(value).__name__}>"

        payload = {
            "tool_name": tool_name,
            "tool_input": redacted_input,
            "permission_suggestions_count": len(raw.get("permission_suggestions") or []),
        }

        return ParsedHookInput(
            provider=self.provider,
            tool_name=tool_name,
            summary=summary,
            payload=payload,
            risk=risk,
            cwd_basename=cwd_basename[:255],
            cwd_hmac=cwd_hmac,
        )

    def emit_hook_output(self, decision: AdapterDecision, parsed: ParsedHookInput) -> dict[str, Any]:
        # PermissionRequest only supports allow/deny per official docs. There
        # is no "ask" or "abstain" — the only documented fail-closed path is
        # deny+message. Fallback / unknown decisions therefore deny with an
        # explanation directing the user to retry locally so Claude's own
        # permission prompt fires on the next attempt.
        #
        # Per docs `message` is "For deny only" — allow responses must NOT
        # include it (Codex review iter5 P2). The shape branches accordingly.
        decision_obj: dict[str, Any]
        if decision.decision == "approve":
            decision_obj = {"behavior": "allow"}
        elif decision.decision == "deny":
            decision_obj = {
                "behavior": "deny",
                "message": decision.reason or "Denied remotely via CLI Pulse",
            }
        else:
            # fallback / unknown → deny with an explanation pointing the user
            # at the local prompt. PermissionRequest has no "ask" value.
            decision_obj = {
                "behavior": "deny",
                "message": decision.reason or (
                    "Remote approval unavailable. Please retry; CLI Pulse will "
                    "let the local Claude permission prompt run."
                ),
            }

        # Phase 1: NEVER emit permissionUpdates. Always-Allow surface is
        # intentionally not exposed remotely yet.
        return {
            "hookSpecificOutput": {
                "hookEventName": "PermissionRequest",
                "decision": decision_obj,
            }
        }
