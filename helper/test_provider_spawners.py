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
    AiderSpawner,
    BaseSpawner,
    ClaudeSpawner,
    CodexSpawner,
    CursorSpawner,
    GeminiSpawner,
    OpenCodeSpawner,
    all_provider_names,
    available_providers,
    get_spawner,
)

# H-F1 (v1.22): the registry after the BaseSpawner refactor + new CLIs.
_ALL_PROVIDERS = {"claude", "codex", "gemini", "aider", "opencode", "cursor"}


# Empty params shim — concrete spawners only read `params.extra_env`.
_EMPTY = SimpleNamespace(extra_env=None)


# ── registry ────────────────────────────────────────────────


def test_registry_has_all_known_providers():
    names = all_provider_names()
    assert set(names) == _ALL_PROVIDERS, (
        f"unexpected provider list: {names}"
    )


def test_get_spawner_returns_instance_for_known():
    for name, cls in [
        ("claude", ClaudeSpawner),
        ("codex", CodexSpawner),
        ("gemini", GeminiSpawner),
        ("aider", AiderSpawner),
        ("opencode", OpenCodeSpawner),
        ("cursor", CursorSpawner),
    ]:
        spawner = get_spawner(name)
        assert spawner is not None
        assert isinstance(spawner, cls)


def test_every_spawner_inherits_base():
    """H-F1 de-dup invariant: all registered spawners share the single
    `BaseSpawner` argv0-override + `is_available` implementation. Pinned
    so a future provider that re-copies the resolution logic instead of
    subclassing is caught in review.
    """
    for name in _ALL_PROVIDERS:
        spawner = get_spawner(name)
        assert isinstance(spawner, BaseSpawner), (
            f"{name} spawner must subclass BaseSpawner (H-F1)"
        )


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


def test_codex_env_overrides_enables_rust_backtrace():
    """v1.16 §2.1: Codex defensive hardening — RUST_BACKTRACE=1 is set
    by default so when Codex's TUI panics on startup with exit_code=101,
    the panic message lands in stderr (and thus in the session's PTY
    output stream) rather than only the bare exit code."""
    env = CodexSpawner().env_overrides(_EMPTY)
    assert env.get("RUST_BACKTRACE") == "1"


def test_gemini_argv_default_is_bare_agy():
    # v-next P0-B: gemini provider spawns the Antigravity CLI `agy`
    # (legacy gemini CLI hard-fails individual-tier accounts).
    assert GeminiSpawner().argv(_EMPTY) == ["agy"]


def test_gemini_argv_adds_skip_permissions_when_opted_in():
    """The spawn UI sets `CLI_PULSE_GEMINI_YOLO=1` in `params.extra_env`
    when the user explicitly opts in. Spawner forwards it as agy's
    `--dangerously-skip-permissions` (the legacy gemini CLI used `--yolo`).
    """
    params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": "1"})
    assert GeminiSpawner().argv(params) == ["agy", "--dangerously-skip-permissions"]


def test_gemini_argv_yolo_accepts_truthy_aliases():
    for value in ("1", "true", "yes"):
        params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": value})
        argv = GeminiSpawner().argv(params)
        assert argv == ["agy", "--dangerously-skip-permissions"], f"value={value!r} → {argv}"


def test_gemini_argv_yolo_falsy_keeps_default():
    for value in ("", "0", "false", "no"):
        params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": value})
        argv = GeminiSpawner().argv(params)
        assert argv == ["agy"], f"value={value!r} → {argv}"


# ── H-F1 new providers (Aider / OpenCode / Cursor) ──────────


@pytest.mark.parametrize("spawner_cls,expected_argv,name", [
    (AiderSpawner, ["aider"], "aider"),
    (OpenCodeSpawner, ["opencode"], "opencode"),
    # Cursor's headless agent binary is `cursor-agent`, not `cursor`.
    (CursorSpawner, ["cursor-agent"], "cursor"),
])
def test_new_provider_argv_and_name(spawner_cls, expected_argv, name):
    s = spawner_cls()
    assert s.name == name
    assert s.argv(_EMPTY) == expected_argv
    assert s.env_overrides(_EMPTY) == {}
    # None of the H-F1 CLIs expose a Claude-style hook protocol.
    assert s.supports_remote_approval() is False


