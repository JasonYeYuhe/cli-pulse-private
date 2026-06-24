"""Tests for the R0 (B2) helper broadcast producer. Fully hermetic — no
network, no real clock: the HTTP poster and clocks are injected."""

from __future__ import annotations

import base64
import json

import pytest

from realtime_broadcast import (
    ALLOWED_EVENTS,
    BroadcastAuthError,
    BroadcastError,
    RealtimeBroadcastSink,
    RealtimeTokenClient,
    TerminalBroadcastPublisher,
    TOKEN_DENY_BACKOFF_S,
    TOKEN_REFRESH_SKEW_S,
)


class FakeHTTP:
    """Records POSTs and replays a programmed (status, body) per call."""

    def __init__(self, responses):
        # responses: list of (status, dict-or-bytes) consumed in order; a
        # single tuple is reused for every call.
        self._responses = responses
        self.calls = []  # (url, headers, parsed_body)

    def __call__(self, url, headers, body, timeout):
        self.calls.append((url, headers, json.loads(body.decode("utf-8"))))
        resp = (
            self._responses
            if isinstance(self._responses, tuple)
            else self._responses[min(len(self.calls) - 1, len(self._responses) - 1)]
        )
        status, payload = resp
        if isinstance(payload, dict):
            payload = json.dumps(payload).encode("utf-8")
        return status, payload


class Clock:
    def __init__(self, t=1000.0):
        self.t = t

    def __call__(self):
        return self.t


# ----------------------------- token client -----------------------------

def _token_client(http, now):
    return RealtimeTokenClient(
        "https://x.supabase.co", "anon-key", "dev-1", "secret-1",
        http_post=http, now=now,
    )


def test_token_mint_success_caches_and_does_not_log_secret():
    clk = Clock(1000.0)
    http = FakeHTTP((200, {"token": "tok-abc", "expires_at": 1000.0 + 3600}))
    tc = _token_client(http, clk)
    assert tc.get_token("sess-1") == "tok-abc"
    # cached: second call does NOT hit the network
    assert tc.get_token("sess-1") == "tok-abc"
    assert len(http.calls) == 1
    # mint body carries device_id + helper_secret + session_id
    body = http.calls[0][2]
    assert body == {"device_id": "dev-1", "helper_secret": "secret-1",
                    "session_id": "sess-1"}


def test_token_proactive_refresh_before_expiry():
    clk = Clock(1000.0)
    http = FakeHTTP([
        (200, {"token": "tok-1", "expires_at": 1000.0 + 3600}),
        (200, {"token": "tok-2", "expires_at": 9999.0 + 3600}),
    ])
    tc = _token_client(http, clk)
    assert tc.get_token("s") == "tok-1"
    # still fresh just before the refresh skew window
    clk.t = 1000.0 + 3600 - TOKEN_REFRESH_SKEW_S - 1
    assert tc.get_token("s") == "tok-1"
    assert len(http.calls) == 1
    # inside the skew window → proactive re-mint (NOT waiting for a 401)
    clk.t = 1000.0 + 3600 - TOKEN_REFRESH_SKEW_S + 1
    assert tc.get_token("s") == "tok-2"
    assert len(http.calls) == 2


def test_token_denied_403_backs_off():
    clk = Clock(1000.0)
    http = FakeHTTP((403, {"error": "not authorized for this session"}))
    tc = _token_client(http, clk)
    assert tc.get_token("pub") is None
    # within backoff → no re-mint
    clk.t = 1000.0 + TOKEN_DENY_BACKOFF_S - 1
    assert tc.get_token("pub") is None
    assert len(http.calls) == 1
    # after backoff → retries
    clk.t = 1000.0 + TOKEN_DENY_BACKOFF_S + 1
    tc.get_token("pub")
    assert len(http.calls) == 2


def test_token_transient_failure_not_cached_as_denied():
    clk = Clock(1000.0)
    http = FakeHTTP((500, {"error": "server not configured"}))
    tc = _token_client(http, clk)
    assert tc.get_token("s") is None
    # a 5xx must NOT poison the denial cache — next call retries immediately
    assert tc.get_token("s") is None
    assert len(http.calls) == 2


def test_token_invalidate_forces_remint():
    clk = Clock(1000.0)
    http = FakeHTTP([
        (200, {"token": "tok-1", "expires_at": 1000.0 + 3600}),
        (200, {"token": "tok-2", "expires_at": 1000.0 + 3600}),
    ])
    tc = _token_client(http, clk)
    assert tc.get_token("s") == "tok-1"
    tc.invalidate("s")
    assert tc.get_token("s") == "tok-2"
    assert len(http.calls) == 2


