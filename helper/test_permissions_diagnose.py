"""Tests for the permissions_diagnose read-only Claude config inspector.

These tests construct fake `~/.claude/settings.json` and `.claude/settings.json`
files in a tmp dir and verify each finding fires (or doesn't) on the right
shape. No real user file is read; no mutation anywhere — except for the
`install_claude_hook` tests at the bottom of this file, which verify the
ONE intentional mutation point added in PR #18 (writing into a tmp_path
copy of `~/.claude/settings.json`, never the real one).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

# Make `helper/` importable when pytest runs from the repo root.
HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import permissions_diagnose as pd  # noqa: E402


def _write(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


# ── settings file loading ────────────────────────────────────


def test_collect_settings_handles_missing_files(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    settings = pd.collect_settings(home, cwd)
    assert set(settings.keys()) == {"user", "project", "local", "managed"}
    for sf in settings.values():
        assert sf.exists is False
        assert sf.parse_error is None


def test_collect_settings_invalid_json_yields_parse_error(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    bad = home / ".claude" / "settings.json"
    bad.parent.mkdir(parents=True)
    bad.write_text("{not valid json", encoding="utf-8")
    settings = pd.collect_settings(home, cwd)
    assert settings["user"].exists
    assert settings["user"].parse_error is not None
    assert "JSON" in settings["user"].parse_error


def test_collect_settings_root_must_be_object(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    bad = home / ".claude" / "settings.json"
    bad.parent.mkdir(parents=True)
    bad.write_text("[]", encoding="utf-8")
    settings = pd.collect_settings(home, cwd)
    assert settings["user"].parse_error is not None
    assert "object" in settings["user"].parse_error.lower()


# ── rule normalisation + overlap detection ──────────────────


def test_rule_normalise_bare_tool():
    assert pd._rule_normalise("Bash") == ("Bash", None)


def test_rule_normalise_with_specifier():
    assert pd._rule_normalise("Bash(npm test:*)") == ("Bash", "npm test:*")


def test_find_overlapping_rules_bare_blocker_matches_all():
    pairs = pd.find_overlapping_rules(
        allow=["Bash(npm test)"],
        ask_or_deny=["Bash"],
    )
    assert pairs == [("Bash(npm test)", "Bash")]


def test_find_overlapping_rules_specifier_prefix_match():
    pairs = pd.find_overlapping_rules(
        allow=["Bash(npm test:watch)"],
        ask_or_deny=["Bash(npm test)"],
    )
    assert ("Bash(npm test:watch)", "Bash(npm test)") in pairs


def test_find_overlapping_rules_different_tool_no_match():
    pairs = pd.find_overlapping_rules(
        allow=["Bash(npm test)"],
        ask_or_deny=["Read(./.env)"],
    )
    assert pairs == []


# ── merged arrays ───────────────────────────────────────────


def test_merge_arrays_concatenates_and_dedupes(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(git status)", "Bash(npm test)"]}})
    _write(cwd / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test)", "Read(./README.md)"]}})
    settings = pd.collect_settings(home, cwd)
    merged = pd._merge_arrays(settings, "allow")
    # Order: managed → local → project → user. local missing, project before user.
    # Dedupe keeps first occurrence.
    assert merged == [
        "Bash(npm test)",          # from project
        "Read(./README.md)",       # from project
        "Bash(git status)",        # from user (Bash(npm test) already seen)
    ]


# ── findings ───────────────────────────────────────────────


def test_diagnose_flags_deny_overriding_allow(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(curl *)"]}})
    _write(cwd / ".claude" / "settings.json",
           {"permissions": {"deny": ["Bash(curl *)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "allow-overridden-by-deny" in codes


def test_diagnose_flags_ask_overriding_allow(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(cwd / ".claude" / "settings.json",
           {"permissions": {
               "allow": ["Bash(npm test)"],
               "ask":   ["Bash(npm test)"],
           }})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "allow-overridden-by-ask" in codes


def test_diagnose_flags_allow_only_in_local_scope(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    # Allow ONLY in local; user + project absent.
    _write(cwd / ".claude" / "settings.local.json",
           {"permissions": {"allow": ["Bash(npm test)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "allow-only-in-local-scope" in codes


def test_diagnose_does_not_flag_local_when_user_also_has_allow(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(git *)"]}})
    _write(cwd / ".claude" / "settings.local.json",
           {"permissions": {"allow": ["Bash(npm test)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "allow-only-in-local-scope" not in codes


def test_diagnose_flags_narrow_bash_pattern(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    # `Bash(npm test)` is exact-match — `npm test:watch` will re-prompt.
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "bash-allow-pattern-too-narrow" in codes


def test_diagnose_does_not_flag_wildcarded_bash(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test:*)", "Bash(npm run *)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "bash-allow-pattern-too-narrow" not in codes


def test_diagnose_flags_missing_hook(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test:*)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "cli-pulse-hook-not-installed" in codes
    assert report.has_permission_request_hook is False


def test_diagnose_detects_existing_hook(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {
               "hooks": {
                   "PermissionRequest": [
                       {"type": "command", "command": "/path/to/cli_pulse_helper.py remote-approval-hook --provider claude"}
                   ]
               },
           })
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "cli-pulse-hook-not-installed" not in codes
    assert report.has_permission_request_hook is True


def test_diagnose_flags_parse_error(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    bad = cwd / ".claude" / "settings.json"
    bad.parent.mkdir(parents=True)
    bad.write_text("{ not valid", encoding="utf-8")
    report = pd.diagnose(home=home, cwd=cwd)
    codes = [f.code for f in report.findings]
    assert "settings-parse-error" in codes


def test_diagnose_pure_no_writes(tmp_path):
    """Sanity: running diagnose against a real (existing) tree must not
    create any new files in the home dir, cwd, or anywhere else."""
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test:*)"]}})

    snapshot_before = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*"))
    pd.diagnose(home=home, cwd=cwd)
    snapshot_after = sorted(p.relative_to(tmp_path) for p in tmp_path.rglob("*"))
    assert snapshot_before == snapshot_after


# ── recommended hook snippet ─────────────────────────────────


def test_recommended_hook_config_snippet_default_python():
    snippet = pd.recommended_hook_config_snippet(
        helper_path=Path("/abs/path/helper.py"),
    )
    parsed = json.loads(snippet)
    cmd = parsed["hooks"]["PermissionRequest"][0]["command"]
    assert cmd.startswith("python3 ")
    assert "/abs/path/helper.py" in cmd
    assert "remote-approval-hook --provider claude" in cmd


def test_recommended_hook_config_snippet_custom_python():
    snippet = pd.recommended_hook_config_snippet(
        helper_path=Path("/abs/path/helper.py"),
        python_path="/opt/homebrew/bin/python3.12",
    )
    parsed = json.loads(snippet)
    cmd = parsed["hooks"]["PermissionRequest"][0]["command"]
    assert cmd.startswith("/opt/homebrew/bin/python3.12 ")


# ── repo-tailored suggestions ────────────────────────────────


def test_suggested_rules_npm_repo(tmp_path):
    cwd = tmp_path / "repo"
    cwd.mkdir()
    (cwd / "package.json").write_text("{}", encoding="utf-8")
    sugg = pd.suggested_rules_for_repo(cwd)
    assert "Bash(npm test)" in sugg
    assert "Bash(npm test:*)" in sugg


def test_suggested_rules_pnpm_repo(tmp_path):
    cwd = tmp_path / "repo"
    cwd.mkdir()
    (cwd / "package.json").write_text("{}", encoding="utf-8")
    (cwd / "pnpm-lock.yaml").write_text("", encoding="utf-8")
    sugg = pd.suggested_rules_for_repo(cwd)
    assert any("pnpm" in r for r in sugg)
    assert not any("npm test:" in r for r in sugg)


def test_suggested_rules_python_repo(tmp_path):
    cwd = tmp_path / "repo"
    cwd.mkdir()
    (cwd / "pyproject.toml").write_text("", encoding="utf-8")
    sugg = pd.suggested_rules_for_repo(cwd)
    assert "Bash(pytest)" in sugg


def test_render_text_report_runs_without_error(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test:*)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    text = pd.render_text_report(report)
    assert "Claude Code permission diagnosis" in text
    assert "user" in text
    assert "project" in text


def test_diagnose_to_json_serialises(tmp_path):
    home = tmp_path / "home"
    cwd = tmp_path / "repo"
    home.mkdir()
    cwd.mkdir()
    _write(home / ".claude" / "settings.json",
           {"permissions": {"allow": ["Bash(npm test:*)"]}})
    report = pd.diagnose(home=home, cwd=cwd)
    payload = report.to_json()
    serialised = json.dumps(payload)
    assert "settings" in payload
    assert isinstance(serialised, str)


# ── install_claude_hook (PR #18 follow-up) ───────────────────


def _install_paths(tmp_path):
    """Helper-path stub + settings file path under a tmp HOME."""
    helper = tmp_path / "fake_helper.py"
    helper.write_text("# stub", encoding="utf-8")
    settings = tmp_path / ".claude" / "settings.json"
    return helper.resolve(), settings


def test_install_claude_hook_creates_when_settings_missing(tmp_path):
    helper, settings = _install_paths(tmp_path)
    assert not settings.exists()

    result = pd.install_claude_hook(helper_path=helper, settings_path=settings)

    assert result["action"] == "created"
    assert result["previous_command"] is None
    written = json.loads(settings.read_text())
    assert "PermissionRequest" in written["hooks"]
    entries = written["hooks"]["PermissionRequest"]
    assert len(entries) == 1
    assert entries[0]["type"] == "command"
    assert "remote-approval-hook --provider claude" in entries[0]["command"]
    assert str(helper) in entries[0]["command"]


def test_install_claude_hook_noop_when_already_wired(tmp_path):
    helper, settings = _install_paths(tmp_path)
    pd.install_claude_hook(helper_path=helper, settings_path=settings)

    # Run again on the same file — should be a clean no-op.
    result = pd.install_claude_hook(helper_path=helper, settings_path=settings)
    assert result["action"] == "noop"
    # File untouched: still has exactly one entry.
    written = json.loads(settings.read_text())
    assert len(written["hooks"]["PermissionRequest"]) == 1


def test_install_claude_hook_replaces_stale_entry(tmp_path):
    helper, settings = _install_paths(tmp_path)
    # Pre-existing CLI Pulse entry from an OLDER helper checkout.
    stale = "python3 /old/path/cli_pulse_helper.py remote-approval-hook --provider claude"
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({
        "hooks": {"PermissionRequest": [{"type": "command", "command": stale}]}
    }), encoding="utf-8")

    result = pd.install_claude_hook(helper_path=helper, settings_path=settings)
    assert result["action"] == "replaced"
    assert result["previous_command"] == stale
    written = json.loads(settings.read_text())
    entries = written["hooks"]["PermissionRequest"]
    assert len(entries) == 1, "stale CLI Pulse entry must be replaced, not duplicated"
    assert str(helper) in entries[0]["command"]


def test_install_claude_hook_appends_when_user_has_other_hooks(tmp_path):
    """User has unrelated PermissionRequest hooks — we must NOT
    silently drop them, just add ours alongside.
    """
    helper, settings = _install_paths(tmp_path)
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text(json.dumps({
        "hooks": {"PermissionRequest": [
            {"type": "command", "command": "/usr/local/bin/audit-hook"}
        ]}
    }), encoding="utf-8")

    result = pd.install_claude_hook(helper_path=helper, settings_path=settings)
    assert result["action"] == "added"
    written = json.loads(settings.read_text())
    entries = written["hooks"]["PermissionRequest"]
    assert len(entries) == 2
    # User's pre-existing audit-hook survives.
    assert any(e["command"] == "/usr/local/bin/audit-hook" for e in entries)
    # Our entry is present.
    assert any(str(helper) in e["command"] for e in entries)


def test_install_claude_hook_preserves_unrelated_keys(tmp_path):
    """Pre-existing `permissions` / `model` / etc. must be preserved
    verbatim. We only touch `hooks.PermissionRequest`.
    """
    helper, settings = _install_paths(tmp_path)
    settings.parent.mkdir(parents=True, exist_ok=True)
    pre = {
        "permissions": {"allow": ["Bash(npm test:*)"], "deny": []},
        "model": "claude-sonnet-4-5",
        "extra": {"nested": {"deeply": True}},
    }
    settings.write_text(json.dumps(pre), encoding="utf-8")

    pd.install_claude_hook(helper_path=helper, settings_path=settings)
    written = json.loads(settings.read_text())
    assert written["permissions"] == pre["permissions"]
    assert written["model"] == pre["model"]
    assert written["extra"] == pre["extra"]
    # And our hook landed.
    assert "PermissionRequest" in written["hooks"]


def test_install_claude_hook_refuses_malformed_json(tmp_path):
    helper, settings = _install_paths(tmp_path)
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text("{not valid json", encoding="utf-8")

    with pytest.raises(ValueError, match="malformed JSON"):
        pd.install_claude_hook(helper_path=helper, settings_path=settings)
    # File untouched.
    assert settings.read_text() == "{not valid json"


def test_install_claude_hook_refuses_non_object_root(tmp_path):
    helper, settings = _install_paths(tmp_path)
    settings.parent.mkdir(parents=True, exist_ok=True)
    settings.write_text("[\"not\", \"an\", \"object\"]", encoding="utf-8")

    with pytest.raises(ValueError, match="non-object JSON"):
        pd.install_claude_hook(helper_path=helper, settings_path=settings)


def test_install_claude_hook_no_leftover_tmp_files(tmp_path):
    helper, settings = _install_paths(tmp_path)
    pd.install_claude_hook(helper_path=helper, settings_path=settings)
    leftovers = list(settings.parent.glob("settings.json.tmp"))
    assert leftovers == [], f"leftover tmp file: {leftovers}"
