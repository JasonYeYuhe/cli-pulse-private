"""Tests for the opt-in shell integration (DEV_PLAN_2026-07-14 M4.3).

Pure-render + file-ops tests always run. The shim-behaviour tests actually
SOURCE the generated shell-init.sh in bash and verify it FAILS OPEN and WRAPS
correctly (the load-bearing safety property).
"""
from __future__ import annotations

import os
import shutil
import stat
import subprocess

import pytest

import shell_integration as si

_BASH = shutil.which("bash")
_TMUX = shutil.which("tmux")


# --- pure render -----------------------------------------------------------

def test_rc_block_is_marked_and_sources_init():
    block = si.render_rc_block("/home/u/.clipulse/shell-init.sh")
    assert block.startswith(si.MARKER_BEGIN)
    assert block.rstrip().endswith(si.MARKER_END)
    assert '. "/home/u/.clipulse/shell-init.sh"' in block


def test_shell_init_defines_provider_shims_and_fails_open():
    init = si.render_shell_init("/usr/bin/tmux", "/tmp/t.sock", "/tmp/t.conf")
    for p in si.WRAPPED_PROVIDERS:
        assert f"{p}()" in init
    # fail-open guards present
    assert "CLIPULSE_WRAP_ACTIVE" in init
    assert "CLIPULSE_WRAP_DISABLE" in init
    assert "-x \"$CLIPULSE_TMUX_BIN\"" in init or '! -x "$CLIPULSE_TMUX_BIN"' in init
    assert "new-session -A" in init


# --- install / uninstall / status -----------------------------------------

def test_install_is_idempotent(tmp_path):
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    with open(rc, "w") as f:
        f.write("export FOO=1\n")
    st1 = si.install(home=home, tmux_bin="/usr/bin/tmux", rc_files=[rc])
    assert st1.installed
    assert os.path.exists(os.path.join(home, ".clipulse", "shell-init.sh"))
    body1 = open(rc).read()
    assert body1.count(si.MARKER_BEGIN) == 1
    assert "export FOO=1" in body1               # preserved the user's content
    # re-install → still exactly one block, no duplication
    si.install(home=home, tmux_bin="/usr/bin/tmux", rc_files=[rc])
    body2 = open(rc).read()
    assert body2.count(si.MARKER_BEGIN) == 1


def test_refresh_rebakes_stale_tmux_path(tmp_path):
    # A shim installed when tmux resolution gave a now-stale path (e.g. a
    # pre-1.30.0 .pkg baked the absent Homebrew fallback) must be re-rendered
    # by refresh() with the CURRENT resolution — without touching the rc file.
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    with open(rc, "w") as f:
        f.write("export FOO=1\n")
    si.install(home=home, tmux_bin="/stale/tmux", rc_files=[rc])
    rc_before = open(rc).read()
    init_p = os.path.join(home, ".clipulse", "shell-init.sh")
    assert "/stale/tmux" in open(init_p).read()

    st = si.refresh(home=home, tmux_bin="/fresh/tmux", rc_files=[rc])
    body = open(init_p).read()
    assert "/fresh/tmux" in body
    assert "/stale/tmux" not in body
    assert open(rc).read() == rc_before          # rc untouched: refresh ≠ install
    assert st.init_present and st.installed


def test_refresh_is_noop_when_not_installed(tmp_path):
    # refresh() must NEVER opt a user in: with no existing init file it writes
    # nothing (postinstall runs it unconditionally on every .pkg install).
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    with open(rc, "w") as f:
        f.write("export FOO=1\n")
    st = si.refresh(home=home, tmux_bin="/fresh/tmux", rc_files=[rc])
    assert not st.init_present and not st.installed
    assert not os.path.exists(os.path.join(home, ".clipulse", "shell-init.sh"))
    assert not os.path.exists(os.path.join(home, ".clipulse", "tmux.conf"))
    assert open(rc).read() == "export FOO=1\n"   # rc untouched


