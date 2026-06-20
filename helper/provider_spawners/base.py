"""
Shared spawner base — H-F1 (v1.22).

Until v1.22 every concrete spawner (`claude.py`, `codex.py`, `gemini.py`)
re-implemented the *exact same* argv0-override parsing and
`is_available()` PATH/override probe verbatim. Three copies of identical
security-relevant resolution logic is a maintenance and audit hazard,
and the CLI count is still growing (Aider, OpenCode, Cursor CLI, …), so
the duplication only gets worse. `BaseSpawner` centralizes it so adding
a provider is a ~10-line subclass:

    class FooSpawner(BaseSpawner):
        name = "foo"
        binary = "foo"
        argv0_env = "CLI_PULSE_FOO_ARGV0"

Behaviour is preserved bit-for-bit from the pre-refactor inline paths;
the v1.15 spawner tests pin every observable (argv default, override
tokenization, override+flag compounding, `is_available` truthiness,
`env_overrides` emptiness, `supports_remote_approval` contract) and must
stay green across this refactor.
"""

from __future__ import annotations

import os
import shutil
from typing import Any

# Common CLI install dirs that launchd's minimal PATH omits. `agy` lives
# in /opt/homebrew/bin (Apple-silicon Homebrew); `claude` in ~/.local/bin.
# Without these on PATH the helper's availability probe greys the provider
# out AND the spawned child can't exec the binary — both bugs trace here.
_EXTRA_PATH_DIRS = (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    os.path.expanduser("~/.local/bin"),
)


def augmented_path(base: str | None = None) -> str:
    """`base` PATH (default: the helper process's PATH) with the common
    CLI install dirs APPENDED (not prepended, so a user's explicit PATH
    ordering still wins). Shared by `BaseSpawner.is_available()` and
    `RemoteAgentManager._build_env` so the availability probe and the
    spawn env search the same dirs.
    """
    base = os.environ.get("PATH", "") if base is None else base
    parts = [p for p in base.split(os.pathsep) if p]
    for d in _EXTRA_PATH_DIRS:
        if d and d not in parts:
            parts.append(d)
    return os.pathsep.join(parts)


class BaseSpawner:
    """Default `ProviderSpawner` implementation (see the Protocol in
    `provider_spawners/__init__.py`).

    Subclasses set the three class attributes and override a method only
    when the provider genuinely diverges (e.g. Gemini's `--yolo`, Codex's
    `RUST_BACKTRACE`). The structural-typing Protocol means no explicit
    inheritance is required for registry membership, but inheriting here
    is how we de-duplicate.
    """

    #: Registry key / provider name (lower-case).
    name: str = ""
    #: Default binary resolved on PATH at exec time.
    binary: str = ""
    #: Env var that lets users on uncommon installs point the spawner at
    #: a non-PATH binary. Whitespace-tokenized; first token is the
    #: binary, the rest are leading flags prepended to the manager argv.
    argv0_env: str = ""

    # ── argv0 override resolution (was triplicated) ─────────────

    def _argv0_tokens(self) -> list[str] | None:
        """Tokens from the `argv0_env` override, or None if unset/empty."""
        if not self.argv0_env:
            return None
        override = os.environ.get(self.argv0_env)
        if not override:
            return None
        tokens = override.split()
        return tokens or None

    def argv(self, params: Any) -> list[str]:  # noqa: ARG002
        tokens = self._argv0_tokens()
        if tokens:
            return tokens
        return [self.binary]

    def env_overrides(self, params: Any) -> dict[str, str]:  # noqa: ARG002
        # Most providers need no provider-specific env beyond what the
        # manager injects in `_build_env`. Subclasses override when they
        # genuinely do (Codex → RUST_BACKTRACE).
        return {}

    def is_available(self) -> bool:
        """True if the override OR a PATH binary is runnable.

        Honors the env override so a user with a non-PATH install still
        sees the provider light up in the app's spawn picker, exactly
        as the pre-refactor per-provider copies did.

        Searches `augmented_path()` — launchd's minimal PATH omits
        /opt/homebrew/bin (agy) and ~/.local/bin (claude), so a bare
        `shutil.which` would mark them unavailable even though the child
        spawn (same augmented PATH) could exec them.
        """
        search = augmented_path()
        tokens = self._argv0_tokens()
        if tokens and (
            shutil.which(tokens[0], path=search) is not None
            or (os.path.isabs(tokens[0]) and os.access(tokens[0], os.X_OK))
        ):
            return True
        return bool(self.binary) and shutil.which(self.binary, path=search) is not None

    def supports_remote_approval(self) -> bool:
        # Only providers with a first-class hook protocol the helper can
        # translate to `remote_pending_approvals` return True. Default is
        # False (TUI-inline approval); ClaudeSpawner overrides to True.
        return False