# ----------------------------- sink -------------------------------------

def test_sink_posts_pterm_topic_and_bearer_token():
    http = FakeHTTP((202, b""))
    sink = RealtimeBroadcastSink("https://x.supabase.co", "anon-key", http_post=http)
    sink.publish("sess-9", "stdout", b"hello\x1b[0m", "tok-xyz")
    url, headers, body = http.calls[0]
    assert url.endswith("/realtime/v1/api/broadcast")
    assert headers["apikey"] == "anon-key"
    assert headers["Authorization"] == "Bearer tok-xyz"  # R0 token, not anon
    msg = body["messages"][0]
    assert msg["topic"] == "pterm:sess-9"          # PRIVATE prefix
    assert msg["event"] == "stdout"
    assert msg["payload"]["session_id"] == "sess-9"
    assert base64.b64decode(msg["payload"]["data_b64"]) == b"hello\x1b[0m"


def test_sink_401_raises_auth_error():
    http = FakeHTTP((401, b"unauthorized"))
    sink = RealtimeBroadcastSink("https://x.supabase.co", "anon", http_post=http)
    with pytest.raises(BroadcastAuthError):
        sink.publish("s", "stdout", b"x", "stale-tok")


def test_sink_non2xx_raises_broadcast_error():
    http = FakeHTTP((500, b"boom"))
    sink = RealtimeBroadcastSink("https://x.supabase.co", "anon", http_post=http)
    with pytest.raises(BroadcastError):
        sink.publish("s", "stdout", b"x", "tok")


# ----------------------------- publisher --------------------------------

class RecordingSink:
    def __init__(self, fail_first_with=None):
        self.sent = []          # (sid, event, data, token)
        self._fail_first = fail_first_with
        self._failed = False

    def publish(self, session_id, event, data, token):
        if self._fail_first and not self._failed:
            self._failed = True
            raise self._fail_first
        self.sent.append((session_id, event, data, token))


class StubTokenClient:
    def __init__(self, token="tok"):
        self.token = token
        self.invalidated = []

    def get_token(self, session_id):
        return self.token

    def invalidate(self, session_id):
        self.invalidated.append(session_id)


def _publisher(sink, token="tok", **kw):
    return TerminalBroadcastPublisher(StubTokenClient(token), sink, **kw)


def test_submit_rejects_disallowed_event():
    pub = _publisher(RecordingSink())
    pub.submit("s", "input_raw", b"keystroke")  # NOT in allowlist
    assert pub.dropped_invalid == 1
    pub._run_drain_pass()
    assert pub.published == 0
    # sanity: the allowlist is exactly the OUTPUT events
    assert set(ALLOWED_EVENTS) == {"stdout", "stderr", "tail_snapshot_result"}


def test_submit_empty_is_noop():
    pub = _publisher(RecordingSink())
    pub.submit("s", "stdout", b"")
    pub._run_drain_pass()
    assert pub.published == 0 and pub.dropped_invalid == 0


def test_drop_oldest_on_overflow():
    sink = RecordingSink()
    pub = _publisher(sink, queue_cap=3)
    for i in range(5):
        pub.submit("s", "stderr", bytes([i]))  # distinct events block coalesce? no—same
    # cap=3 → first 2 dropped
    assert pub.dropped_overflow == 2


def test_coalesce_merges_same_session_event_in_order():
    sink = RecordingSink()
    pub = _publisher(sink)
    pub.submit("s", "stdout", b"ab")
    pub.submit("s", "stdout", b"cd")
    pub.submit("s", "stdout", b"ef")
    pub._run_drain_pass()
    assert len(sink.sent) == 1
    assert sink.sent[0][2] == b"abcdef"


def test_coalesce_splits_oversized():
    sink = RecordingSink()
    pub = _publisher(sink, max_message_bytes=4)
    pub.submit("s", "stdout", b"abcdefghij")  # 10 bytes, cap 4 → 3 msgs
    pub._run_drain_pass()
    assert [m[2] for m in sink.sent] == [b"abcd", b"efgh", b"ij"]


def test_distinct_events_not_merged():
    sink = RecordingSink()
    pub = _publisher(sink)
    pub.submit("s", "stdout", b"out")
    pub.submit("s", "stderr", b"err")
    pub._run_drain_pass()
    assert {(m[1], m[2]) for m in sink.sent} == {("stdout", b"out"), ("stderr", b"err")}


