"""Tests for the local auth-token store.

Covers:
  - rotate_token writes a base64-encoded token to a 0600 file
  - load_token round-trips the same value
  - rotate_token replaces an existing token (every helper restart
    invalidates the previous one)
  - compare uses constant-time comparison via hmac.compare_digest
    (we can't time the comparison portably, but we assert the
    semantic: identical strings match, off-by-one strings don't)
  - empty / None inputs always return False
"""
from __future__ import annotations

import base64
import os
import stat
import sys
from pathlib import Path


HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from local_auth_token import (  # noqa: E402
    TOKEN_BYTES,
    compare,
    load_token,
    rotate_token,
)


def test_rotate_token_writes_file_mode_0600(tmp_path: Path):
    target = tmp_path / "container" / "helper-auth-token"
    encoded = rotate_token(target)
    assert target.exists()
    mode = stat.S_IMODE(os.stat(target).st_mode)
    assert mode == 0o600, f"expected 0600, got {mode:o}"
    # Decoded form should be exactly TOKEN_BYTES of entropy.
    raw = base64.b64decode(encoded)
    assert len(raw) == TOKEN_BYTES


def test_rotate_token_creates_parent_directory(tmp_path: Path):
    # Container path may not exist on a fresh helper-only install.
    target = tmp_path / "deep" / "nested" / "container" / "token"
    rotate_token(target)
    assert target.exists()


def test_load_token_round_trip(tmp_path: Path):
    target = tmp_path / "tok"
    written = rotate_token(target)
    assert load_token(target) == written


def test_rotate_token_replaces_existing(tmp_path: Path):
    target = tmp_path / "tok"
    first = rotate_token(target)
    second = rotate_token(target)
    assert first != second
    assert load_token(target) == second


def test_load_token_missing_returns_none(tmp_path: Path):
    assert load_token(tmp_path / "does-not-exist") is None


def test_compare_matches_identical():
    a = "abc123"
    assert compare(a, a) is True


def test_compare_rejects_off_by_one():
    a = "abc123"
    b = "abc124"
    assert compare(a, b) is False


def test_compare_rejects_empty_inputs():
    assert compare("", "anything") is False
    assert compare("anything", "") is False
    assert compare("", "") is False
    # Use type-friendly empty-ish values that the production helper
    # never sees but defenders-in-depth should still reject.
    assert compare(None, "x") is False  # type: ignore[arg-type]
    assert compare("x", None) is False  # type: ignore[arg-type]


def test_compare_uses_hmac_compare_digest(monkeypatch):
    """Behavioral check: replace hmac.compare_digest with a sentinel
    that would let an obviously-wrong pair through, then prove our
    function calls *that* function path rather than a naïve `==`.
    """
    import hmac as _hmac

    calls: list[tuple[str, str]] = []

    def fake(a, b):
        calls.append((a, b))
        return True

    monkeypatch.setattr(_hmac, "compare_digest", fake)
    # Re-import to re-bind compare's reference if needed; the module
    # called `from hmac import compare_digest` style? Check:
    # local_auth_token does `import hmac` then `hmac.compare_digest`.
    # Monkeypatching `hmac.compare_digest` is the right surface.
    assert compare("clearly-not", "the-same") is True  # via fake
    assert calls == [("clearly-not", "the-same")]
