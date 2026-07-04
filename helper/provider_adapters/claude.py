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

from typing import Any

# Centralised secret-redaction patterns live in helper/redaction.py so the
# Phase-2 stdout/info uploader in remote_agent.py shares the same regex
# set. We import the module-level helper rather than re-declaring locals.
from redaction import redact as _redact

from .base import AdapterDecision, AdapterRisk, ParsedHookInput, ProviderAdapter


# Tools that read state but don't change it. Approving these remotely is low
# risk — we still let the user approve, but we won't auto-deny them.
_LOW_RISK_TOOLS = {
    "Read", "Glob", "Grep", "WebFetch", "WebSearch",
    "TodoRead", "ListMcpResources",
}

# Substring patterns where whitespace IS the structural signature of the
# danger — fork bombs encode their meaning in the operator layout, and
# `chmod 777 /` / `history -c` are multi-token signatures that only mean
# what they mean as a phrase. Token-splitting would break these matches.
_SUBSTRING_DANGER: tuple[str, ...] = (
    ":(){ :|:& };:",   # fork bomb (whitespace IS the signature)
    "chmod 777 /",     # root chmod 777 (non-root chmod 777 is medium)
    "history -c",      # shell history wipe
)

# Single-token danger keywords — exact equality after whitespace split, so
# `sudoer-config-tool`, `forecast-curl-stats`, etc. don't false-positive on
# substring matches. `dd` is special-cased separately because it's only
# dangerous when paired with the `if=` source-input flag.
_SINGLE_TOKEN_DANGER: frozenset[str] = frozenset({
    "sudo", "mkfs", "shutdown", "reboot", "killall", "kextload",
    "csrutil", "curl", "wget", "ssh", "scp", "rsync",
})

# Future work (Gemini review P3 #9): tool inputs like `cat .env` or
# `cat ~/.aws/credentials` will still pass through summary/payload because
# the *filename* itself is non-secret text. A v2 redactor should match
# sensitive filename patterns (.env, id_rsa, *.pem, credentials.json, ...)
# and strip the surrounding command. Tracked separately, not in Phase 1.


def _truncate(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 1)].rstrip() + "…"


def _is_high_risk_bash(command: str) -> bool:
    """Token-level high-risk classifier for Bash commands.

    Mirrors cli-pulse-desktop v0.7.0 `risk.rs::is_high_risk_bash`
    (cross-team alignment 2026-05-07, Mac M3 P2 backport). The previous
    Mac classifier used naive `tok in command` substring matching, which
    silently failed on whitespace-perturbed forms — `rm  -rf` (double
    space), `rm\\t-rf` (tab), `rm -r -f` (split flags) all evaded the
    `"rm -rf"` literal. Token-based matching is whitespace-tolerant by
    construction: `command.split()` collapses any run of whitespace.

    Logic:
      * Substring scan for patterns whose whitespace IS the signature
        (fork bomb, `chmod 777 /`, `history -c`).
      * Token scan for single-keyword dangers (sudo / mkfs / curl / …).
        Exact equality avoids `sudoer-config-tool` false-positives.
      * `rm` paired with destructive flag clusters — single-token form
        (`rm -rf`, `rm -fr`, `rm -rfv`) AND split-flag form
        (`rm -r -f`, `rm -r --force`). A flag token "contains both r
        and f" satisfies the single-token form; consecutive flag tokens
        collectively satisfying r+f satisfy the split form.
    """
    for s in _SUBSTRING_DANGER:
        if s in command:
            return True

    tokens = command.split()
    if not tokens:
        return False

    for tok in tokens:
        if tok in _SINGLE_TOKEN_DANGER:
            return True
        # `dd` is dangerous when invoked with `if=` (input file). Bare `dd`
        # without args is harmless; treat any `dd` token as suspect only
        # when the command also contains `if=`.
        if tok == "dd" and "if=" in command:
            return True

    # `rm` paired with destructive flags: -rf / -fr / -rfv / -r -f / etc.
    for i, tok in enumerate(tokens):
        if tok != "rm":
            continue
        # Single-token form: next token contains both r and f.
        if i + 1 < len(tokens):
            stripped = tokens[i + 1].lstrip("-")
            if "r" in stripped and "f" in stripped:
                return True
        # Split-flag form: scan consecutive flag tokens after `rm`,
        # collecting r/f flags. Stop at the first non-flag (operand).
        has_r = False
        has_f = False
        for tok2 in tokens[i + 1:]:
            if not tok2.startswith("-"):
                break
            stripped = tok2.lstrip("-")
            if "r" in stripped:
                has_r = True
            if "f" in stripped:
                has_f = True
        if has_r and has_f:
            return True

    return False


def _classify_risk(tool_name: str, tool_input: dict[str, Any]) -> str:
    if tool_name in _LOW_RISK_TOOLS:
        return AdapterRisk.LOW
    if tool_name == "Bash":
        cmd = str(tool_input.get("command", ""))
        if _is_high_risk_bash(cmd):
            return AdapterRisk.HIGH
        return AdapterRisk.MEDIUM
    # Edit / Write / MCP / etc — default medium. WebSearch is in low set above.
    return AdapterRisk.MEDIUM


def _sanitize_url(value: str) -> str:
    """Strip credentials from a URL before it goes into a remote-visible summary:
    drop userinfo (``//user:pass@``), query, and fragment; keep scheme://host/path.
    Non-URLs (e.g. a WebSearch query string) pass through unchanged — the caller
    still runs _redact over the result. The key-name redactor alone misses
    userinfo, ``?token=``, and OAuth ``?code=``, so this closes those. (audit F7.)"""
    try:
        from urllib.parse import urlsplit, urlunsplit
        parts = urlsplit(value)
        if not parts.scheme or not parts.netloc:
            return value
        host = parts.hostname or ""
        if parts.port:
            host = f"{host}:{parts.port}"
        return urlunsplit((parts.scheme, host, parts.path, "", ""))
    except Exception:  # noqa: BLE001 — a summary must never raise
        return value


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
        # F7: sanitize URL creds + run the same redactor as the Bash path — a
        # signed / credential-bearing URL must not leave the device in a summary.
        url = _redact(_sanitize_url(str(tool_input.get("url") or tool_input.get("query") or "")))
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
                # F7: _sanitize_url first (strips URL userinfo/query/fragment the
                # key-name redactor misses); non-URL strings pass through unchanged.
                redacted_input[key] = _truncate(_redact(_sanitize_url(value)), 1024)
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
            # fallback / unknown → deny with an explanation. PermissionRequest
            # has no "ask" value, and there is no documented "delegate to local"
            # shape. The honest path:
            #   * tell the user we couldn't reach the remote channel
            #   * tell them what to do — turn Remote Control off if it's
            #     persistently broken, otherwise re-run the command
            # Phrasing avoids implying that a single retry will magically make
            # the local prompt appear (it won't if Remote Control is still on
            # and the helper is still unreachable).
            decision_obj = {
                "behavior": "deny",
                "message": decision.reason or (
                    "Remote approval unavailable. If this keeps happening, "
                    "open CLI Pulse → Settings → Privacy and turn off "
                    "Remote Control; the local Claude permission prompt "
                    "will then run on your next attempt."
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