def test_new_provider_inherits_shared_argv0_override(monkeypatch, tmp_path):
    """The whole point of H-F1: a brand-new provider gets the override
    + `is_available` behavior for free from BaseSpawner, with zero
    copied resolution code. Verify on CursorSpawner.
    """
    fake = tmp_path / "cursor-agent"
    fake.write_text("#!/bin/sh\nexit 0\n")
    fake.chmod(0o755)
    monkeypatch.setenv("CLI_PULSE_CURSOR_ARGV0", f"{fake} --print")
    s = CursorSpawner()
    assert s.argv(_EMPTY) == [str(fake), "--print"]
    assert s.is_available() is True


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
    """Override + opt-in together: tokenized argv0 first, then
    `--dangerously-skip-permissions` appended.
    """
    monkeypatch.setenv("CLI_PULSE_GEMINI_ARGV0", "/opt/agy/bin/agy")
    params = SimpleNamespace(extra_env={"CLI_PULSE_GEMINI_YOLO": "1"})
    argv = GeminiSpawner().argv(params)
    assert argv == ["/opt/agy/bin/agy", "--dangerously-skip-permissions"]


# ── env_overrides ───────────────────────────────────────────


def test_env_overrides_default_empty(monkeypatch):
    """v1.16 §2.1: only CodexSpawner adds env. Claude + Gemini stay empty.
    Pinned to flag if a future change accidentally adds a leak.

    v1.35: Codex also pins CODEX_HOME when a home resolves; force the home
    unresolvable here to pin the RUST_BACKTRACE-only invariant, then test
    the CODEX_HOME pin separately below.
    """
    assert ClaudeSpawner().env_overrides(_EMPTY) == {}
    assert GeminiSpawner().env_overrides(_EMPTY) == {}
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: None
    )
    # Codex with no resolvable home: RUST_BACKTRACE=1 only, no CODEX_HOME.
    assert CodexSpawner().env_overrides(_EMPTY) == {"RUST_BACKTRACE": "1"}


# ── v1.35 Codex on-plan (Swift↔Python parity) ───────────────

# A verified ChatGPT auth.json (auth_mode=chatgpt + a real access token),
# and an api-key variant that must NOT trigger the scrub.
_CHATGPT_AUTH = (
    b'{"auth_mode":"chatgpt","tokens":{"access_token":"tok-abc",'
    b'"refresh_token":"ref-xyz"},"OPENAI_API_KEY":"sk-in-file"}'
)
_APIKEY_AUTH = b'{"auth_mode":"apikey","OPENAI_API_KEY":"sk-live"}'


def test_codex_env_overrides_pins_codex_home(monkeypatch):
    """When a home resolves, Codex pins CODEX_HOME=<home>/.codex so codex
    reads the on-plan auth.json even if launchd drifted HOME. Mirrors Swift
    CodexSpawner.envPatch."""
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: "/Users/z"
    )
    env = CodexSpawner().env_overrides(_EMPTY)
    assert env["RUST_BACKTRACE"] == "1"
    assert env["CODEX_HOME"] == "/Users/z/.codex"


def test_codex_has_verified_chatgpt_auth_true_for_chatgpt_token():
    assert CodexSpawner.has_verified_chatgpt_auth(
        "/home/u", file_loader=lambda _p: _CHATGPT_AUTH
    ) is True


def test_codex_has_verified_chatgpt_auth_refresh_only():
    raw = b'{"auth_mode":"chatgpt","tokens":{"refresh_token":"r"}}'
    assert CodexSpawner.has_verified_chatgpt_auth(
        "/home/u", file_loader=lambda _p: raw
    ) is True


def test_codex_has_verified_chatgpt_auth_false_for_apikey():
    assert CodexSpawner.has_verified_chatgpt_auth(
        "/home/u", file_loader=lambda _p: _APIKEY_AUTH
    ) is False


def test_codex_has_verified_chatgpt_auth_false_when_missing_or_bad():
    assert CodexSpawner.has_verified_chatgpt_auth(
        "/home/u", file_loader=lambda _p: None
    ) is False
    assert CodexSpawner.has_verified_chatgpt_auth(
        "/home/u", file_loader=lambda _p: b"not json"
    ) is False
    # chatgpt mode but no tokens at all → not verified.
    assert CodexSpawner.has_verified_chatgpt_auth(
        "/home/u", file_loader=lambda _p: b'{"auth_mode":"chatgpt"}'
    ) is False
    # No home → never verified (avoids keying off a bad path).
    assert CodexSpawner.has_verified_chatgpt_auth(None) is False


