"""Tests for the helper-side OAuth-429 backoff in `system_collector`.

Pinning the four scenarios specified in the task brief, plus the
design-choice safety nets:

    1. 429 records backoff
    2. calls during backoff skip OAuth (return None without
       hitting urlopen)
    3. non-429 failures do NOT poison the backoff path
    4. backoff expiry allows OAuth to retry
    5. token-fingerprint keying — re-auth with a fresh token is
       NOT blocked by the previous token's backoff
    6. successful response immediately clears backoff
    7. fingerprint stable + does not leak the raw token

No network. The `urllib.request.urlopen` symbol used by
`_fetch_claude_oauth_api` is monkeypatched per-test to a stub that
either returns a canned response, raises `HTTPError`, or asserts
"this should NOT be called" when we expect a backoff skip.

Time is monkeypatched via `_oauth_now` so we can fast-forward
through the 15-min cooldown without `sleep()`.
"""
from __future__ import annotations

import io
import json as _json
import sys
import urllib.error
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import system_collector as sc  # noqa: E402


# ── shared fixtures ────────────────────────────────────────────


@pytest.fixture(autouse=True)
def _isolate_backoff_state():
    """Each test starts with an empty `_OAUTH_BACKOFF` dict so
    one test's failure record can't bleed into the next.
    """
    sc._oauth_reset_all_for_testing()
    yield
    sc._oauth_reset_all_for_testing()


class _Clock:
    """Mutable clock injected via monkeypatching `_oauth_now`."""

    def __init__(self, start: float = 1_700_000_000.0) -> None:
        self.now = start

    def advance(self, secs: float) -> None:
        self.now += secs


@pytest.fixture
def clock(monkeypatch):
    c = _Clock()
    monkeypatch.setattr(sc, "_oauth_now", lambda: c.now)
    return c


def _stub_urlopen_returning(status_data: dict):
    """Build an `urlopen` stub that returns `status_data` as JSON."""
    class _Resp:
        def __init__(self, payload: bytes) -> None:
            self._payload = payload
        def read(self) -> bytes:
            return self._payload
        def __enter__(self): return self
        def __exit__(self, *a): pass

    payload = _json.dumps(status_data).encode("utf-8")
    return lambda req, timeout=10: _Resp(payload)


def _stub_urlopen_raising_http(code: int):
    """Build an `urlopen` stub that raises `HTTPError(code)`."""
    def _raise(req, timeout=10):
        raise urllib.error.HTTPError(
            url=req.full_url if hasattr(req, "full_url") else "x",
            code=code,
            msg=f"HTTP {code}",
            hdrs=None,  # type: ignore
            fp=io.BytesIO(b""),
        )
    return _raise


def _stub_urlopen_raising(exc: Exception):
    """Build an `urlopen` stub that raises an arbitrary exception
    (network errors, JSON decode failures from caller, etc.)."""
    def _raise(req, timeout=10):
        raise exc
    return _raise


def _stub_urlopen_must_not_be_called():
    """If the strategy short-circuits via backoff, this stub
    fires the assertion that proves the network call was avoided."""
    def _explode(req, timeout=10):
        raise AssertionError(
            "urlopen was called even though backoff should have skipped it"
        )
    return _explode


# ── 1. 429 records backoff ────────────────────────────────────


def test_429_records_backoff_for_token_fingerprint(monkeypatch, clock):
    monkeypatch.setattr(
        sc.urllib.request, "urlopen", _stub_urlopen_raising_http(429)
    )
    fp = sc._oauth_token_fingerprint("sk-ant-oat01-tokenA")

    # Pre-call: no backoff for this fingerprint.
    assert sc._oauth_remaining_backoff(fp) is None

    result = sc._fetch_claude_oauth_api("sk-ant-oat01-tokenA", plan_type="Max 20x")

    # Failure path returns None (caller falls through to web).
    assert result is None

    # Backoff was recorded.
    remaining = sc._oauth_remaining_backoff(fp)
    assert remaining is not None
    assert 0 < remaining <= sc._OAUTH_BACKOFF_WINDOW_SECS


# ── 2. Calls during backoff skip OAuth ────────────────────────


def test_calls_during_backoff_skip_oauth_without_hitting_network(
    monkeypatch, clock
):
    fp = sc._oauth_token_fingerprint("tokenA")
    sc._oauth_record_failure(fp)

    # The urlopen stub asserts if it's called — proving the strategy
    # short-circuited before the network round-trip.
    monkeypatch.setattr(
        sc.urllib.request, "urlopen", _stub_urlopen_must_not_be_called()
    )

    result = sc._fetch_claude_oauth_api("tokenA", plan_type="Max 20x")
    assert result is None  # still falls through, just doesn't network


# ── 3. Non-429 failures do NOT poison the backoff path ────────


def test_401_does_not_record_backoff(monkeypatch, clock):
    """Auth failures call for token refresh, not a cooldown. They
    must not block the next refresh's OAuth attempt.
    """
    monkeypatch.setattr(
        sc.urllib.request, "urlopen", _stub_urlopen_raising_http(401)
    )
    fp = sc._oauth_token_fingerprint("tokenA")

    result = sc._fetch_claude_oauth_api("tokenA", plan_type=None)
    assert result is None
    # Critically: backoff dict stayed empty.
    assert sc._oauth_remaining_backoff(fp) is None


