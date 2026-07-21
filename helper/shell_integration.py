r"""Opt-in shell integration — wrap future `claude`/`codex` launches into a
CLI-Pulse-owned tmux server so the app can stream their I/O and inject remote
input (DEV_PLAN_2026-07-14_external_session_control.md M4.3).

This is the ONLY way to get real remote INPUT into an externally-launched agent
TUI on macOS (TIOCSTI is dead, a bare TUI exposes no IPC). We can't attach to a
session that already started outside tmux, so we shim FUTURE launches: a small
`claude()` / `codex()` shell function runs the real binary inside a tmux session
on `~/.clipulse/tmux.sock`, then the helper's TmuxTransport attaches out-of-band
in control mode.

Safety invariants (this writes to the user's shell rc — a STANDING change):
  * Everything is gated by an explicit opt-in — `install()` is only ever called
    from a user-driven toggle, never automatically.
  * The rc edit is an idempotent MARKED BLOCK that only SOURCES a separate init
    file, so re-install / update never rewrites the rc, and `uninstall()` removes
    exactly the block.
  * The shim FAILS OPEN: if tmux is missing, or we're already inside a CLI-Pulse
    tmux, or anything errors, it runs the real binary unchanged — a broken
    integration can never brick the user's `claude`.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from dataclasses import dataclass

MARKER_BEGIN = "# >>> cli-pulse shell integration >>>"
MARKER_END = "# <<< cli-pulse shell integration <<<"

# Everything the integration writes lives under ~/.clipulse so uninstall is a
# clean directory removal + one marked-block deletion per rc file.
CLIPULSE_DIR = ".clipulse"
INIT_BASENAME = "shell-init.sh"
CONF_BASENAME = "tmux.conf"
SOCK_BASENAME = "tmux.sock"

# Session name prefix so the helper can enumerate wrapped sessions and so a shim
# never collides with the user's own tmux sessions.
SESSION_PREFIX = "clipulse-"

# The providers we wrap. Kept small + explicit — never wrap a general shell.
WRAPPED_PROVIDERS = ("claude", "codex")

# rc files we manage, in preference order (we touch every one that exists, plus
# always the login shell's primary so a fresh file is created if needed).
_RC_CANDIDATES = (".zshrc", ".bashrc", ".bash_profile")


def _home(home: str | None) -> str:
    return home or os.path.expanduser("~")


def clipulse_dir(home: str | None = None) -> str:
    return os.path.join(_home(home), CLIPULSE_DIR)


def sock_path(home: str | None = None) -> str:
    return os.path.join(clipulse_dir(home), SOCK_BASENAME)


def init_path(home: str | None = None) -> str:
    return os.path.join(clipulse_dir(home), INIT_BASENAME)


def conf_path(home: str | None = None) -> str:
    return os.path.join(clipulse_dir(home), CONF_BASENAME)


# --- tmux binary resolution (M4.4b: prefer the bundled signed tmux) --------

def _bundled_tmux_path() -> str | None:
    """Path to a tmux bundled ALONGSIDE the FROZEN helper executable, if present
    + executable — `Contents/Helpers/tmux` in the shipped .app,
    `~/Library/CLI-Pulse-Helper/tmux` in the helper .pkg install (embedded by
    scripts/build_helper_pkg.sh step 3d since helper 1.30.0). `None` otherwise.

    Only consulted when running as the PyInstaller-frozen helper (`sys.frozen`):
      * in a dev checkout `sys.executable` is the python interpreter, whose dir
        may hold a Homebrew tmux we'd WRONGLY claim as "bundled" (review: agy);
      * `sys.argv[0]` is deliberately NOT used — it can point at an
        attacker-writable CWD (e.g. running the helper from ~/Downloads), which
        would let a planted `tmux` be executed (review: agy)."""
    if not getattr(sys, "frozen", False):
        return None
    exe = getattr(sys, "executable", None)
    if not exe:
        return None
    try:
        cand = os.path.join(os.path.dirname(os.path.realpath(exe)), "tmux")
    except (OSError, ValueError):
        return None
    if os.path.isfile(cand) and os.access(cand, os.X_OK):
        return cand
    return None


def resolve_tmux_bin(explicit: str | None = None) -> str:
    """Resolve which tmux to use, in priority order: an explicit path → the
    bundled signed tmux next to the helper (shipped .app) → PATH → the Homebrew
    fallback. Single source of truth for every tmux-touching entry point."""
    if explicit:
        return explicit
    return _bundled_tmux_path() or shutil.which("tmux") or "/opt/homebrew/bin/tmux"


# --- rendered file contents (pure) ----------------------------------------

def render_tmux_conf() -> str:
    """Minimal tmux config for wrapped sessions — invisible chrome so a wrapped
    `claude` looks native; generous scrollback; no key remaps that would surprise
    the user."""
    return (
        "# CLI Pulse wrapped-session tmux config (managed — do not edit).\n"
        "set -g status off\n"                         # no status bar → looks native
        "set -g history-limit 50000\n"
        "set -g mouse on\n"
        'set -g default-terminal "tmux-256color"\n'
        "set -g escape-time 10\n"
        "set -g focus-events on\n"
    )


def render_shell_init(tmux_bin: str, sock: str, conf: str) -> str:
    """POSIX-sh init sourced by the rc block. Defines a wrap helper + one shim
    function per provider. Fails open in every degenerate case."""
    provider_fns = "\n".join(
        f'{p}() {{ _clipulse_wrap {p} {p} "$@"; }}' for p in WRAPPED_PROVIDERS
    )
    return f"""# CLI Pulse shell integration (managed — do not edit; toggle in the app).