def test_codex_env_removals_scrubs_openai_key_on_plan(monkeypatch):
    """The whole point: an on-plan Codex spawn scrubs an inherited
    OPENAI_API_KEY so codex can't fall back to the billed API. Mirrors
    Swift ProviderEnvPatch.remove."""
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: "/Users/z"
    )
    monkeypatch.setattr(
        CodexSpawner, "has_verified_chatgpt_auth",
        staticmethod(lambda home, file_loader=None: True),
    )
    assert CodexSpawner().env_removals(_EMPTY) == {"OPENAI_API_KEY"}


def test_codex_env_removals_empty_when_off_plan(monkeypatch):
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: "/Users/z"
    )
    monkeypatch.setattr(
        CodexSpawner, "has_verified_chatgpt_auth",
        staticmethod(lambda home, file_loader=None: False),
    )
    # api-key user: DON'T scrub — leave their own auth intact.
    assert CodexSpawner().env_removals(_EMPTY) == set()


def test_codex_env_removals_empty_when_no_home(monkeypatch):
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: None
    )
    # Unresolvable home ⇒ no pin AND no scrub (documented invariant).
    assert CodexSpawner().env_removals(_EMPTY) == set()
    assert "CODEX_HOME" not in CodexSpawner().env_overrides(_EMPTY)


def test_codex_plan_auth_status(monkeypatch):
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: "/Users/z"
    )
    monkeypatch.setattr(
        CodexSpawner, "has_verified_chatgpt_auth",
        staticmethod(lambda home, file_loader=None: True),
    )
    assert CodexSpawner().plan_auth_status() == "on_plan"
    monkeypatch.setattr(
        CodexSpawner, "has_verified_chatgpt_auth",
        staticmethod(lambda home, file_loader=None: False),
    )
    assert CodexSpawner().plan_auth_status() == "off_plan"
    monkeypatch.setattr(
        "provider_spawners.codex.resolved_user_home", lambda: None
    )
    assert CodexSpawner().plan_auth_status() == "unknown"


def test_gemini_plan_auth_status_follows_availability(monkeypatch):
    """agy resolvable ⇒ on_plan (Gemini via agy's own OAuth); else unknown.
    Never off_plan. Mirrors Swift GeminiSpawner.planAuthStatus."""
    g = GeminiSpawner()
    monkeypatch.setattr(g, "is_available", lambda: True)
    assert g.plan_auth_status() == "on_plan"
    monkeypatch.setattr(g, "is_available", lambda: False)
    assert g.plan_auth_status() == "unknown"


def test_base_defaults_no_removals_unknown_plan():
    """A vanilla spawner removes nothing and is plan-unknown, so adding a
    provider can't accidentally scrub env or emit a false warning."""
    assert AiderSpawner().env_removals(_EMPTY) == set()
    assert AiderSpawner().plan_auth_status() == "unknown"


def test_provider_plan_statuses_omits_unknown(monkeypatch):
    """The hello map carries only decisive statuses; unknown + unavailable
    providers are omitted (absent ⇒ no picker warning). Mirrors Swift
    ProviderSpawnerRegistry.planAuthStatuses."""
    import provider_spawners as ps

    class _Fake:
        def __init__(self, avail, status):
            self._a, self._s = avail, status

        def is_available(self):
            return self._a

        def plan_auth_status(self, params=None):
            return self._s

    monkeypatch.setattr(ps, "_REGISTRY", {
        "codex": _Fake(True, "on_plan"),
        "gemini": _Fake(True, "off_plan"),
        "aider": _Fake(True, "unknown"),      # decisive-only ⇒ omitted
        "cursor": _Fake(False, "on_plan"),    # unavailable ⇒ omitted
    })
    assert ps.provider_plan_statuses() == {
        "codex": "on_plan", "gemini": "off_plan",
    }


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
    # H-F1 CLIs: observability-only, no remote-approve surface.
    assert AiderSpawner().supports_remote_approval() is False
    assert OpenCodeSpawner().supports_remote_approval() is False
    assert CursorSpawner().supports_remote_approval() is False


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
    import provider_spawners.base as _base
    monkeypatch.setenv("CLI_PULSE_CLAUDE_ARGV0", "/no/such/path/that/exists")
    # Also ensure plain `claude` resolves to nothing for this scope.
    monkeypatch.setenv("PATH", "/var/empty")
    # v-next P0-C: is_available() now searches augmented_path(), which
    # appends ~/.local/bin (where `claude` is actually installed on a dev
    # box). Neutralize the extra dirs so "binary missing" stays testable.
    monkeypatch.setattr(_base, "_EXTRA_PATH_DIRS", ())
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