def test_uninstall_removes_block_and_files(tmp_path):
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    with open(rc, "w") as f:
        f.write("export FOO=1\n")
    si.install(home=home, tmux_bin="/usr/bin/tmux", rc_files=[rc])
    si.uninstall(home=home, rc_files=[rc])
    body = open(rc).read()
    assert si.MARKER_BEGIN not in body
    assert "export FOO=1" in body                # user content survives
    assert not os.path.exists(os.path.join(home, ".clipulse", "shell-init.sh"))
    st = si.status(home=home, rc_files=[rc])
    assert not st.installed


def test_uninstall_is_safe_when_never_installed(tmp_path):
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    open(rc, "w").write("export FOO=1\n")
    si.uninstall(home=home, rc_files=[rc])       # no raise
    assert "export FOO=1" in open(rc).read()


def test_strip_block_tolerates_missing_end_marker():
    text = f"a\n{si.MARKER_BEGIN}\nsomething\n"   # truncated, no END
    out = si._strip_block(text)
    assert si.MARKER_BEGIN not in out
    assert out.startswith("a")


def test_status_reflects_state(tmp_path):
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    open(rc, "w").write("")
    assert not si.status(home=home, rc_files=[rc]).installed
    si.install(home=home, tmux_bin="/usr/bin/tmux", rc_files=[rc])
    st = si.status(home=home, rc_files=[rc])
    assert st.installed and st.init_present and rc in st.rc_files_with_block


# --- shim behaviour (source it in a real shell) ---------------------------

def _fake_bin(dir_: str, name: str, body: str) -> None:
    p = os.path.join(dir_, name)
    with open(p, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)


@pytest.mark.skipif(_BASH is None, reason="bash not available")
def test_shim_fails_open_when_wrap_active(tmp_path):
    # A fake `claude` on PATH; with CLIPULSE_WRAP_ACTIVE set, the shim must run it
    # directly (no tmux) — proving the anti-recursion / fail-open guard.
    bind = tmp_path / "bin"
    bind.mkdir()
    marker = tmp_path / "ran.txt"
    _fake_bin(str(bind), "claude", f'echo "GOT:$*" > "{marker}"\n')
    init = si.render_shell_init("/nonexistent/tmux", "/tmp/x.sock", "/tmp/x.conf")
    init_p = tmp_path / "init.sh"
    init_p.write_text(init)
    env = dict(os.environ, PATH=f"{bind}:{os.environ['PATH']}", CLIPULSE_WRAP_ACTIVE="1")
    subprocess.run([_BASH, "-c", f'. "{init_p}"; claude hello world'], env=env, check=True)
    assert marker.read_text().strip() == "GOT:hello world"


@pytest.mark.skipif(_BASH is None, reason="bash not available")
def test_shim_fails_open_when_tmux_missing(tmp_path):
    bind = tmp_path / "bin"
    bind.mkdir()
    marker = tmp_path / "ran.txt"
    _fake_bin(str(bind), "codex", f'echo "CODEX:$*" > "{marker}"\n')
    # tmux bin points at a nonexistent path → guard runs the real binary
    init = si.render_shell_init("/definitely/not/tmux", "/tmp/x.sock", "/tmp/x.conf")
    init_p = tmp_path / "init.sh"
    init_p.write_text(init)
    env = dict(os.environ, PATH=f"{bind}:{os.environ['PATH']}")
    env.pop("CLIPULSE_WRAP_ACTIVE", None)
    subprocess.run([_BASH, "-c", f'. "{init_p}"; codex go'], env=env, check=True)
    assert marker.read_text().strip() == "CODEX:go"


def _run_under_pty(bash: str, script: str, env: dict, timeout: float = 5.0) -> None:
    """Run `bash -c script` with a PTY as stdio so the shim's `[ -t 0 ]`/`[ -t 1 ]`
    interactive check passes."""
    import pty
    import time
    master, slave = pty.openpty()
    proc = subprocess.Popen([bash, "-c", script], stdin=slave, stdout=slave, stderr=slave,
                            env=env, start_new_session=True)
    os.close(slave)
    deadline = time.monotonic() + timeout
    while proc.poll() is None and time.monotonic() < deadline:
        try:
            os.read(master, 4096)
        except OSError:
            break
    os.close(master)
    if proc.poll() is None:
        proc.kill()
    proc.wait(timeout=2)


