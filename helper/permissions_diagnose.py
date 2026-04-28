"""Diagnostic module for Claude Code permission rules + hook configuration.

Read-only. Never writes. Surfaces "why does Always Allow keep re-prompting"
in a structured, evidence-based way so users can fix the actual cause
without us silently rewriting their settings files.

Source-of-truth for behaviour: https://code.claude.com/docs/en/settings
(verified 2026-04-29). Key facts encoded here:

  * Rule eval order: deny → ask → allow. First matching rule wins.
  * Scope precedence (high→low): Managed > Local > Project > User.
  * Array settings (`permissions.allow`/`ask`/`deny`) MERGE across
    scopes, then are evaluated in the deny→ask→allow order.
  * "Always Allow" UI button writes the rule somewhere; the docs do
    NOT specify where, but in practice it lands in the most-specific
    scope (Local) which is gitignored and per-project.
  * Rule format: `Tool` or `Tool(specifier)`. e.g. `Bash(npm test)`,
    `Bash(npm test:*)`, `Read(./.env)`.
  * PermissionRequest hooks fire AFTER rule evaluation, only when a
    permission dialog would show (i.e. no allow rule matched).
  * `permissionUpdates` from a PermissionRequest hook output CAN write
    to settings — but Phase 1 deliberately doesn't emit them.

Top reasons "Always Allow" still re-prompts (used by `diagnose`):

  1. **Pattern-too-narrow.** Always Allow saved `Bash(npm test)` but
     the user later runs `npm test:watch` or `npm test --coverage`.
     Different specifier → different rule.
  2. **Wrong scope.** Always Allow saved into `.claude/settings.local.json`
     (gitignored, per-cwd). Open another project, the rule isn't there.
  3. **Higher-precedence deny/ask.** A `deny` or `ask` rule in
     project / local / managed settings overrides a user-level allow.
  4. **Settings rewritten externally.** IDE plugins, CI scripts, or
     `git checkout` of a different branch can clear rules.

We surface these in `diagnose_permissions(...)` as labelled findings.
"""
from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

# Scope precedence per docs: highest first.
_SCOPE_PRECEDENCE = ("managed", "local", "project", "user")

# Tool-name patterns we expect to see in a typical Claude Code session.
# Used to flag suspiciously narrow Always-Allow rules.
_COMMON_BASH_FAMILIES = (
    ("npm",   ("Bash(npm test)", "Bash(npm test:*)", "Bash(npm run *)")),
    ("yarn",  ("Bash(yarn test)", "Bash(yarn *)")),
    ("pnpm",  ("Bash(pnpm test)", "Bash(pnpm *)")),
    ("git",   ("Bash(git status)", "Bash(git diff *)", "Bash(git log *)")),
    ("python",("Bash(python *)", "Bash(python3 *)", "Bash(pytest)", "Bash(pytest *)")),
)


@dataclass
class SettingsFile:
    """One Claude settings file as we found it on disk."""

    scope: str                       # one of _SCOPE_PRECEDENCE
    path: Path
    exists: bool
    parse_error: str | None = None
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def hooks(self) -> dict[str, Any]:
        return self.raw.get("hooks") or {}

    @property
    def permissions(self) -> dict[str, list[str]]:
        p = self.raw.get("permissions") or {}
        # Normalise: every key returns a list, even when missing.
        return {
            "allow": list(p.get("allow") or []),
            "ask":   list(p.get("ask")   or []),
            "deny":  list(p.get("deny")  or []),
        }


@dataclass
class Finding:
    """One diagnostic finding."""

    severity: str                    # info | warn | err
    code: str                        # short stable id, e.g. permissions-conflict
    title: str
    detail: str
    suggestion: str | None = None


