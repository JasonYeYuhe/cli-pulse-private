"""Tests for the v1.15 provider spawner registry."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

# CI runs `pytest -q` from `helper/` as the working dir, so `helper.X`
# style imports do NOT resolve. Use the same `sys.path.insert` trick
# `test_local_session_server.py` uses to keep the test runnable both
# from the repo root (`pytest helper/`) and from within the helper dir.
HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from provider_spawners import (  # noqa: E402
    ClaudeSpawner,
    CodexSpawner,
    GeminiSpawner,
    all_provider_names,
    available_providers,
    get_spawner,
)


# Empty params shim — concrete spawners only read `params.extra_env`.
_EMPTY = SimpleNamespace(extra_env=None)


# ── registry ────────────────────────────────────────────────


def test_registry_has_three_known_providers():
    names = all_provider_names()
    assert set(names) == {"claude", "codex", "gemini"}, (
        f"unexpected provider list: {names}"
    )


def test_get_spawner_returns_instance_for_known():
    for name, cls in [
        ("claude", ClaudeSpawner),
        ("codex", CodexSpawner),
        ("gemini", GeminiSpawner),
    ]:
        spawner = get_spawner(name)
        assert spawner is not None
        assert isinstance(spawner, cls)


def test_get_spawner_returns_none_for_unknown():
    assert get_spawner("totally-not-a-cli") is None


def test_get_spawner_is_case_insensitive():
    assert isinstance(get_spawner("Claude"), ClaudeSpawner)
    assert isinstance(get_spawner("CODEX"), CodexSpawner)
    assert isinstance(get_spawner("Gemini"), GeminiSpawner)


# ── argv resolution ─────────────────────────────────────────


def test_claude_argv_default():
    assert ClaudeSpawner().argv(_EMPTY) == ["claude"]


def test_codex_argv_default():
    assert CodexSpawner().argv(_EMPTY) == ["codex"]


def test_gemini_argv_default_omits_yolo():
    assert GeminiSpawner().argv(_EMPTY) == ["gemini"]


def test_gemini_argv_adds_yolo_when_opted_in():
    """The iOS spawn UI sets `CLI_PULSE_GEMINI_YOLO=1` in
    `params.extra_env` when the user explicitly opts in. Spawner
    forwards the flag as a standard `--yolo` argv.
    """
    params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": "1"})
    assert GeminiSpawner().argv(params) == ["gemini", "--yolo"]


def test_gemini_argv_yolo_accepts_truthy_aliases():
    for value in ("1", "true", "yes"):
        params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": value})
        argv = GeminiSpawner().argv(params)
        assert argv == ["gemini", "--yolo"], f"value={value!r} → {argv}"


def test_gemini_argv_yolo_falsy_keeps_default():
    for value in ("", "0", "false", "no"):
        params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": value})
        argv = GeminiSpawner().argv(params)
        assert argv == ["gemini"], f"value={value!r} → {argv}"


# ── env override hooks ──────────────────────────────────────


@pytest.mark.parametrize("env_var,spawner_cls,expected", [
    ("CLI_PULSE_CLAUDE_ARGV0", ClaudeSpawner,
     ["/opt/local/bin/claude", "--theme=dark"]),
    ("CLI_PULSE_CODEX_ARGV0", CodexSpawner,
     ["/usr/local/bin/codex"]),
    ("CLI_PULSE_GEMINI_ARGV0", GeminiSpawner,
     ["/Users/test/bin/gemini"]),
])
def test_argv0_env_override(monkeypatch, env_var, spawner_cls, expected):
    """`CLI_PULSE_<PROVIDER>_ARGV0` lets users on uncommon installs
    point the spawner at a non-PATH binary. Whitespace-tokenized so
    multi-token argv0 (binary + leading flags) work.
    """
    monkeypatch.setenv(env_var, " ".join(expected))
    argv = spawner_cls().argv(_EMPTY)
    assert argv == expected


def test_gemini_yolo_compounds_with_argv0_override(monkeypatch):
    """Override + YOLO together: tokenized argv0 first, then `--yolo`
    appended.
    """
    monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", "/opt/gemini/bin/gemini")
    params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": "1"})
    argv = GeminiSpawner().argv(params)
    assert argv == ["/opt/gemini/bin/gemini", "--yolo"]


# ── env_overrides ───────────────────────────────────────────


def test_env_overrides_default_empty():
    """No spawner needs provider-specific env beyond what the manager
    already injects (CLI_PULSE_REMOTE_SESSION_ID, capability token).
    Pinned to flag if a future change accidentally adds a leak.
    """
    for spawner in (ClaudeSpawner(), CodexSpawner(), GeminiSpawner()):
        assert spawner.env_overrides(_EMPTY) == {}


# ── approval-surface contract ───────────────────────────────


def test_only_claude_supports_remote_approval():
    """Claude has the `claude-pre-tool-use` hook → routes to
    `remote_pending_approvals`. Codex / Gemini handle approvals
    inline in their TUI; v1.15 ships no remote-approve surface for
    them. Pinned so a future refactor that adds Codex/Gemini hooks
    has to update this contract intentionally.
    """
    assert ClaudeSpawner().supports_remote_approval() is True
    assert CodexSpawner().supports_remote_approval() is False
    assert GeminiSpawner().supports_remote_approval() is False


# ── is_available + capability advertisement ─────────────────


def test_is_available_reports_truthy_with_argv0_override(monkeypatch, tmp_path):
    """Dummy executable on disk + ARGV0 override → is_available()
    returns True. Ensures the capability map can pick up users with
    unusual install layouts.
    """
    fake_bin = tmp_path / "claude"
    fake_bin.write_text("#!/bin/sh\nexit 0\n")
    fake_bin.chmod(0o755)
    monkeypatch.setenv("CLI_PULSE_CLAUDE_ARGV0", str(fake_bin))
    assert ClaudeSpawner().is_available() is True


def test_is_available_returns_false_when_binary_missing(monkeypatch):
    """Both the override AND PATH must miss → False. Use a path
    deliberately not on PATH to defeat the fallback shutil.which().
    """
    monkeypatch.setenv("CLI_PULSE_CLAUDE_ARGV0", "/no/such/path/that/exists")
    # Also ensure plain `claude` resolves to nothing for this scope.
    monkeypatch.setenv("PATH", "/var/empty")
    assert ClaudeSpawner().is_available() is False


def test_available_providers_subset_of_all():
    """`available_providers()` is a subset of `all_provider_names()`.
    Even on a host with zero CLIs installed the function returns a
    list (possibly empty); never raises.
    """
    available = set(available_providers())
    all_names = set(all_provider_names())
    assert available.issubset(all_names), (
        f"available={available} is not a subset of all={all_names}"
    )