@pytest.mark.skipif(_BASH is None, reason="bash required")
def test_shim_builds_the_expected_tmux_command(tmp_path):
    # A FAKE tmux that records its argv, so we deterministically verify the shim's
    # command construction (the real attach + streaming is proven by the tmux
    # transport's round-trip tests + the M4.1 spike). Runs under a PTY so the
    # interactive tty guard passes; the fake tmux just records + exits.
    bind = tmp_path / "bin"
    bind.mkdir()
    argv_log = tmp_path / "argv.txt"
    _fake_bin(str(bind), "tmux", f'printf "%s\\n" "$@" > "{argv_log}"; exit 0\n')
    fake_tmux = str(bind / "tmux")
    _fake_bin(str(bind), "claude", 'exit 0\n')
    # The shim fails open if the tmux CONF is missing (turned-off guard), so the
    # conf must EXIST for the wrap path under test to run.
    conf_p = tmp_path / "x.conf"
    conf_p.write_text(si.render_tmux_conf())
    init = si.render_shell_init(fake_tmux, "/tmp/x.sock", str(conf_p))
    init_p = tmp_path / "init.sh"
    init_p.write_text(init)
    env = dict(os.environ, PATH=f"{bind}:{os.environ['PATH']}")
    env.pop("CLIPULSE_WRAP_ACTIVE", None)
    _run_under_pty(_BASH, f'. "{init_p}"; claude hi there', env)
    args = argv_log.read_text().splitlines()
    assert "-S" in args and "/tmp/x.sock" in args
    assert "new-session" in args and "-A" in args
    assert any(a.startswith("clipulse-claude-") for a in args), args
    assert "CLIPULSE_WRAP_ACTIVE=1" in args
    tail = args[args.index("--") + 1:]
    assert tail == ["claude", "hi", "there"], tail