@dataclass
class DiagnoseReport:
    """End-to-end diagnostic snapshot."""

    home: Path
    cwd: Path
    settings: dict[str, SettingsFile]
    findings: list[Finding] = field(default_factory=list)
    merged_allow: list[str] = field(default_factory=list)
    merged_ask: list[str] = field(default_factory=list)
    merged_deny: list[str] = field(default_factory=list)
    has_permission_request_hook: bool = False
    has_pre_tool_use_hook: bool = False

    def to_json(self) -> dict[str, Any]:
        return {
            "home": str(self.home),
            "cwd": str(self.cwd),
            "settings": {
                scope: {
                    "path": str(sf.path),
                    "exists": sf.exists,
                    "parse_error": sf.parse_error,
                    "permissions_allow_count": len(sf.permissions["allow"]),
                    "permissions_ask_count":   len(sf.permissions["ask"]),
                    "permissions_deny_count":  len(sf.permissions["deny"]),
                    "hook_event_names": sorted(sf.hooks.keys()),
                }
                for scope, sf in self.settings.items()
            },
            "merged": {
                "allow_count": len(self.merged_allow),
                "ask_count": len(self.merged_ask),
                "deny_count": len(self.merged_deny),
            },
            "has_permission_request_hook": self.has_permission_request_hook,
            "has_pre_tool_use_hook": self.has_pre_tool_use_hook,
            "findings": [
                {
                    "severity": f.severity,
                    "code": f.code,
                    "title": f.title,
                    "detail": f.detail,
                    "suggestion": f.suggestion,
                }
                for f in self.findings
            ],
        }


# ── file loading ──────────────────────────────────────────────


def _load_settings_file(scope: str, path: Path) -> SettingsFile:
    if not path.exists():
        return SettingsFile(scope=scope, path=path, exists=False)
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        return SettingsFile(scope=scope, path=path, exists=True,
                            parse_error=f"unreadable: {exc}")
    try:
        raw = json.loads(text) if text.strip() else {}
    except json.JSONDecodeError as exc:
        return SettingsFile(scope=scope, path=path, exists=True,
                            parse_error=f"invalid JSON: {exc.msg} at line {exc.lineno}")
    if not isinstance(raw, dict):
        return SettingsFile(scope=scope, path=path, exists=True,
                            parse_error="root must be a JSON object")
    return SettingsFile(scope=scope, path=path, exists=True, raw=raw)


def collect_settings(home: Path, cwd: Path) -> dict[str, SettingsFile]:
    """Load all four scopes the docs describe.

    `managed` lives in OS-specific paths the docs reference but we don't
    enumerate every platform here. We probe a handful of plausible
    locations; if none exist, we record absent. This module's job is
    diagnosis, not coverage of every enterprise rollout.
    """
    settings: dict[str, SettingsFile] = {}

    # User scope: ~/.claude/settings.json (most common cross-project rules)
    settings["user"] = _load_settings_file("user", home / ".claude" / "settings.json")

    # Project scope: <cwd>/.claude/settings.json (committed, shared with team)
    settings["project"] = _load_settings_file("project", cwd / ".claude" / "settings.json")

    # Local scope: <cwd>/.claude/settings.local.json (gitignored, per-cwd, where
    # interactive Always-Allow tends to land)
    settings["local"] = _load_settings_file("local", cwd / ".claude" / "settings.local.json")

    # Managed enterprise. Try the most likely place; missing is the common case.
    candidates = (
        Path("/Library/Application Support/ClaudeCode/managed-settings.json"),
        Path("/etc/claude-code/managed-settings.json"),
    )
    managed_path = candidates[0]
    for c in candidates:
        if c.exists():
            managed_path = c
            break
    settings["managed"] = _load_settings_file("managed", managed_path)

    return settings


# ── diagnostic engine ─────────────────────────────────────────


def _merge_arrays(settings: dict[str, SettingsFile], key: str) -> list[str]:
    """Concatenate + dedupe `permissions[key]` across all 4 scopes.

    Per docs: array settings merge across scopes (concatenated +
    deduplicated, not replaced). We preserve the order of first
    appearance in scope precedence (managed → local → project → user).
    """
    seen: set[str] = set()
    out: list[str] = []
    for scope in _SCOPE_PRECEDENCE:
        sf = settings.get(scope)
        if sf is None or not sf.exists or sf.parse_error:
            continue
        for rule in sf.permissions.get(key, []):
            if not isinstance(rule, str):
                continue
            if rule in seen:
                continue
            seen.add(rule)
            out.append(rule)
    return out


