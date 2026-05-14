"""Local control auth token for the helper UDS server.

Phase 3 Iter 1 introduces a same-machine fast path: the macOS app talks
to the helper over a Unix domain socket inside the app group container,
bypassing Supabase for keystroke-level latency. Same-machine does NOT
mean trusted: any other process on the Mac can `connect(2)` to the
socket. We require every UDS request to carry a 32-byte auth token that
the helper rotates on every startup and writes — mode 0600 — into the
app group container the macOS app can read via its sandbox entitlement.

This is **local** authentication only. Do not confuse it with the paired
device `helper_secret` (which is a SHA-256 hex digest the Supabase RPCs
verify). The two have different threat models, different rotation
schedules, and different storage locations.
"""
from __future__ import annotations

import base64
import hmac
import logging
import os
import secrets
from pathlib import Path

logger = logging.getLogger("cli_pulse.local_auth_token")

# Length of the raw random token in bytes. 32 bytes = 256 bits of
# entropy; far above any plausible online-guessing threat model and
# matches the modern secret-token convention. Encoded form is 44
# characters of unpadded base64 (we keep padding for round-trip
# convenience).
TOKEN_BYTES = 32

# App group container the macOS sandbox entitlement grants both the app
# and the helper read/write access to. Same path family the existing
# config and the Phase 3 spike use.
APP_GROUP_ID = "group.yyh.CLI-Pulse"
TOKEN_FILENAME = "helper-auth-token"


def container_path() -> Path:
    """Return the app group container directory used by both the macOS
    app and the helper. Resolves under `$HOME` so test rigs can point
    `HOME` at a temp directory.
    """
    return Path.home() / "Library" / "Group Containers" / APP_GROUP_ID


def token_path() -> Path:
    return container_path() / TOKEN_FILENAME


def rotate_token(path: Path | None = None) -> str:
    """Generate a fresh token, write it (mode 0600) at `path`, and
    return the base64-encoded form so the caller can keep it in
    memory for `compare()`.

    Rotates unconditionally — every helper restart invalidates the
    previous token. The macOS app reads the file on each request, so
    the rotation is transparent to the user.

    Creates the parent directory if it doesn't exist (the app may not
    have launched yet when the user starts the helper from CLI).
    """
    if path is None:
        path = token_path()
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True)

    raw = secrets.token_bytes(TOKEN_BYTES)
    encoded = base64.b64encode(raw).decode("ascii")
    # v1.20.1 C6: write the tmp file via low-level os.open with mode 0o600
    # at create time, then rename. The previous `tmp.write_text() + chmod`
    # sequence created the file at the process umask (typically 0o022,
    # i.e. world-readable) for the brief window between write and chmod.
    # A local user with fswatch/inotify on the parent directory could race
    # the read and capture the helper auth token, which grants full PTY
    # control of any managed CLI session.
    tmp = path.with_suffix(path.suffix + ".tmp")
    # O_NOFOLLOW defends against a symlink swap targeting a privileged path.
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    fd = os.open(str(tmp), flags, 0o600)
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(encoded)
    except BaseException:
        # If write failed mid-flight, close + unlink so we don't leave
        # a zero-byte token tmp file lying around for the next rotation.
        try:
            os.unlink(str(tmp))
        except FileNotFoundError:
            pass
        raise
    tmp.replace(path)
    # `replace()` preserves the destination's mode on some platforms;
    # re-chmod the final path to be defensive against an existing path
    # that already had wider permissions (e.g. a prior buggy build).
    os.chmod(path, 0o600)
    logger.info("rotated local auth token at %s", path)
    return encoded


def load_token(path: Path | None = None) -> str | None:
    """Read the on-disk token (no validation). Returns None if the
    file is missing — caller decides whether that's fatal.
    """
    if path is None:
        path = token_path()
    try:
        return path.read_text().strip() or None
    except FileNotFoundError:
        return None
    except OSError as exc:
        logger.warning("load_token(%s) failed: %s", path, exc)
        return None


def compare(expected: str, supplied: str) -> bool:
    """Constant-time comparison of two base64-encoded tokens.

    Uses `hmac.compare_digest` to defeat the timing oracle a naïve
    `==` comparison would expose. Empty/None inputs always return
    False — defenders in depth: a missing token must never authenticate
    """
    if not expected or not supplied:
        return False
    return hmac.compare_digest(expected, supplied)
