"""Tests for `claude_oauth` — managed-session Claude token resolution.

Covers the v-next P0-A contract proven on-device 2026-06-20:
  * read credentials file-first (the file holds the refresh token; the
    keychain item's refreshToken is empty on the affected installs),
  * refresh with the public client_id (a bare body is rejected) and
    handle a ROTATED refresh token,
  * persist the refreshed credential back to the file atomically (0600,
    preserving every other field), and
  * resolve a fresh access token (skip refresh when still valid).

No network: `urlopen` is injected per-test. No real keychain/file: the
credential file path is monkeypatched to a tmp file and the keychain
reader is stubbed.
"""
from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import claude_oauth as co  # noqa: E402

_FRESH_AT = "sk-ant-oat01-FRESHaccess"
_ROTATED_RT = "sk-ant-ort01-ROTATEDrefresh"


# ── fixtures / stubs ────────────────────────────────────────────────


class _Resp:
    def __init__(self, payload: dict) -> None:
        self._payload = json.dumps(payload).encode()

    def read(self) -> bytes:
        return self._payload

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def _urlopen_ok(payload: dict, capture: list | None = None):
    def _open(req, timeout=10):
        if capture is not None:
            capture.append(req)
        return _Resp(payload)
    return _open


def _urlopen_fail(exc: Exception):
    def _open(req, timeout=10):
        raise exc
    return _open


def _write_creds(path: Path, oauth: dict, *, extra_top: dict | None = None) -> None:
    doc = {"claudeAiOauth": oauth}
    if extra_top:
        doc.update(extra_top)
    path.write_text(json.dumps(doc))
    os.chmod(path, 0o600)


@pytest.fixture
def creds_file(tmp_path, monkeypatch):
    p = tmp_path / ".credentials.json"
    monkeypatch.setattr(co, "_CREDENTIALS_FILE", str(p))
    # Default: keychain has nothing (the affected-install reality).
    monkeypatch.setattr(co, "_read_keychain_oauth", lambda: None)
    return p


@pytest.fixture
def clock(monkeypatch):
    # Realistic epoch so `expiresAt` (ms = now*1000 ≈ 1.7e12) trips the
    # ms-vs-seconds heuristic in `_exp_to_secs` the way real creds do.
    state = {"now": 1_700_000_000.0}
    monkeypatch.setattr(co, "_now", lambda: state["now"])
    return state


# ── read_claude_oauth ───────────────────────────────────────────────


def test_read_prefers_file_with_refresh_token(creds_file):
    _write_creds(creds_file, {
        "accessToken": "sk-ant-oat01-A", "refreshToken": "sk-ant-ort01-R",
        "expiresAt": 9_999_999_999_000,
    })
    oauth, source = co.read_claude_oauth()
    assert source == "file"
    assert co._refresh_of(oauth) == "sk-ant-ort01-R"


def test_read_falls_back_to_keychain_when_file_lacks_refresh(creds_file, monkeypatch):
    # File has an EMPTY refresh token (the keychain-vs-file inversion).
    _write_creds(creds_file, {"accessToken": "sk-ant-oat01-A", "refreshToken": ""})
    monkeypatch.setattr(co, "_read_keychain_oauth", lambda: {
        "accessToken": "sk-ant-oat01-KC", "refreshToken": "sk-ant-ort01-KCR",
    })
    oauth, source = co.read_claude_oauth()
    assert source == "keychain"
    assert co._refresh_of(oauth) == "sk-ant-ort01-KCR"


def test_read_returns_none_when_nothing(creds_file):
    oauth, source = co.read_claude_oauth()
    assert oauth is None and source is None


# ── refresh_claude_token ────────────────────────────────────────────


def test_refresh_includes_client_id_in_body(creds_file):
    cap: list = []
    resp = co.refresh_claude_token(
        "sk-ant-ort01-R",
        urlopen=_urlopen_ok({"access_token": _FRESH_AT, "refresh_token": _ROTATED_RT,
                             "expires_in": 28800}, capture=cap),
    )
    assert resp["access_token"] == _FRESH_AT
    assert resp["refresh_token"] == _ROTATED_RT
    # client_id is REQUIRED — assert it's in the posted body.
    body = json.loads(cap[0].data.decode())
    assert body["client_id"] == co.CLAUDE_CODE_CLIENT_ID
    assert body["grant_type"] == "refresh_token"
    assert body["refresh_token"] == "sk-ant-ort01-R"


def test_refresh_returns_none_without_refresh_token(creds_file):
    assert co.refresh_claude_token("", urlopen=_urlopen_ok({})) is None


def test_refresh_returns_none_on_non_oauth_token(creds_file):
    # A response whose access_token isn't an sk-ant-oat* token is ignored.
    assert co.refresh_claude_token(
        "r", urlopen=_urlopen_ok({"access_token": "garbage"})
    ) is None