def _rule_normalise(rule: str) -> tuple[str, str | None]:
    """Split `Tool(specifier)` into (tool, specifier).

    `Bash(npm test)` → (`Bash`, `npm test`). `Bash` (bare) → (`Bash`, None).
    """
    rule = rule.strip()
    if "(" not in rule or not rule.endswith(")"):
        return rule, None
    tool, _, rest = rule.partition("(")
    spec = rest[:-1]                      # strip the trailing ')'
    return tool.strip(), spec.strip() or None


def find_overlapping_rules(allow: Iterable[str], ask_or_deny: Iterable[str]) -> list[tuple[str, str]]:
    """Return (allow_rule, blocker_rule) pairs where the blocker shares
    the same Tool and either has no specifier (matches all of that tool)
    or has a specifier that's a prefix-match on the allow specifier.

    This is intentionally conservative — Claude Code's own pattern
    matching has wildcard semantics we don't try to replicate here.
    The goal is "loud common conflicts", not full equivalence.
    """
    blockers = [(r, _rule_normalise(r)) for r in ask_or_deny]
    pairs: list[tuple[str, str]] = []
    for a in allow:
        a_tool, a_spec = _rule_normalise(a)
        for blocker_rule, (b_tool, b_spec) in blockers:
            if a_tool != b_tool:
                continue
            # Bare blocker (no specifier) → matches every call to that tool.
            if b_spec is None:
                pairs.append((a, blocker_rule))
                continue
            # Both specified → prefix overlap is the cheap signal.
            if a_spec is not None and (a_spec.startswith(b_spec) or b_spec.startswith(a_spec)):
                pairs.append((a, blocker_rule))
    return pairs


def suggested_rules_for_repo(cwd: Path) -> list[str]:
    """Recommend a small allowlist tailored to the cwd.

    We sniff for npm/yarn/pnpm/python/git markers and suggest the
    broadest sensible patterns. Caller decides what to actually apply.
    Never writes.
    """
    sugg: list[str] = []
    if (cwd / "package.json").exists():
        if (cwd / "pnpm-lock.yaml").exists():
            sugg += ["Bash(pnpm test)", "Bash(pnpm run *)", "Bash(pnpm install *)"]
        elif (cwd / "yarn.lock").exists():
            sugg += ["Bash(yarn test)", "Bash(yarn *)"]
        else:
            sugg += ["Bash(npm test)", "Bash(npm test:*)", "Bash(npm run *)", "Bash(npm install *)"]
    if (cwd / "pyproject.toml").exists() or (cwd / "requirements.txt").exists():
        sugg += ["Bash(pytest)", "Bash(pytest *)", "Bash(python *)", "Bash(python3 *)"]
    if (cwd / ".git").exists():
        sugg += ["Bash(git status)", "Bash(git diff *)", "Bash(git log *)", "Bash(git branch *)"]
    return sugg


# ── orchestration ─────────────────────────────────────────────