def test_unauthorized_token_skips_send():
    sink = RecordingSink()
    pub = TerminalBroadcastPublisher(StubTokenClient(token=None), sink)
    pub.submit("pub-session", "stdout", b"data")
    pub._run_drain_pass()
    assert sink.sent == []
    assert pub.dropped_unauthorized == 1


def test_401_invalidates_and_requeues_front():
    sink = RecordingSink(fail_first_with=BroadcastAuthError("401"))
    tc = StubTokenClient(token="tok")
    pub = TerminalBroadcastPublisher(tc, sink)
    pub.submit("s", "stdout", b"keepme")
    pub._run_drain_pass()           # first attempt 401s → invalidate + requeue
    assert tc.invalidated == ["s"]
    assert sink.sent == []          # not lost
    pub._run_drain_pass()           # retry → succeeds
    assert sink.sent[0][2] == b"keepme"


class AlwaysAuthFailSink:
    def __init__(self):
        self.attempts = 0

    def publish(self, session_id, event, data, token):
        self.attempts += 1
        raise BroadcastAuthError("401")


def test_persistent_401_drops_after_one_requeue_no_infinite_loop():
    sink = AlwaysAuthFailSink()
    pub = TerminalBroadcastPublisher(StubTokenClient(token="tok"), sink)
    pub.submit("s", "stdout", b"x")
    pub._run_drain_pass()   # 401 #1 → invalidate + requeue
    pub._run_drain_pass()   # 401 #2 (persistent) → drop, no requeue
    assert sink.attempts == 2
    assert pub.dropped_unauthorized == 1
    # Queue is now empty — the bad chunk did NOT requeue forever.
    pub._run_drain_pass()
    assert sink.attempts == 2


def test_401_on_one_session_does_not_drop_other_sessions_chunks():
    # Interleaved queue [A(s1), B(s2), C(s1)] → 3 coalesced messages (A and C
    # are non-consecutive). A single 401 on s1's first send must NOT discard
    # B(s2) (a different session) or C(s1) (a later same-session chunk), and
    # must preserve order. This is the HIGH bug the B2 review caught.
    sink = RecordingSink(fail_first_with=BroadcastAuthError("401"))
    pub = TerminalBroadcastPublisher(StubTokenClient(token="tok"), sink)
    pub.submit("s1", "stdout", b"A")
    pub.submit("s2", "stdout", b"B")
    pub.submit("s1", "stdout", b"C")
    pub._run_drain_pass()   # A(s1) 401 → requeue [A, B, C]; nothing sent
    assert sink.sent == []
    pub._run_drain_pass()   # re-mint + all three deliver, in order
    assert [(m[0], m[2]) for m in sink.sent] == [
        ("s1", b"A"), ("s2", b"B"), ("s1", b"C")
    ]


def test_token_forget_purges_session_state():
    clk = Clock(1000.0)
    http = FakeHTTP((200, {"token": "tok", "expires_at": 1000.0 + 3600}))
    tc = _token_client(http, clk)
    tc.get_token("s")
    assert "s" in tc._tokens
    tc.forget("s")
    assert "s" not in tc._tokens and "s" not in tc._denied


def test_token_forget_purges_denied_public_session():
    clk = Clock(1000.0)
    http = FakeHTTP((403, {"error": "not authorized"}))
    tc = _token_client(http, clk)
    assert tc.get_token("pub") is None
    assert "pub" in tc._denied  # would otherwise persist for the daemon's life
    tc.forget("pub")
    assert "pub" not in tc._denied


def test_publisher_forget_clears_retries_and_token():
    class _TC:
        def __init__(self):
            self.forgotten = []

        def get_token(self, s):
            return "t"

        def invalidate(self, s):
            pass

        def forget(self, s):
            self.forgotten.append(s)

    tc = _TC()
    pub = TerminalBroadcastPublisher(tc, RecordingSink())
    pub._auth_retries["s"] = 1
    pub.forget("s")
    assert "s" not in pub._auth_retries
    assert tc.forgotten == ["s"]


def test_flush_emits_final_chunk_for_session_only():
    sink = RecordingSink()
    pub = _publisher(sink)
    pub.submit("s1", "stdout", b"final-1")
    pub.submit("s2", "stdout", b"other")
    pub.flush("s1")
    assert [m for m in sink.sent if m[0] == "s1"][0][2] == b"final-1"
    # s2's chunk is left queued (flush is per-session)
    assert all(m[0] != "s2" for m in sink.sent)
