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


def recommended_hook_command(helper_path: Path, python_path: str | None = None) -> str:
    """Return JUST the `command` string the helper installs as a Claude
    Code PermissionRequest hook. Used by both
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
    return f"{py} {helper} remote-approval-hook --provider claude"


def install_claude_hook(
    helper_path: Path,
    *,
    settings_path: Path | None = None,
    python_path: str | None = None,
) -> dict[str, object]:
    """Idempotently merge the CLI Pulse PermissionRequest hook into
    `~/.claude/settings.json`, preserving every other key the user
    has set.

    Behaviour:

      - if the file is missing or empty → write a minimal settings
        object containing just `hooks.PermissionRequest` with our
        command.
      - if the file is parse-broken JSON → raise `ValueError` (do
        NOT clobber the user's data; the operator must fix the file
        manually).
      - if the file already contains `hooks.PermissionRequest` with
        an entry whose `.command` resolves to our helper script →
        no-op (idempotent).
      - if the file contains `hooks.PermissionRequest` with OTHER
        entries → append our entry (do not remove the user's other
        hooks); this is documented as the unsupported case in the
        original print-snippet flow but is the safe default here.
      - otherwise create the missing keys and add our entry.

    Returns a small status dict the CLI command renders for the user:
    `{"settings_path", "action", "previous_command", "new_command"}`.
    `action` is one of `"created" | "added" | "noop" | "replaced"`.
    """
    settings = settings_path or (Path.home() / ".claude" / "settings.json")
    target_command = recommended_hook_command(
        helper_path=helper_path, python_path=python_path,
    )

    # Load existing data if any.
    if settings.exists() and settings.stat().st_size > 0:
        try:
            raw = settings.read_text(encoding="utf-8")
            data = json.loads(raw)
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
    else:
        data = {}

    # Locate / create hooks.PermissionRequest.
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        hooks = {}
    pr = hooks.get("PermissionRequest")
    if not isinstance(pr, list):
        pr = []

    # Detect existing CLI Pulse hook entries. The marker
    # `remote-approval-hook --provider claude` is unique to this
    # codebase — no other Claude PermissionRequest hook would use
    # both that subcommand AND that argument shape, so matching on
    # this string alone is specific enough without false positives.
    #
    # We probe BOTH schema shapes AND check matcher canonicality:
    #
    #   - **Current canonical (matcher: "" + nested hooks)**: each
    #     PermissionRequest entry is `{"matcher": "", "hooks":
    #     [{"type":"command","command":"..."}]}`. The empty-string
    #     matcher means "fire on every PermissionRequest" — this is
    #     the only shape that lets CLI Pulse intercept ALL tool
    #     permission prompts (Bash + Read + Write + …). Anything
    #     else is non-canonical even if the inner command matches
    #     our marker.
    #   - **Narrower matcher (matcher: "Bash" / "Read" / etc.)**:
    #     same nested-hooks structure but the matcher would only
    #     fire for one tool family, so the rest of the structured
    #     approval routing stays broken. Codex iter6 finding: this
    #     must be reported as `replaced`, NOT `noop`, even when the
    #     inner command matches.
    #   - **Legacy flat (no matcher, top-level command)**: each
    #     entry is `{"type":"command","command":"..."}`. Older
    #     versions of this codebase wrote this shape; Claude Code's
    #     current `/doctor` rejects it as malformed (
    #     `hooks.PermissionRequest.0.hooks: Expected array, but
    #     received undefined`). Auto-heal lifts these into the
    #     canonical matcher shape.
    helper_marker = "remote-approval-hook --provider claude"

    def _hook_has_marker(h: object) -> bool:
        return (
            isinstance(h, dict)
            and isinstance(h.get("command"), str)
            and helper_marker in h["command"]
        )

    def _is_cli_pulse_legacy_entry(entry: object) -> bool:
        """Legacy flat shape: top-level `command` field, no nested
        `hooks` array. The whole entry IS our hook (no other hooks
        can be co-resident in this shape).
        """
        return (
            isinstance(entry, dict)
            and not isinstance(entry.get("hooks"), list)
            and isinstance(entry.get("command"), str)
            and helper_marker in entry["command"]
        )

    def _matcher_entry_has_our_hook(entry: object) -> bool:
        """Matcher-shape entry whose nested `hooks` array contains
        our marker. The entry MAY also contain other (non-CLI-Pulse)
        nested hooks — the mixed-entry preservation path below
        surgically removes only our nested hook in that case.
        """
        if not isinstance(entry, dict):
            return False
        nested = entry.get("hooks")
        if not isinstance(nested, list):
            return False
        return any(_hook_has_marker(h) for h in nested)

    def _is_canonical_matcher(entry: object) -> bool:
        """Match-all matcher: exactly the empty string `""`.
        Missing key, `None`, or any non-empty value (`"Bash"`,
        `"Read"`, regex-like strings, etc.) is non-canonical —
        Codex iter6: those would only fire for a subset of
        PermissionRequests and silently break structured approvals
        for the rest, so installer must replace and detector must
        report .notWired.
        """
        return isinstance(entry, dict) and entry.get("matcher") == ""

    def _is_canonical_pure_cli_pulse_entry(entry: object) -> bool:
        """Entry that is EXACTLY our canonical shape: matcher="",
        hooks=[<single CLI Pulse hook>]. Used for the noop-eligibility
        check — anything richer (extra nested hooks, narrower
        matcher) needs auto-heal.
        """
        if not _is_canonical_matcher(entry):
            return False
        nested = entry.get("hooks")
        if not isinstance(nested, list) or len(nested) != 1:
            return False
        return _hook_has_marker(nested[0])

    def _entry_command(entry: object) -> str | None:
        """Pull the helper command string out of either schema shape."""
        if _is_cli_pulse_legacy_entry(entry):
            return entry["command"]
        if _matcher_entry_has_our_hook(entry):
            for h in entry["hooks"]:
                if _hook_has_marker(h):
                    return h["command"]
        return None

    # First-pass scan: count how many entries touch our marker
    # (in either schema shape) and find the previous command (for
    # the status-dict response).
    cli_pulse_touched_count = sum(
        1 for entry in pr
        if _is_cli_pulse_legacy_entry(entry) or _matcher_entry_has_our_hook(entry)
    )
    previous_command: str | None = None
    for entry in pr:
        cmd = _entry_command(entry)
        if cmd is not None:
            previous_command = cmd
            break

    # Noop ONLY when the array contains exactly one CLI-Pulse-related
    # entry AND that entry is the canonical pure shape with the
    # exact target command. Anything else (narrower matcher, legacy
    # shape, mixed nested hooks, duplicate entries, stale command)
    # routes through the auto-heal rebuild path below.
    canonical_pure_indices = [
        i for i, entry in enumerate(pr)
        if _is_canonical_pure_cli_pulse_entry(entry)
        and entry["hooks"][0]["command"] == target_command
    ]
    is_noop = (
        cli_pulse_touched_count == 1
        and len(canonical_pure_indices) == 1
    )

    had_unrelated_entries = any(
        not (_is_cli_pulse_legacy_entry(entry) or _matcher_entry_has_our_hook(entry))
        for entry in pr
    )

    if is_noop:
        action = "noop"
    else:
        # Auto-heal rebuild path. Three guarantees:
        #   1. **Drop legacy flat entries** — they have no nested
        #      hooks list, the entire entry IS our hook, no user
        #      data to preserve.
        #   2. **Surgically remove our nested hook from mixed
        #      matcher entries** — Codex iter6 finding: if the user
        #      put another hook (e.g. an audit hook) in the SAME
        #      matcher entry's nested hooks array as ours, replacing
        #      the whole entry would silently delete their hook.
        #      Instead we filter the nested array to exclude only
        #      the marker-matching entries; if the cleaned array is
        #      empty, the parent entry had nothing else and we drop
        #      it; if non-empty, we preserve the parent entry with
        #      the cleaned nested array (matcher key + any other
        #      sibling keys preserved verbatim).
        #   3. **Append exactly one canonical CLI Pulse entry** at
        #      the end so detection lights up as `.wired` on the
        #      next read.
        new_pr: list[Any] = []
        for entry in pr:
            if _is_cli_pulse_legacy_entry(entry):
                continue
            if _matcher_entry_has_our_hook(entry):
                cleaned_nested = [
                    h for h in entry["hooks"] if not _hook_has_marker(h)
                ]
                if not cleaned_nested:
                    # Whole nested array was CLI Pulse — drop entry.
                    continue
                # Mixed entry: preserve every key except `hooks`,
                # which we replace with the cleaned (CLI-Pulse-free)
                # array. `dict(entry)` shallow-copies so we don't
                # mutate the caller's data.
                preserved = dict(entry)
                preserved["hooks"] = cleaned_nested
                new_pr.append(preserved)
            else:
                # Entry doesn't touch our marker — leave verbatim.
                new_pr.append(entry)
        new_pr.append(_cli_pulse_hook_entry(target_command))
        pr = new_pr

        if previous_command is not None:
            # Pre-existing CLI Pulse hook found in non-canonical
            # form — covers narrower matcher, legacy flat schema,
            # mixed nested, stale command, duplicate entries.
            action = "replaced"
        elif had_unrelated_entries or data:
            # Existing settings file with other content but no
            # CLI Pulse hook yet — we added alongside.
            action = "added"
        else:
            action = "created"

    hooks["PermissionRequest"] = pr
    data["hooks"] = hooks

    if action != "noop":
        # Atomic write — temp file in same dir, then rename.
        # Mode handling (P2 fix from Codex review on 7528084):
        # preserve the existing file's mode if it was already on
        # disk (a 0600 settings.json must NOT be widened to 0644
        # by our install). New files default to 0600 — settings
        # often contain machine-readable hook commands referencing
        # paths under $HOME, and on multi-user systems the
        # safer default is owner-only.
        mode_to_set = 0o600
        try:
            existing_stat = settings.stat()
            mode_to_set = existing_stat.st_mode & 0o777
        except FileNotFoundError:
            pass
        settings.parent.mkdir(parents=True, exist_ok=True)
        tmp = settings.with_suffix(settings.suffix + ".tmp")
        tmp.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
        os.chmod(tmp, mode_to_set)
        tmp.replace(settings)
        # `replace` may preserve the destination's mode on some
        # POSIX implementations (it's syscall-level rename, but
        # mode is on the inode being-replaced, not the new one).
        # Re-chmod the final path to be defensive — same
        # idempotent-mode pattern `local_auth_token.rotate_token`
        # uses for the same reason.
        os.chmod(settings, mode_to_set)

    return {
        "settings_path": str(settings),
        "action": action,
        "previous_command": previous_command,
        "new_command": target_command,
    }