# Runs future `claude`/`codex` inside a CLI-Pulse tmux so the app can stream I/O
# and inject remote input. Fails open: runs the real binary if anything is off.
CLIPULSE_TMUX_BIN="${{CLIPULSE_TMUX_BIN:-{tmux_bin}}}"
CLIPULSE_TMUX_SOCK="${{CLIPULSE_TMUX_SOCK:-{sock}}}"
CLIPULSE_TMUX_CONF="${{CLIPULSE_TMUX_CONF:-{conf}}}"

_clipulse_wrap() {{
  # usage: _clipulse_wrap <label> <real-cmd> [args...]
  _clip_label="$1"; shift
  # FAIL OPEN — run the real binary unchanged (never brick the user's command)
  # when: already inside a CLI-Pulse wrap; wrapping disabled; tmux unavailable; OR
  # stdin/stdout is NOT a terminal. The last is CRITICAL: `tmux new-session -A`
  # ATTACHES and needs a controlling tty, so a non-interactive launch (headless
  # `claude -p …`, a pipe, a script, an IDE task) MUST run unwrapped or it breaks.
  # ALSO fail open when the managed tmux CONF was removed (integration turned
  # OFF) — an already-running shell keeps this function; without this guard it
  # would wrap against a deleted -f config and break `claude` (review: codex).
  if [ -n "$CLIPULSE_WRAP_ACTIVE" ] || [ "$CLIPULSE_WRAP_DISABLE" = "1" ] \\
     || [ ! -t 0 ] || [ ! -t 1 ] || [ ! -x "$CLIPULSE_TMUX_BIN" ] \\
     || [ ! -f "$CLIPULSE_TMUX_CONF" ]; then
    command "$@"; return $?
  fi
  _clip_sess="{SESSION_PREFIX}${{_clip_label}}-$$"
  CLIPULSE_WRAP_ACTIVE=1 "$CLIPULSE_TMUX_BIN" -S "$CLIPULSE_TMUX_SOCK" \\
    -f "$CLIPULSE_TMUX_CONF" new-session -A -s "$_clip_sess" \\
    -e CLIPULSE_WRAP_ACTIVE=1 -- "$@"
}}