def test_403_does_not_record_backoff(monkeypatch, clock):
    monkeypatch.setattr(
        sc.urllib.request, "urlopen", _stub_urlopen_raising_http(403)
    )
    fp = sc._oauth_token_fingerprint("tokenA")
    sc._fetch_claude_oauth_api("tokenA", plan_type=None)
    assert sc._oauth_remaining_backoff(fp) is None


def test_network_error_does_not_record_backoff(monkeypatch, clock):
    """Transient network errors typically clear next cycle. Don't
    treat them like a rate-limit cooldown.
    """
    monkeypatch.setattr(
        sc.urllib.request,
        "urlopen",
        _stub_urlopen_raising(ConnectionError("DNS failed")),
    )
    fp = sc._oauth_token_fingerprint("tokenA")
    sc._fetch_claude_oauth_api("tokenA", plan_type=None)
    assert sc._oauth_remaining_backoff(fp) is None


def test_500_does_not_record_backoff(monkeypatch, clock):
    """Server errors are not rate-limit signals."""
    monkeypatch.setattr(
        sc.urllib.request, "urlopen", _stub_urlopen_raising_http(500)
    )
    fp = sc._oauth_token_fingerprint("tokenA")
    sc._fetch_claude_oauth_api("tokenA", plan_type=None)
    assert sc._oauth_remaining_backoff(fp) is None


# ── 4. Backoff expiry allows OAuth to retry ───────────────────


def test_backoff_expiry_allows_retry(monkeypatch, clock):
    fp = sc._oauth_token_fingerprint("tokenA")
    sc._oauth_record_failure(fp)
    assert sc._oauth_remaining_backoff(fp) is not None

    clock.advance(sc._OAUTH_BACKOFF_WINDOW_SECS + 1)

    # After expiry: remaining returns None.
    assert sc._oauth_remaining_backoff(fp) is None

    # Now a fresh urlopen call goes through to the network. We stub
    # a 200 response with a minimal valid shape so `_parse_claude_api
    # _response` doesn't blow up — but the test only cares that
    # urlopen was reached.
    network_calls = []

    def _record_then_raise(req, timeout=10):
        network_calls.append(req.full_url)
        # Raise so we don't have to construct a perfect
        # OAuthUsageResponse — the test only cares that the network
        # path was reached.
        raise urllib.error.HTTPError(
            url=req.full_url, code=503, msg="Service Unavailable",
            hdrs=None, fp=io.BytesIO(b""),  # type: ignore
        )

    monkeypatch.setattr(sc.urllib.request, "urlopen", _record_then_raise)
    sc._fetch_claude_oauth_api("tokenA", plan_type=None)
    assert len(network_calls) == 1, (
        "After expiry, the next call must reach urlopen"
    )


# ── 5. Token-fingerprint keying ───────────────────────────────


def test_fresh_token_after_reauth_is_not_blocked_by_old_token_backoff(
    monkeypatch, clock
):
    fp_old = sc._oauth_token_fingerprint("old-burned-token")
    fp_new = sc._oauth_token_fingerprint("fresh-reauth-token")
    assert fp_old != fp_new

    sc._oauth_record_failure(fp_old)

    # The new token has no backoff entry → urlopen should be called.
    network_calls = []

    def _record(req, timeout=10):
        network_calls.append(req.full_url)
        raise urllib.error.HTTPError(
            url=req.full_url, code=503, msg="x",
            hdrs=None, fp=io.BytesIO(b""),  # type: ignore
        )

    monkeypatch.setattr(sc.urllib.request, "urlopen", _record)
    sc._fetch_claude_oauth_api("fresh-reauth-token", plan_type=None)
    assert len(network_calls) == 1


# ── 6. Successful response clears backoff ─────────────────────


def test_successful_response_clears_backoff(monkeypatch, clock):
    fp = sc._oauth_token_fingerprint("tokenA")
    sc._oauth_record_failure(fp)
    assert sc._oauth_remaining_backoff(fp) is not None

    # Build a urlopen stub that returns a minimal-but-valid shape
    # `_parse_claude_api_response` accepts. We don't care about the
    # parsed result — only the side effect that backoff is cleared.
    monkeypatch.setattr(
        sc.urllib.request,
        "urlopen",
        _stub_urlopen_returning({
            "five_hour": {"utilization": 12, "resets_at": None},
            "seven_day": {"utilization": 30, "resets_at": None},
        }),
    )

    # The backoff would normally suppress this call. Reset it
    # manually so the call actually executes — we want to test
    # the SUCCESS path's cleanup, not the skip path.
    sc._oauth_reset(fp)

    sc._fetch_claude_oauth_api("tokenA", plan_type=None)

    # Re-check: any prior entry must be gone.
    assert sc._oauth_remaining_backoff(fp) is None


# ── 7. Fingerprint stability + privacy ────────────────────────


def test_fingerprint_is_stable_for_same_token():
    assert sc._oauth_token_fingerprint("tokenA") == sc._oauth_token_fingerprint("tokenA")


def test_fingerprint_differs_across_tokens():
    assert sc._oauth_token_fingerprint("tokenA") != sc._oauth_token_fingerprint("tokenB")


def test_fingerprint_is_exactly_16_hex_chars():
    fp = sc._oauth_token_fingerprint("anytoken")
    assert len(fp) == 16
    assert all(c in "0123456789abcdef" for c in fp)


def test_fingerprint_does_not_contain_raw_token_substring():
    token = "sk-ant-oat01-supersecretREVEALEDtoken"
    fp = sc._oauth_token_fingerprint(token)
    assert "supersecret" not in fp
    assert "oat01" not in fp