def diagnose(home: Path | None = None, cwd: Path | None = None) -> DiagnoseReport:
    """Run a full read-only diagnosis of Claude Code permissions
    in the user's environment. Pure function: no writes, no env mutation.
    """
    home = home or Path.home()
    cwd = cwd or Path.cwd()

    settings = collect_settings(home, cwd)
    findings: list[Finding] = []

    # ── findings: invalid JSON ────────────────────────────────
    for scope in _SCOPE_PRECEDENCE:
        sf = settings[scope]
        if sf.exists and sf.parse_error:
            findings.append(Finding(
                severity="err",
                code="settings-parse-error",
                title=f"{scope} settings won't parse",
                detail=f"{sf.path}: {sf.parse_error}",
                suggestion="Open the file, fix the JSON, and re-run. Until then, "
                           "Claude Code will silently ignore this scope's rules.",
            ))

    # ── merged rules ──────────────────────────────────────────
    merged_allow = _merge_arrays(settings, "allow")
    merged_ask   = _merge_arrays(settings, "ask")
    merged_deny  = _merge_arrays(settings, "deny")

    # ── findings: deny/ask overrides allow ───────────────────
    overrides_by_deny = find_overlapping_rules(merged_allow, merged_deny)
    for allow_rule, deny_rule in overrides_by_deny:
        findings.append(Finding(
            severity="warn",
            code="allow-overridden-by-deny",
            title=f"`{deny_rule}` overrides your `{allow_rule}` allow",
            detail=("Claude Code evaluates permission rules deny → ask → allow. "
                    "When the same tool call matches both, deny wins, so the "
                    "Always-Allow you clicked is never honoured."),
            suggestion=f"Remove or narrow `{deny_rule}` if you actually want "
                       f"`{allow_rule}` to apply.",
        ))
    overrides_by_ask = find_overlapping_rules(merged_allow, merged_ask)
    for allow_rule, ask_rule in overrides_by_ask:
        findings.append(Finding(
            severity="warn",
            code="allow-overridden-by-ask",
            title=f"`{ask_rule}` overrides your `{allow_rule}` allow",
            detail=("Same tool call matches an `ask` rule and an `allow` rule. "
                    "Per docs, ask wins over allow — Claude will keep prompting."),
            suggestion=f"Remove or narrow `{ask_rule}` if you don't want to be "
                       f"prompted again.",
        ))

    # ── findings: Always-Allow saved at the wrong scope ──────
    # If we see allow rules ONLY in `local` (gitignored, per-cwd) and
    # nothing in `user` or `project`, the user is likely re-prompted in
    # other projects.
    sf_user    = settings["user"]
    sf_project = settings["project"]
    sf_local   = settings["local"]
    user_allow_count    = len(sf_user.permissions["allow"])    if sf_user.exists    else 0
    project_allow_count = len(sf_project.permissions["allow"]) if sf_project.exists else 0
    local_allow_count   = len(sf_local.permissions["allow"])   if sf_local.exists   else 0
    if local_allow_count > 0 and user_allow_count == 0 and project_allow_count == 0:
        findings.append(Finding(
            severity="warn",
            code="allow-only-in-local-scope",
            title="Always-Allow rules live only in .claude/settings.local.json",
            detail=("That file is gitignored and per-cwd. Open Claude Code from "
                    "a different project and you'll re-prompt for the same "
                    "tool calls — the rule won't apply outside this directory."),
            suggestion="If you want rules to apply across projects, copy the "
                       "allow list to ~/.claude/settings.json (user scope) or "
                       "to .claude/settings.json (project scope, committed).",
        ))

    # ── findings: pattern-too-narrow ─────────────────────────
    # Look for Bash allow rules that don't end with `*` or `:*` — these
    # only match the literal command. A user who clicked Always Allow
    # on `Bash(npm test)` will re-prompt for `Bash(npm test:watch)`.
    narrow_bash = [
        r for r in merged_allow
        if r.startswith("Bash(") and r.endswith(")") and not r.rstrip(")").endswith("*")
    ]
    if narrow_bash:
        findings.append(Finding(
            severity="info",
            code="bash-allow-pattern-too-narrow",
            title=f"{len(narrow_bash)} Bash allow rule(s) are exact-match only",
            detail=("Rules like `Bash(npm test)` only match that exact command "
                    "string. `npm test:watch`, `npm test --coverage`, etc. "
                    "will still trigger a permission prompt. Examples in your "
                    f"settings: {', '.join(narrow_bash[:3])}."),
            suggestion="Replace exact-match rules with wildcards where safe, "
                       "e.g. `Bash(npm test:*)` covers `npm test:watch` and "
                       "`npm test:unit`; `Bash(npm test*)` also covers "
                       "`npm test --coverage`.",
        ))

    # ── hook detection ────────────────────────────────────────
    has_pr_hook  = False
    has_pre_hook = False
    for sf in settings.values():
        if not sf.exists or sf.parse_error:
            continue
        hooks = sf.hooks
        if "PermissionRequest" in hooks and hooks["PermissionRequest"]:
            has_pr_hook = True
        if "PreToolUse" in hooks and hooks["PreToolUse"]:
            has_pre_hook = True

    if not has_pr_hook:
        findings.append(Finding(
            severity="info",
            code="cli-pulse-hook-not-installed",
            title="CLI Pulse remote-approval hook not configured",
            detail=("None of your Claude settings.json files have a "
                    "PermissionRequest hook. CLI Pulse Remote Approvals only "
                    "fires when this hook is wired in."),
            suggestion="See helper/REMOTE_APPROVAL_SETUP.md for the JSON "
                       "snippet to add to ~/.claude/settings.json. Run "
                       "`remote-approvals print-claude-hook-config` for the "
                       "exact entry tailored to this machine.",
        ))

    return DiagnoseReport(
        home=home,
        cwd=cwd,
        settings=settings,
        findings=findings,
        merged_allow=merged_allow,
        merged_ask=merged_ask,
        merged_deny=merged_deny,
        has_permission_request_hook=has_pr_hook,
        has_pre_tool_use_hook=has_pre_hook,
    )