def test_refresh_tries_second_endpoint_on_first_failure(creds_file, monkeypatch):
    calls: list = []

    def _open(req, timeout=10):
        calls.append(req.full_url)
        if len(calls) == 1:
            raise OSError("first endpoint down")
        return _Resp({"access_token": _FRESH_AT, "refresh_token": _ROTATED_RT,
                      "expires_in": 28800})

    resp = co.refresh_claude_token("r", urlopen=_open)
    assert resp and resp["access_token"] == _FRESH_AT
    assert len(calls) == 2  # fell through to the second endpoint


# ── resolve_fresh_claude_access_token ───────────────────────────────


def test_resolve_skips_refresh_when_valid(creds_file, clock):
    # Token valid for another hour → no network, returns it as-is.
    _write_creds(creds_file, {
        "accessToken": "sk-ant-oat01-VALID", "refreshToken": "sk-ant-ort01-R",
        "expiresAt": int((clock["now"] + 3600) * 1000),
    })

    def _boom(req, timeout=10):
        raise AssertionError("must not refresh a still-valid token")

    assert co.resolve_fresh_claude_access_token(urlopen=_boom) == "sk-ant-oat01-VALID"


def test_resolve_refreshes_and_persists_when_expired(creds_file, clock):
    _write_creds(
        creds_file,
        {
            "accessToken": "sk-ant-oat01-OLD", "refreshToken": "sk-ant-ort01-OLD",
            "expiresAt": int((clock["now"] - 3600) * 1000),  # expired 1h ago
            "scopes": ["user:inference"], "subscriptionType": "max",
        },
        extra_top={"mcpOAuth": {"keep": "me"}},
    )
    token = co.resolve_fresh_claude_access_token(
        urlopen=_urlopen_ok({"access_token": _FRESH_AT, "refresh_token": _ROTATED_RT,
                             "expires_in": 28800}),
    )
    assert token == _FRESH_AT
    # Persisted: rotated refresh + new access + recomputed expiry, with
    # every other field (mcpOAuth, scopes, subscriptionType) preserved.
    doc = json.loads(creds_file.read_text())
    o = doc["claudeAiOauth"]
    assert o["accessToken"] == _FRESH_AT
    assert o["refreshToken"] == _ROTATED_RT
    assert o["expiresAt"] == int((clock["now"] + 28800) * 1000)
    assert o["scopes"] == ["user:inference"]
    assert o["subscriptionType"] == "max"
    assert doc["mcpOAuth"] == {"keep": "me"}
    # Still 0600.
    assert stat.S_IMODE(os.stat(creds_file).st_mode) == 0o600


def test_resolve_returns_stale_token_when_refresh_fails(creds_file, clock):
    _write_creds(creds_file, {
        "accessToken": "sk-ant-oat01-STALE", "refreshToken": "sk-ant-ort01-R",
        "expiresAt": int((clock["now"] - 10) * 1000),
    })
    token = co.resolve_fresh_claude_access_token(
        urlopen=_urlopen_fail(OSError("network down")),
    )
    # Falls back to the stale token (no worse than injecting nothing); the
    # file is NOT rewritten.
    assert token == "sk-ant-oat01-STALE"
    assert json.loads(creds_file.read_text())["claudeAiOauth"]["accessToken"] == "sk-ant-oat01-STALE"


def test_resolve_returns_none_without_credentials(creds_file):
    assert co.resolve_fresh_claude_access_token(urlopen=_urlopen_ok({})) is None


def test_resolve_does_not_leak_token_via_logs(creds_file, clock, caplog):
    _write_creds(creds_file, {
        "accessToken": "sk-ant-oat01-OLD", "refreshToken": "sk-ant-ort01-OLD",
        "expiresAt": int((clock["now"] - 10) * 1000),
    })
    with caplog.at_level("DEBUG"):
        co.resolve_fresh_claude_access_token(
            urlopen=_urlopen_ok({"access_token": _FRESH_AT, "refresh_token": _ROTATED_RT,
                                 "expires_in": 28800}),
        )
    blob = "\n".join(r.getMessage() for r in caplog.records)
    assert _FRESH_AT not in blob
    assert _ROTATED_RT not in blob
    assert "sk-ant-ort01-OLD" not in blob


def test_persist_is_atomic_no_partial_on_serialize_failure(creds_file, clock, monkeypatch):
    _write_creds(creds_file, {
        "accessToken": "sk-ant-oat01-OLD", "refreshToken": "sk-ant-ort01-OLD",
        "expiresAt": int((clock["now"] - 10) * 1000),
    })
    original = creds_file.read_text()

    # Force the temp-file write to blow up after mkstemp; the original
    # must remain intact (atomic replace never happened) + no .tmp leak.
    real_dump = co.json.dump

    def _boom_dump(obj, fp):
        raise OSError("disk full")

    monkeypatch.setattr(co.json, "dump", _boom_dump)
    ok = co._persist_refreshed_to_file({"access_token": _FRESH_AT, "expires_in": 1})
    monkeypatch.setattr(co.json, "dump", real_dump)
    assert ok is False
    assert creds_file.read_text() == original
    leftover = [p for p in creds_file.parent.iterdir() if p.name.endswith(".tmp")]
    assert leftover == []