@pytest.mark.skipif(_BASH is None, reason="bash required")
def test_shim_fails_open_when_not_a_tty(tmp_path):
    # CRITICAL: a non-interactive launch (no tty — headless `claude -p`, a pipe, a
    # script) must run the REAL binary, NOT wrap (tmux attach needs a tty). Here
    # stdin/stdout are pipes → the shim must call the real claude, never fake tmux.
    bind = tmp_path / "bin"
    bind.mkdir()
    ran = tmp_path / "ran.txt"
    tmux_called = tmp_path / "tmux_called.txt"
    _fake_bin(str(bind), "tmux", f'echo called > "{tmux_called}"\n')
    _fake_bin(str(bind), "claude", f'echo "REAL:$*" > "{ran}"\n')
    init = si.render_shell_init(str(bind / "tmux"), "/tmp/x.sock", "/tmp/x.conf")
    init_p = tmp_path / "init.sh"
    init_p.write_text(init)
    env = dict(os.environ, PATH=f"{bind}:{os.environ['PATH']}")
    env.pop("CLIPULSE_WRAP_ACTIVE", None)
    # subprocess.run → pipes, not a tty
    subprocess.run([_BASH, "-c", f'. "{init_p}"; claude go'], env=env,
                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    assert ran.read_text().strip() == "REAL:go"
    assert not tmux_called.exists(), "shim wrapped a non-interactive launch — would break it"


@pytest.mark.skipif(_BASH is None, reason="bash required")
def test_shim_fails_open_when_conf_missing(tmp_path):
    # Turn-Off safety (review: codex): an already-running shell keeps the wrapper
    # function after uninstall removed the conf. The shim must then run the REAL
    # binary, NOT wrap against the deleted -f config. Run under a PTY so the tty
    # guards pass and ONLY the missing-conf guard fires.
    bind = tmp_path / "bin"
    bind.mkdir()
    ran = tmp_path / "ran.txt"
    tmux_called = tmp_path / "tmux_called.txt"
    _fake_bin(str(bind), "tmux", f'echo called > "{tmux_called}"\n')
    _fake_bin(str(bind), "claude", f'echo "REAL:$*" > "{ran}"\n')
    # conf path deliberately does NOT exist (simulates post-uninstall).
    init = si.render_shell_init(str(bind / "tmux"), str(tmp_path / "x.sock"),
                                str(tmp_path / "gone.conf"))
    init_p = tmp_path / "init.sh"
    init_p.write_text(init)
    env = dict(os.environ, PATH=f"{bind}:{os.environ['PATH']}")
    env.pop("CLIPULSE_WRAP_ACTIVE", None)
    _run_under_pty(_BASH, f'. "{init_p}"; claude go', env)
    assert ran.read_text().strip() == "REAL:go"
    assert not tmux_called.exists(), "shim wrapped against a deleted conf — would break claude"


def test_install_locks_down_clipulse_dir(tmp_path):
    home = str(tmp_path)
    rc = os.path.join(home, ".zshrc")
    open(rc, "w").write("")
    si.install(home=home, tmux_bin="/usr/bin/tmux", rc_files=[rc])
    mode = stat.S_IMODE(os.stat(si.clipulse_dir(home)).st_mode)
    assert mode == 0o700, oct(mode)


# --- M4.4b: bundled-tmux resolution ---------------------------------------

import sys as _sys  # noqa: E402


def test_resolve_tmux_bin_prefers_explicit():
    assert si.resolve_tmux_bin("/custom/path/tmux") == "/custom/path/tmux"


def _fake_frozen(monkeypatch, exe_path):
    # Simulate the PyInstaller-frozen helper: sys.frozen=True + sys.executable
    # pointing at the (fake) frozen binary. NEVER sys.argv (hijack-safe).
    monkeypatch.setattr(_sys, "frozen", True, raising=False)
    monkeypatch.setattr(_sys, "executable", str(exe_path))


def test_resolve_tmux_bin_prefers_bundled_sibling(tmp_path, monkeypatch):
    # A tmux sibling of the FROZEN helper executable is preferred over PATH —
    # this is Contents/Helpers/tmux in the shipped .app.
    fake_helper = tmp_path / "cli_pulse_helper"
    fake_helper.write_text("#!/bin/sh\n")
    bundled = tmp_path / "tmux"
    bundled.write_text("#!/bin/sh\n")
    bundled.chmod(0o755)
    _fake_frozen(monkeypatch, fake_helper)
    assert si.resolve_tmux_bin() == str(bundled)


def test_resolve_tmux_bin_ignores_sibling_when_not_frozen(tmp_path, monkeypatch):
    # In a DEV checkout (not frozen), a tmux next to the python interpreter must
    # NOT be treated as "bundled" — else a Homebrew tmux beside a Homebrew
    # python3 would be wrongly claimed. (agy)
    fake_helper = tmp_path / "python3"
    fake_helper.write_text("#!/bin/sh\n")
    bundled = tmp_path / "tmux"
    bundled.write_text("#!/bin/sh\n")
    bundled.chmod(0o755)
    monkeypatch.setattr(_sys, "frozen", False, raising=False)
    monkeypatch.setattr(_sys, "executable", str(fake_helper))
    assert si.resolve_tmux_bin() != str(bundled)  # sibling ignored → PATH/fallback


def test_resolve_tmux_bin_falls_back_when_no_bundle(tmp_path, monkeypatch):
    # Frozen but no tmux sibling → falls through to PATH / homebrew fallback,
    # never the nonexistent bundled path.
    fake_helper = tmp_path / "cli_pulse_helper"
    fake_helper.write_text("#!/bin/sh\n")
    _fake_frozen(monkeypatch, fake_helper)
    got = si.resolve_tmux_bin()
    assert got != str(tmp_path / "tmux")
    assert got  # non-empty


def test_resolve_tmux_bin_ignores_non_executable_sibling(tmp_path, monkeypatch):
    # A non-executable `tmux` sibling must be ignored (not a runnable binary).
    fake_helper = tmp_path / "cli_pulse_helper"
    fake_helper.write_text("#!/bin/sh\n")
    (tmp_path / "tmux").write_text("not executable\n")  # no +x
    _fake_frozen(monkeypatch, fake_helper)
    assert si.resolve_tmux_bin() != str(tmp_path / "tmux")