def render_text_report(report: DiagnoseReport) -> str:
    """Pretty-print the diagnose report for `helper print` consumption.

    The output contains local filesystem paths and verbatim entries from
    `permissions.allow` / `ask` / `deny` (which can themselves include
    paths and shell command fragments). The header below warns the user
    not to paste it publicly without redaction. The diagnose flow itself
    is local-only and never uploads anywhere.
    """
    lines: list[str] = []
    lines.append("CLI Pulse — Claude Code permission diagnosis")
    lines.append("  Output may contain local paths and command patterns from")
    lines.append("  your Always-Allow history. Read-only — nothing is uploaded.")
    lines.append("  Redact before pasting in a public bug report or chat.")
    lines.append("")
    lines.append(f"  cwd:  {report.cwd}")
    lines.append(f"  home: {report.home}")
    lines.append("")
    lines.append("Settings files:")
    for scope in _SCOPE_PRECEDENCE:
        sf = report.settings[scope]
        if not sf.exists:
            lines.append(f"  [{scope:>7}] {sf.path}  (missing)")
            continue
        if sf.parse_error:
            lines.append(f"  [{scope:>7}] {sf.path}  (PARSE ERROR: {sf.parse_error})")
            continue
        p = sf.permissions
        lines.append(
            f"  [{scope:>7}] {sf.path}  "
            f"allow={len(p['allow'])} ask={len(p['ask'])} deny={len(p['deny'])} "
            f"hooks={sorted(sf.hooks.keys()) or '[]'}"
        )
    lines.append("")
    lines.append(
        f"Merged rule counts (precedence: deny > ask > allow): "
        f"deny={len(report.merged_deny)} ask={len(report.merged_ask)} allow={len(report.merged_allow)}"
    )
    lines.append("")
    if report.findings:
        lines.append(f"{len(report.findings)} finding(s):")
        for i, f in enumerate(report.findings, start=1):
            lines.append(f"  [{i}] [{f.severity.upper():>4}] {f.title}")
            lines.append(f"        code: {f.code}")
            for paragraph in f.detail.split("\n"):
                lines.append(f"        {paragraph}")
            if f.suggestion:
                lines.append(f"        suggestion: {f.suggestion}")
    else:
        lines.append("No findings — Claude Code permission state looks consistent.")
    return "\n".join(lines)


def recommended_hook_config_snippet(helper_path: Path, python_path: str | None = None) -> str:
    """Return a JSON snippet to paste into ~/.claude/settings.json.

    `helper_path` should be the absolute path to cli_pulse_helper.py.
    `python_path` defaults to whatever the user's python3 is on PATH;
    callers can pass a specific interpreter if they want.
    """
    py = python_path or "python3"
    cmd = f"{py} {helper_path} remote-approval-hook --provider claude"
    snippet = {
        "hooks": {
            "PermissionRequest": [
                {
                    "type": "command",
                    "command": cmd,
                }
            ]
        }
    }
    return json.dumps(snippet, indent=2)