{provider_fns}
"""


def render_rc_block(init_path: str) -> str:
    """The idempotent marked block added to each rc file — sources the init file
    only if it exists (so a leftover block after a manual dir delete is inert)."""
    return (
        f"{MARKER_BEGIN}\n"
        f'[ -f "{init_path}" ] && . "{init_path}"\n'
        f"{MARKER_END}\n"
    )


# --- install / uninstall / status -----------------------------------------

@dataclass
class IntegrationStatus:
    installed: bool
    init_present: bool
    tmux_bin: str | None
    rc_files_with_block: list[str]
    sock: str


def _rc_targets(home: str | None) -> list[str]:
    h = _home(home)
    targets = [os.path.join(h, rc) for rc in _RC_CANDIDATES if os.path.exists(os.path.join(h, rc))]
    # Always ensure the zsh rc (macOS default login shell) so a first-time user
    # with no rc still gets wrapped.
    zshrc = os.path.join(h, ".zshrc")
    if zshrc not in targets:
        targets.append(zshrc)
    return targets


def _strip_block(text: str) -> str:
    """Remove our marked block (and a trailing blank line we may have added).
    Tolerant of a missing END marker (truncated file)."""
    begin = text.find(MARKER_BEGIN)
    if begin == -1:
        return text
    end = text.find(MARKER_END, begin)
    if end == -1:
        # no end marker — drop from begin to EOL of begin (defensive, minimal)
        eol = text.find("\n", begin)
        cut_end = len(text) if eol == -1 else eol + 1
    else:
        eol = text.find("\n", end)
        cut_end = len(text) if eol == -1 else eol + 1
    before = text[:begin].rstrip("\n")
    after = text[cut_end:].lstrip("\n")
    if before and after:
        return before + "\n\n" + after
    return (before or after) + ("\n" if (before or after) else "")


def install(home: str | None = None, tmux_bin: str | None = None,
            rc_files: list[str] | None = None) -> IntegrationStatus:
    """Write the init file + tmux.conf under ~/.clipulse and add the idempotent
    marked block to the shell rc(s). Never call this except from an explicit
    user opt-in. Returns the resulting status."""
    h = _home(home)
    tb = resolve_tmux_bin(tmux_bin)
    d = clipulse_dir(h)
    os.makedirs(d, exist_ok=True)
    # 0700 — the dir holds the tmux CONTROL socket, which can inject input into
    # the user's agent sessions; keep it strictly user-only (tmux also restricts
    # the socket itself, but defence-in-depth on the container).
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    init_p = init_path(h)
    conf_p = conf_path(h)
    sock = sock_path(h)
    # write managed files (0700 dir already; files 0644 is fine — no secrets)
    with open(conf_p, "w", encoding="utf-8") as f:
        f.write(render_tmux_conf())
    with open(init_p, "w", encoding="utf-8") as f:
        f.write(render_shell_init(tb, sock, conf_p))
    block = render_rc_block(init_p)
    targets = rc_files if rc_files is not None else _rc_targets(h)
    for rc in targets:
        existing = ""
        if os.path.exists(rc):
            with open(rc, encoding="utf-8") as f:
                existing = f.read()
        stripped = _strip_block(existing)              # idempotent: drop any prior block
        body = stripped.rstrip("\n")
        new = (body + "\n\n" if body else "") + block
        with open(rc, "w", encoding="utf-8") as f:
            f.write(new)
    return status(h, rc_files=targets)


def uninstall(home: str | None = None, rc_files: list[str] | None = None,
              remove_dir: bool = True) -> IntegrationStatus:
    """Remove the marked block from every rc file and (optionally) the managed
    ~/.clipulse files. Idempotent — safe if never installed."""
    h = _home(home)
    targets = rc_files if rc_files is not None else _rc_targets(h)
    for rc in targets:
        if not os.path.exists(rc):
            continue
        with open(rc, encoding="utf-8") as f:
            text = f.read()
        new = _strip_block(text)
        if new != text:
            with open(rc, "w", encoding="utf-8") as f:
                f.write(new)
    if remove_dir:
        for p in (init_path(h), conf_path(h)):
            try:
                os.remove(p)
            except FileNotFoundError:
                pass
    return status(h, rc_files=targets)


def status(home: str | None = None, tmux_bin: str | None = None,
           rc_files: list[str] | None = None) -> IntegrationStatus:
    h = _home(home)
    init_p = init_path(h)
    targets = rc_files if rc_files is not None else _rc_targets(h)
    with_block: list[str] = []
    for rc in targets:
        if os.path.exists(rc):
            with open(rc, encoding="utf-8") as f:
                if MARKER_BEGIN in f.read():
                    with_block.append(rc)
    return IntegrationStatus(
        installed=bool(with_block) and os.path.exists(init_p),
        init_present=os.path.exists(init_p),
        # Report a tmux that ACTUALLY EXISTS — the bundled binary (clean Mac,
        # no Homebrew) or one on PATH — but never the may-not-exist Homebrew
        # fallback from resolve_tmux_bin, which would falsely read "installed"
        # (review: codex). None → genuinely "tmux not found".
        tmux_bin=(tmux_bin or _bundled_tmux_path() or shutil.which("tmux")),
        rc_files_with_block=with_block,
        sock=sock_path(h),
    )


def list_wrapped_sessions(tmux_bin: str | None = None, sock: str | None = None) -> list[str]:
    """Enumerate CLI-Pulse-wrapped tmux sessions (name starts with the prefix).
    Returns [] if the socket/server isn't up."""
    tb = resolve_tmux_bin(tmux_bin)
    sk = sock or sock_path()
    try:
        r = subprocess.run([tb, "-S", sk, "list-sessions", "-F", "#{session_name}"],
                           capture_output=True, text=True, timeout=5)
    except (subprocess.SubprocessError, FileNotFoundError, PermissionError):
        return []
    if r.returncode != 0:
        return []
    return [s for s in r.stdout.splitlines() if s.startswith(SESSION_PREFIX)]
