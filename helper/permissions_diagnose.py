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
import shlex
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

    Schema: each PermissionRequest entry is a matcher object with
    a nested `hooks` array (per Claude Code's current contract,
    surfaced by `claude /doctor`). The flat
    `[{"type":"command","command":"..."}]` shape used by older
    docs is rejected at runtime — Claude Code logs
    `hooks.PermissionRequest.0.hooks: Expected array, but
    received undefined` and silently never invokes the hook.
    Empty matcher matches every tool name.
    """
    cmd = recommended_hook_command(helper_path=helper_path, python_path=python_path)
    snippet = {
        "hooks": {
            "PermissionRequest": [
                _cli_pulse_hook_entry(cmd)
            ]
        }
    }
    return json.dumps(snippet, indent=2)


def _cli_pulse_hook_entry(command: str) -> dict[str, Any]:
    """Build the matcher-shape hook entry for `~/.claude/settings.json`.

    Single source of truth used by both
    `recommended_hook_config_snippet` (print path) and
    `install_claude_hook` (merge path) so the two can never drift
    on schema details.
    """
    return {
        "matcher": "",
        "hooks": [
            {"type": "command", "command": command}
        ],
    }


def recommended_hook_command(
    helper_path: Path, python_path: str | None = None, provider: str = "claude",
) -> str:
    """Return JUST the `command` string the helper installs as a `provider`
    approval hook (claude | codex). Used by both
    `recommended_hook_config_snippet` (for the print path) and
    `install_claude_hook` (for the merge path) so the two surfaces
    can never drift.

    Both `python_path` and `helper_path` are run through
    `shlex.quote` because Claude Code shell-parses the command
    string. Without quoting, a helper checkout living under a path
    with spaces (e.g. `~/Documents/cli pulse/helper/cli_pulse_helper.py`,
    which is the dev layout in this repo) would be split by the
    shell into multiple argv entries — Python would then try to
    run a non-existent path and the hook would silently fail.

    The unquoted form was a real bug Codex caught after the
    initial Stage 1 commit. Pinned by
    `test_install_claude_hook_quotes_paths_with_spaces`.
    """
    py = shlex.quote(python_path or "python3")
    helper = shlex.quote(str(helper_path))
    return f"{py} {helper} {_marker_for(provider)}"


# M1: the CLI Pulse hook is installed under BOTH `PermissionRequest` (fires only
# when a permission dialog would show) AND `PreToolUse` (fires for EVERY tool
# call — the always-present lever on a broad-allowlist machine). The command +
# entry shape is identical for both; only the event key differs. `remote_hook`
# reads `hook_event_name` to emit the right output shape per event.
_CLI_PULSE_HOOK_EVENTS = ("PermissionRequest", "PreToolUse")

# The marker `remote-approval-hook --provider <p>` is unique to this codebase —
# no other hook would use both that subcommand AND that argument shape, so
# matching on this string alone is specific enough without false positives. The
# provider suffix makes it provider-SPECIFIC: a claude install must never detect,
# heal, or remove a codex entry (and vice versa). `_HELPER_MARKER` stays the
# claude marker so the shipped claude callers + their default args are unchanged.
def _marker_for(provider: str) -> str:
    return f"remote-approval-hook --provider {provider}"


_HELPER_MARKER = _marker_for("claude")


def _hook_has_marker(h: object, marker: str = _HELPER_MARKER) -> bool:
    return (
        isinstance(h, dict)
        and isinstance(h.get("command"), str)
        and marker in h["command"]
    )


def _is_cli_pulse_legacy_entry(entry: object, marker: str = _HELPER_MARKER) -> bool:
    """Legacy flat shape: top-level `command` field, no nested `hooks` array.
    The whole entry IS our hook (no other hooks can be co-resident)."""
    return (
        isinstance(entry, dict)
        and not isinstance(entry.get("hooks"), list)
        and isinstance(entry.get("command"), str)
        and marker in entry["command"]
    )


def _matcher_entry_has_our_hook(entry: object, marker: str = _HELPER_MARKER) -> bool:
    """Matcher-shape entry whose nested `hooks` array contains our marker. The
    entry MAY also contain other (non-CLI-Pulse) nested hooks — the mixed-entry
    preservation path surgically removes only ours."""
    if not isinstance(entry, dict):
        return False
    nested = entry.get("hooks")
    if not isinstance(nested, list):
        return False
    return any(_hook_has_marker(h, marker) for h in nested)


def _is_canonical_matcher(entry: object) -> bool:
    """Match-all matcher: exactly the empty string. Missing key / None / any
    non-empty value is non-canonical (would only fire for a subset)."""
    return isinstance(entry, dict) and entry.get("matcher") == ""


def _is_canonical_pure_cli_pulse_entry(entry: object, marker: str = _HELPER_MARKER) -> bool:
    """Entry that is EXACTLY our canonical shape: matcher="", hooks=[<single CLI
    Pulse hook with type=command>]. Used for the noop-eligibility check.

    The `type == "command"` requirement matters: Claude Code AND Codex only
    execute `command` hooks, so a marker-bearing entry with a non-command type
    (e.g. a hand-edited `"type": "prompt"`, or a missing `type`) is INERT. It
    must NOT count as already-correct — otherwise reinstall reports `noop` and
    never heals it. `_matcher_entry_has_our_hook` still matches it on the marker
    alone, so the merge path strips the inert hook and rewrites the canonical
    command entry (review: codex)."""
    if not _is_canonical_matcher(entry):
        return False
    nested = entry.get("hooks")
    if not isinstance(nested, list) or len(nested) != 1:
        return False
    hook = nested[0]
    return _hook_has_marker(hook, marker) and hook.get("type") == "command"


def _entry_command(entry: object, marker: str = _HELPER_MARKER) -> str | None:
    """Pull the helper command string out of either schema shape."""
    if _is_cli_pulse_legacy_entry(entry, marker):
        return entry["command"]
    if _matcher_entry_has_our_hook(entry, marker):
        for h in entry["hooks"]:
            if _hook_has_marker(h, marker):
                return h["command"]
    return None


def _merge_cli_pulse_event(
    existing: object, target_command: str, *, file_had_data: bool,
    marker: str = _HELPER_MARKER,
) -> tuple[list[Any], str, str | None]:
    """Idempotently merge one CLI Pulse hook entry into a single event's list
    (e.g. `hooks["PreToolUse"]`). Pure — returns `(new_list, action,
    previous_command)`, mutating nothing. Same auto-heal semantics the shipped
    PermissionRequest install had (Codex iter6 hardening): drop legacy flat
    entries, surgically strip our nested hook from mixed matcher entries
    (preserving the user's co-resident hooks), and append exactly one canonical
    entry. `action` ∈ noop | replaced | added | created. `marker` scopes
    detection to one provider (claude vs codex)."""
    pr = existing if isinstance(existing, list) else []

    cli_pulse_touched_count = sum(
        1 for entry in pr
        if _is_cli_pulse_legacy_entry(entry, marker) or _matcher_entry_has_our_hook(entry, marker)
    )
    previous_command: str | None = None
    for entry in pr:
        cmd = _entry_command(entry, marker)
        if cmd is not None:
            previous_command = cmd
            break

    canonical_pure_indices = [
        i for i, entry in enumerate(pr)
        if _is_canonical_pure_cli_pulse_entry(entry, marker)
        and entry["hooks"][0]["command"] == target_command
    ]
    is_noop = cli_pulse_touched_count == 1 and len(canonical_pure_indices) == 1
    had_unrelated_entries = any(
        not (_is_cli_pulse_legacy_entry(entry, marker) or _matcher_entry_has_our_hook(entry, marker))
        for entry in pr
    )

    if is_noop:
        return list(pr), "noop", previous_command

    new_pr: list[Any] = []
    for entry in pr:
        if _is_cli_pulse_legacy_entry(entry, marker):
            continue
        if _matcher_entry_has_our_hook(entry, marker):
            cleaned_nested = [h for h in entry["hooks"] if not _hook_has_marker(h, marker)]
            if not cleaned_nested:
                continue
            preserved = dict(entry)
            preserved["hooks"] = cleaned_nested
            new_pr.append(preserved)
        else:
            new_pr.append(entry)
    new_pr.append(_cli_pulse_hook_entry(target_command))

    if previous_command is not None:
        action = "replaced"
    elif had_unrelated_entries or file_had_data:
        action = "added"
    else:
        action = "created"
    return new_pr, action, previous_command


def _strip_cli_pulse_from_event(
    existing: object, marker: str = _HELPER_MARKER,
) -> tuple[list[Any], int]:
    """Remove every CLI Pulse hook from one event's list (uninstall). Preserves
    the user's co-resident hooks in mixed matcher entries. Returns `(new_list,
    removed_count)`. `marker` scopes removal to one provider."""
    pr = existing if isinstance(existing, list) else []
    new_pr: list[Any] = []
    removed = 0
    for entry in pr:
        if _is_cli_pulse_legacy_entry(entry, marker):
            removed += 1
            continue
        if _matcher_entry_has_our_hook(entry, marker):
            cleaned_nested = [h for h in entry["hooks"] if not _hook_has_marker(h, marker)]
            removed += len(entry["hooks"]) - len(cleaned_nested)
            if not cleaned_nested:
                continue
            preserved = dict(entry)
            preserved["hooks"] = cleaned_nested
            new_pr.append(preserved)
        else:
            new_pr.append(entry)
    return new_pr, removed


def _write_settings_atomic(settings: Path, data: dict[str, Any]) -> None:
    """Atomic settings write preserving the existing file's mode (a 0600
    settings.json must NOT be widened); new files default to 0600."""
    mode_to_set = 0o600
    try:
        mode_to_set = settings.stat().st_mode & 0o777
    except FileNotFoundError:
        pass
    settings.parent.mkdir(parents=True, exist_ok=True)
    tmp = settings.with_suffix(settings.suffix + ".tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    os.chmod(tmp, mode_to_set)
    tmp.replace(settings)
    os.chmod(settings, mode_to_set)


def _load_settings_or_raise(settings: Path) -> dict[str, Any]:
    """Load a settings.json object, or {} if absent/empty. Raises ValueError on
    malformed / non-object JSON (NEVER clobbers the user's data)."""
    if settings.exists() and settings.stat().st_size > 0:
        try:
            data = json.loads(settings.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(
                f"refusing to overwrite malformed JSON at {settings}: {exc.msg}. "
                "Please fix the file by hand and rerun this command."
            ) from exc
        if not isinstance(data, dict):
            raise ValueError(
                f"refusing to overwrite non-object JSON at {settings} "
                f"(got {type(data).__name__}). The file must be a JSON object."
            )
        return data
    return {}


def _aggregate_action(actions: list[str], *, file_had_data: bool) -> str:
    """Combine per-event actions into one status for the UI."""
    s = set(actions)
    if s == {"noop"}:
        return "noop"
    if "replaced" in s:
        return "replaced"
    if not file_had_data and "added" not in s and "noop" not in s:
        return "created"
    return "added"


def install_claude_hook(
    helper_path: Path,
    *,
    settings_path: Path | None = None,
    python_path: str | None = None,
) -> dict[str, object]:
    """Idempotently merge the CLI Pulse hook into BOTH `hooks.PermissionRequest`
    AND `hooks.PreToolUse` in `~/.claude/settings.json`, preserving every other
    key the user has set. (M1: PreToolUse is the always-present lever — it fires
    for every tool call even when a broad allowlist suppresses PermissionRequest.
    Both events run the same command; `remote_hook` reads `hook_event_name` to
    emit the right shape.)

    Behaviour (applied per event):

      - missing/empty file → create it with both events wired.
      - parse-broken JSON → raise `ValueError` (never clobber the user's data).
      - an event already wired with our EXACT canonical entry → that event is a
        no-op; the OTHER event is still added if missing.
      - an event with OTHER entries → append ours (preserve the user's hooks).
      - a stale / narrower-matcher / legacy-flat CLI Pulse entry → auto-heal
        (surgically strip ours from mixed entries, then append one canonical).

    Returns `{"settings_path", "action", "previous_command", "new_command",
    "events": {<event>: <per-event action>}}`. `action` is the aggregate
    (`"created" | "added" | "noop" | "replaced"`); `events` gives the detail.
    """
    return _install_hook(
        helper_path, provider="claude",
        default_settings=Path.home() / ".claude" / "settings.json",
        settings_path=settings_path, python_path=python_path,
    )


def _install_hook(
    helper_path: Path, *, provider: str, default_settings: Path,
    settings_path: Path | None = None, python_path: str | None = None,
) -> dict[str, object]:
    """Provider-generic hook install (claude → ~/.claude/settings.json, codex →
    ~/.codex/hooks.json — the two files share the exact `{"hooks": {<event>:
    [...]}}` structure). Merges our canonical entry into BOTH events with the
    reviewed auto-heal / mixed-entry-preservation semantics, scoped to this
    provider's marker so it never touches the OTHER provider's hooks."""
    settings = settings_path or default_settings
    marker = _marker_for(provider)
    target_command = recommended_hook_command(
        helper_path=helper_path, python_path=python_path, provider=provider,
    )

    data = _load_settings_or_raise(settings)   # raises on malformed/non-object
    file_had_data = bool(data)

    # Anti-clobber (review: codex): a present-but-malformed `hooks` structure may
    # carry REAL user hook data — e.g. a user who mistakenly put the event array
    # directly at `hooks` (`"hooks": [ {matcher…} ]`) instead of under an event
    # key. Silently coercing to `{}` and writing would DISCARD it. Refuse instead,
    # mirroring `_load_settings_or_raise`'s never-overwrite contract for the root.
    if "hooks" in data and not isinstance(data["hooks"], dict):
        raise ValueError(
            "settings 'hooks' is present but is not a JSON object "
            f"(got {type(data['hooks']).__name__}); refusing to overwrite — fix it by hand"
        )
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    for event in _CLI_PULSE_HOOK_EVENTS:
        if event in hooks and not isinstance(hooks[event], list):
            raise ValueError(
                f"settings hooks[{event!r}] is present but is not a JSON array "
                f"(got {type(hooks[event]).__name__}); refusing to overwrite — fix it by hand"
            )

    actions: list[str] = []
    previous_command: str | None = None
    for event in _CLI_PULSE_HOOK_EVENTS:
        new_list, action, prev = _merge_cli_pulse_event(
            hooks.get(event), target_command, file_had_data=file_had_data, marker=marker,
        )
        hooks[event] = new_list
        actions.append(action)
        # Report `previous` ONLY from an event we actually REPLACED (review: codex).
        if action == "replaced" and prev is not None and previous_command is None:
            previous_command = prev

    data["hooks"] = hooks
    aggregate = _aggregate_action(actions, file_had_data=file_had_data)

    if aggregate != "noop":
        _write_settings_atomic(settings, data)

    return {
        "settings_path": str(settings),
        "action": aggregate,
        "previous_command": previous_command,
        "new_command": target_command,
        "events": {ev: actions[i] for i, ev in enumerate(_CLI_PULSE_HOOK_EVENTS)},
    }


def install_codex_hook(
    helper_path: Path,
    *,
    settings_path: Path | None = None,
    python_path: str | None = None,
) -> dict[str, object]:
    """Install the CLI Pulse hook into `~/.codex/hooks.json` (both events). Codex
    hooks are Claude-compatible — the JSON file has the byte-identical `{"hooks":
    {"PermissionRequest": [...], "PreToolUse": [...]}}` structure — so this reuses
    the exact claude install machinery, scoped to the `--provider codex` marker.
    A standalone hooks.json is additive to the user's config.toml (Codex loads
    all matching hooks; higher layers don't replace lower ones).

    ⚠️ One-time trust: Codex requires the user to review + trust a non-managed
    command hook via `/hooks` in the TUI (hash-pinned) BEFORE it runs. This CANNOT
    be automated — the caller MUST instruct the user to run `/hooks` once.

    Return shape = `install_claude_hook`'s, PLUS two codex-only fields that make
    the required manual step self-describing so EVERY consumer (CLI, UDS, a future
    Swift client) can render it instead of relying on out-of-band docs (review:
    codex): `requires_manual_trust: True` and `trust_command: "/hooks"`. The write
    succeeded, but the hook stays INERT until the user completes the trust."""
    result = _install_hook(
        helper_path, provider="codex",
        default_settings=Path.home() / ".codex" / "hooks.json",
        settings_path=settings_path, python_path=python_path,
    )
    result["requires_manual_trust"] = True
    result["trust_command"] = "/hooks"
    return result


def uninstall_claude_hook(
    *, settings_path: Path | None = None,
) -> dict[str, object]:
    """Remove EVERY CLI Pulse hook (both PermissionRequest and PreToolUse) from
    `~/.claude/settings.json`, preserving the user's own hooks. The reversible
    other half of the opt-in (design-doc M1: "one-click uninstall, never
    silent"). Idempotent — a `noop` when nothing is installed.

      - malformed / non-object JSON → `ValueError` (never clobber).
      - surgically strips our marker from mixed matcher entries (keeps the
        user's co-resident hooks); drops an event array that becomes empty, and
        the `hooks` key if it becomes empty.

    Returns `{"settings_path", "action", "removed", "events"}` where `action`
    is `"removed" | "noop"` and `removed` is the total hook count deleted.
    """
    return _uninstall_hook(
        provider="claude",
        default_settings=Path.home() / ".claude" / "settings.json",
        settings_path=settings_path,
    )


def _uninstall_hook(
    *, provider: str, default_settings: Path, settings_path: Path | None = None,
) -> dict[str, object]:
    """Provider-generic hook uninstall. Surgically strips ONLY this provider's
    marker from both events (keeps the user's co-resident hooks AND the OTHER
    provider's hooks if they somehow share a file), dropping emptied arrays and
    the `hooks` key when they become empty."""
    settings = settings_path or default_settings
    marker = _marker_for(provider)
    if not (settings.exists() and settings.stat().st_size > 0):
        return {"settings_path": str(settings), "action": "noop", "removed": 0,
                "events": {}}

    data = _load_settings_or_raise(settings)
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return {"settings_path": str(settings), "action": "noop", "removed": 0,
                "events": {}}

    per_event: dict[str, int] = {}
    total_removed = 0
    for event in _CLI_PULSE_HOOK_EVENTS:
        if event not in hooks:
            continue
        new_list, removed = _strip_cli_pulse_from_event(hooks.get(event), marker=marker)
        if removed == 0:
            continue
        per_event[event] = removed
        total_removed += removed
        if new_list:
            hooks[event] = new_list
        else:
            # Event array is now empty (only held our hooks) → drop the key so
            # we don't leave `"PreToolUse": []` litter behind.
            del hooks[event]

    if total_removed == 0:
        return {"settings_path": str(settings), "action": "noop", "removed": 0,
                "events": {}}

    if hooks:
        data["hooks"] = hooks
    else:
        # Whole hooks object was ours → drop it entirely.
        data.pop("hooks", None)
    _write_settings_atomic(settings, data)

    return {
        "settings_path": str(settings),
        "action": "removed",
        "removed": total_removed,
        "events": per_event,
    }


def uninstall_codex_hook(
    *, settings_path: Path | None = None,
) -> dict[str, object]:
    """Remove EVERY CLI Pulse hook (both events) from `~/.codex/hooks.json`,
    preserving the user's own hooks. Reversible other half of the Codex opt-in.
    Idempotent — `noop` when nothing is installed. Same return shape as
    `uninstall_claude_hook`."""
    return _uninstall_hook(
        provider="codex",
        default_settings=Path.home() / ".codex" / "hooks.json",
        settings_path=settings_path,
    )
