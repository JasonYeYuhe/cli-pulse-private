"""R0 (B2) — Python helper terminal-broadcast producer + scoped-token auth.

Route A (DEV_PLAN_R0_…2026-06-22.md §1): the SHIPPED helper is Python, and it
had NO Realtime producer (only the unshipped Swift HelperKit did). This module
ports the proven Swift reference (`TerminalBroadcastPublisher` +
`SupabaseRealtimeBroadcastSink`) and adds the R0 per-subscriber auth.

OUTPUT-ONLY: streams the already-redacted raw terminal bytes to the PRIVATE
`pterm:<session_id>` Realtime topic (RLS-governed) so an iPhone can mirror the
session securely. Input keystrokes stay on the command RPC — never here.

Auth (R0 §2): the helper can't mint a JWT in SQL, so it asks the
`mint-realtime-token` edge fn (device_id + helper_secret + session_id) for a
short-lived ES256 token and sends it as the broadcast `Authorization: Bearer`.
The edge fn's gate (`remote_helper_authorize_broadcast`) only authorizes
PRIVATE sessions — so a public session's mint returns 403 and we simply don't
broadcast it (it stays on the legacy DB-event path). The token is refreshed
PROACTIVELY before expiry (not reactively on 401), and a 401 that slips through
requeues the chunk rather than dropping it.

Gate: `HelperConfig.remote_realtime_broadcast_enabled` — DEFAULT ON since
helper 1.24.0 (S3 fleet flip); False is the ops kill switch. When off: zero
broadcasts, zero edge-fn calls. Even when on, only sessions whose start payload
marked them PRIVATE ever reach this module (the `_post_stdout_chunk` local gate).

NEVER logs the token or the helper_secret.
"""

from __future__ import annotations

import base64
import json
import logging
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from typing import Callable, Deque, Optional

logger = logging.getLogger("cli_pulse_helper.realtime_broadcast")

# Coalesce window: batch chunks that arrive within ~60 ms into one broadcast.
# Humans don't perceive the batching on OUTPUT (Gemini), and it keeps the POST
# rate sane (R0 §2 / spec §3b: "output-coalesce ~50-80 ms").
COALESCE_WINDOW_S = 0.06
# Bounded per-publisher queue; drop OLDEST on overflow (a laggy sink must never
# back-pressure the PTY drain — reconnect-snapshot is the recovery path).
QUEUE_CAP_MESSAGES = 256
# Per-message payload cap (pre-base64). A coalesced buffer that would exceed
# this is split into multiple messages so one giant chunk can't be rejected.
MAX_MESSAGE_BYTES = 48 * 1024
# Helper-side event allowlist (R0 §2.7 — the direct-HTTP path can't enforce it
# server-side; ownership is closed by write-RLS, shape is validated here).
ALLOWED_EVENTS = ("stdout", "stderr", "tail_snapshot_result")
# Refresh the token this many seconds BEFORE it expires (proactive — Gemini
# HIGH). For a ~1 h token this fires at ~45 min, well clear of in-flight bursts.
TOKEN_REFRESH_SKEW_S = 900
# After an auth denial (403 = not private / not owned), don't re-mint for this
# long — avoids hammering the edge fn for a public session every chunk.
TOKEN_DENY_BACKOFF_S = 300
# Max consecutive 401 requeues for a session before dropping the chunk. ONE
# requeue covers a token-rotation race (re-mint + retry); a SECOND consecutive
# 401 means a persistent misconfig (wrong aud/role) — drop rather than spin.
MAX_AUTH_REQUEUE = 1
# Per-request HTTP timeout for the mint + broadcast calls.
HTTP_TIMEOUT_S = 2.5


class BroadcastAuthError(Exception):
    """The broadcast token was rejected (HTTP 401). Caller should invalidate
    the cached token and requeue the chunk (NOT drop it)."""


class BroadcastError(Exception):
    """Any other broadcast failure (transport / non-2xx). Chunk is dropped;
    reconnect tail-snapshot recovers."""


def _default_http_post(
    url: str, headers: dict[str, str], body: bytes, timeout: float
) -> tuple[int, bytes]:
    """urllib POST → (status, body_bytes). Raises only on transport error;
    HTTP error statuses are returned (so callers classify 401 vs 403 vs 5xx)."""
    req = urllib.request.Request(url=url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as err:
        return err.code, err.read()
    except (urllib.error.URLError, TimeoutError) as err:
        raise BroadcastError(f"transport: {err}") from err


class RealtimeTokenClient:
    """Mints + caches the R0 broadcast token per session, with proactive
    pre-expiry refresh and a denial backoff. Hermetic: inject `http_post`
    (and `now`) so tests never touch the network or the wall clock."""

    def __init__(
        self,
        supabase_url: str,
        anon_key: str,
        device_id: str,
        helper_secret: str,
        *,
        http_post: Callable[[str, dict[str, str], bytes, float], tuple[int, bytes]]
        | None = None,
        now: Callable[[], float] = time.time,
    ) -> None:
        self._url = supabase_url.rstrip("/") + "/functions/v1/mint-realtime-token"
        self._anon = anon_key
        self._device_id = device_id
        self._helper_secret = helper_secret
        self._http_post = http_post or _default_http_post
        self._now = now
        self._lock = threading.Lock()
        # session_id -> (token, expires_at_unix)
        self._tokens: dict[str, tuple[str, float]] = {}
        # session_id -> denied_until_unix
        self._denied: dict[str, float] = {}

    def get_token(self, session_id: str) -> Optional[str]:
        """A valid cached token, refreshing proactively if near expiry; or a
        freshly minted one. None if the session isn't authorized (denied, in
        backoff) or a transient mint failure — caller skips the broadcast."""
        now = self._now()
        with self._lock:
            denied_until = self._denied.get(session_id)
            if denied_until is not None and now < denied_until:
                return None
            cached = self._tokens.get(session_id)
            if cached is not None and now < cached[1] - TOKEN_REFRESH_SKEW_S:
                return cached[0]
        # Mint outside the lock (network).
        return self._mint(session_id, now)

    def invalidate(self, session_id: str) -> None:
        """Drop the cached token so the next get_token re-mints (called after a
        401 from the broadcast endpoint)."""
        with self._lock:
            self._tokens.pop(session_id, None)

    def forget(self, session_id: str) -> None:
        """Purge ALL cached + denial state for an ended session, so the
        long-lived daemon's dicts stay bounded to LIVE sessions (a public
        session's denial entry would otherwise persist for the daemon's life)."""
        with self._lock:
            self._tokens.pop(session_id, None)
            self._denied.pop(session_id, None)

    def _mint(self, session_id: str, now: float) -> Optional[str]:
        body = json.dumps(
            {
                "device_id": self._device_id,
                "helper_secret": self._helper_secret,
                "session_id": session_id,
            }
        ).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "apikey": self._anon,
            "Authorization": f"Bearer {self._anon}",
        }
        try:
            status, resp = self._http_post(self._url, headers, body, HTTP_TIMEOUT_S)
        except BroadcastError as exc:
            # Transient (network) — don't poison the denial cache; retry later.
            logger.debug("mint transport failure for %s: %s", session_id, exc)
            return None
        if status == 200:
            try:
                data = json.loads(resp.decode("utf-8"))
                token = data["token"]
                expires_at = float(data["expires_at"])
            except (ValueError, KeyError, TypeError) as exc:
                # Log the error TYPE only — the 200 body carries the token, so
                # never echo it (even a parse-error snippet) into a log.
                logger.debug(
                    "mint bad response for %s: %s", session_id, type(exc).__name__
                )
                return None
            with self._lock:
                self._tokens[session_id] = (token, expires_at)
                self._denied.pop(session_id, None)
            return token
        if status in (401, 403):
            # Not a private/owned session (or bad secret) — back off, don't
            # broadcast. NEVER log the response body (could echo internals).
            with self._lock:
                self._denied[session_id] = now + TOKEN_DENY_BACKOFF_S
                self._tokens.pop(session_id, None)
            logger.debug("mint denied (%s) for %s — backing off", status, session_id)
            return None
        # 5xx / misconfig — transient; retry next chunk (no denial cache).
        logger.debug("mint failed (%s) for %s", status, session_id)
        return None


class RealtimeBroadcastSink:
    """POSTs ONE coalesced message to the Supabase Realtime broadcast endpoint
    on the PRIVATE `pterm:` topic, authorized by the R0 Bearer token."""

    def __init__(
        self,
        supabase_url: str,
        anon_key: str,
        *,
        http_post: Callable[[str, dict[str, str], bytes, float], tuple[int, bytes]]
        | None = None,
    ) -> None:
        self._url = supabase_url.rstrip("/") + "/realtime/v1/api/broadcast"
        self._anon = anon_key
        self._http_post = http_post or _default_http_post

    def publish(
        self, session_id: str, event: str, data: bytes, token: str
    ) -> None:
        """Raises BroadcastAuthError on 401 (requeue), BroadcastError otherwise."""
        topic = f"pterm:{session_id}"
        body = json.dumps(
            {
                "messages": [
                    {
                        "topic": topic,
                        # 🔴 MUST be true. The broadcast HTTP API routes a message
                        # to PRIVATE (RLS-governed) subscribers ONLY when
                        # `private:true`; without it the message goes to the
                        # PUBLIC channel of the same topic name and the private
                        # subscriber (the iPhone joining pterm: with private:true)
                        # receives NOTHING — a silent blackhole (verified live on
                        # prod 2026-06-24: 202 returned, zero delivery, until this
                        # flag was added). The endpoint still evaluates write-RLS
                        # by the Bearer token, so injection stays closed.
                        "private": True,
                        "event": event,
                        "payload": {
                            "session_id": session_id,
                            "data_b64": base64.b64encode(data).decode("ascii"),
                        },
                    }
                ]
            }
        ).encode("utf-8")
        headers = {
            "Content-Type": "application/json",
            "apikey": self._anon,
            "Authorization": f"Bearer {token}",  # R0 scoped token, NOT anon
        }
        status, resp = self._http_post(self._url, headers, body, HTTP_TIMEOUT_S)
        if status == 401:
            raise BroadcastAuthError("broadcast token rejected (401)")
        if not (200 <= status < 300):
            raise BroadcastError(f"broadcast HTTP {status}")


class TerminalBroadcastPublisher:
    """Coalescing, bounded, drop-oldest producer between the PTY drain and the
    sink. Mirrors the Swift `TerminalBroadcastPublisher`. Runs a single daemon
    drain thread; tests drive `_run_drain_pass()` / `flush()` directly.

    Invariants:
      * Bytes handed to `submit` are ALREADY redacted (the caller reuses the
        `_post_stdout_chunk` redact-at-write path) — this class never sees raw.
      * A laggy sink can't back-pressure the drain: overflow drops the OLDEST.
      * `flush(session_id)` on teardown emits the final buffered chunk so the
        last compiler line before the prompt isn't lost (Gemini Route-A risk).
    """

    def __init__(
        self,
        token_client: RealtimeTokenClient,
        sink: RealtimeBroadcastSink,
        *,
        coalesce_window_s: float = COALESCE_WINDOW_S,
        queue_cap: int = QUEUE_CAP_MESSAGES,
        max_message_bytes: int = MAX_MESSAGE_BYTES,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._tokens = token_client
        self._sink = sink
        self._window = coalesce_window_s
        self._cap = max(1, queue_cap)
        self._max_bytes = max(1, max_message_bytes)
        self._clock = clock
        self._sleep = sleep
        # Queued envelopes: (session_id, event, data_bytes)
        self._queue: Deque[tuple[str, str, bytes]] = deque()
        # session_id -> consecutive-401 count (reset on any successful send).
        self._auth_retries: dict[str, int] = {}
        self._lock = threading.Lock()
        self._wake = threading.Event()
        self._thread: Optional[threading.Thread] = None
        self._stopped = False
        # Observability counters (read in tests + a future status line).
        self.dropped_overflow = 0
        self.dropped_invalid = 0
        self.dropped_unauthorized = 0
        self.published = 0

    # ---- producer side ----------------------------------------------------

    def submit(self, session_id: str, event: str, data: bytes) -> None:
        """Enqueue one already-redacted chunk. Returns immediately
        (fire-and-forget). Invalid events / empty data are dropped + counted."""
        if not data:
            return
        if event not in ALLOWED_EVENTS:
            with self._lock:
                self.dropped_invalid += 1
            return
        with self._lock:
            if len(self._queue) >= self._cap:
                self._queue.popleft()
                self.dropped_overflow += 1
            self._queue.append((session_id, event, data))
        self._wake.set()

    # ---- drain thread -----------------------------------------------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stopped = False
        t = threading.Thread(
            target=self._loop, name="r0-broadcast-drain", daemon=True
        )
        self._thread = t
        t.start()

    def stop(self) -> None:
        self._stopped = True
        self._wake.set()
        t = self._thread
        if t is not None:
            t.join(timeout=2.0)
        self._thread = None

    def _loop(self) -> None:
        while not self._stopped:
            # Wait for work, then let a coalesce window accumulate before draining.
            self._wake.wait()
            self._wake.clear()
            if self._stopped:
                break
            self._sleep(self._window)
            self._run_drain_pass()

    # ---- drain core (synchronous; the test seam) --------------------------

    def _drain_queue(self) -> list[tuple[str, str, bytes]]:
        """Pop everything currently queued (under lock)."""
        with self._lock:
            items = list(self._queue)
            self._queue.clear()
        return items

    def _coalesce(
        self, items: list[tuple[str, str, bytes]]
    ) -> list[tuple[str, str, bytes]]:
        """Merge consecutive same-(session,event) chunks into one message, in
        arrival order, splitting at `max_message_bytes` so no message is
        oversized. Order is preserved (terminal output must stay coherent)."""
        out: list[tuple[str, str, bytes]] = []
        for sid, event, data in items:
            if out and out[-1][0] == sid and out[-1][1] == event \
                    and len(out[-1][2]) + len(data) <= self._max_bytes:
                psid, pev, pdata = out[-1]
                out[-1] = (psid, pev, pdata + data)
            else:
                # Oversized single chunk → split into <=max_bytes pieces.
                if len(data) > self._max_bytes:
                    for i in range(0, len(data), self._max_bytes):
                        out.append((sid, event, data[i : i + self._max_bytes]))
                else:
                    out.append((sid, event, data))
        return out

    def _send(self, sid: str, event: str, data: bytes) -> bool:
        """Send one already-coalesced message. Returns True when the chunk is
        DONE (sent, or intentionally dropped); False when it needs REQUEUE (a
        recoverable 401 — the CALLER re-enqueues it, in order, together with any
        un-sent coalesced suffix). The network publish() runs OUTSIDE the lock;
        only the small counter/retry mutations are guarded."""
        token = self._tokens.get_token(sid)
        if token is None:
            with self._lock:
                self.dropped_unauthorized += 1
            return True  # public/denied — intentional skip
        try:
            self._sink.publish(sid, event, data, token)
            with self._lock:
                self.published += 1
                self._auth_retries.pop(sid, None)  # healthy send clears guard
            return True
        except BroadcastAuthError:
            # Token went stale mid-flight. Requeue ONCE (invalidate → re-mint →
            # retry) so a rotation race doesn't drop the chunk. A SECOND
            # consecutive 401 = persistent misconfig → drop rather than spin.
            with self._lock:
                retries = self._auth_retries.get(sid, 0)
                if retries >= MAX_AUTH_REQUEUE:
                    self._auth_retries.pop(sid, None)
                    self.dropped_unauthorized += 1
                    persist = True
                else:
                    self._auth_retries[sid] = retries + 1
                    persist = False
            if persist:
                logger.debug("broadcast 401 persists for %s — dropping", sid)
                return True
            self._tokens.invalidate(sid)
            return False  # caller requeues failed + un-sent suffix, in order
        except BroadcastError as exc:
            logger.debug("broadcast drop for %s: %s", sid, exc)
            return True  # drop; reconnect tail-snapshot recovers

    def _run_drain_pass(self) -> None:
        """One coalesce-and-send pass. On a recoverable 401, requeue the failed
        chunk AND the un-sent coalesced suffix (in original order) at the FRONT
        — so a single session's token rotation can't drop a DIFFERENT session's
        chunks or reorder a later same-session chunk — then stop the pass
        (re-mint happens on the next pass). Test seam."""
        items = self._drain_queue()
        if not items:
            return
        coalesced = self._coalesce(items)
        for idx, (sid, event, data) in enumerate(coalesced):
            if not self._send(sid, event, data):
                # Restore [failed, suffix...] at the FRONT, ahead of anything
                # submitted during this pass. appendleft in reverse → correct
                # forward order: reversed([failed,s0,s1]) appendleft'd yields
                # front [failed, s0, s1, ...].
                with self._lock:
                    for entry in reversed(coalesced[idx:]):
                        self._queue.appendleft(entry)
                self._wake.set()
                break

    def flush(self, session_id: str) -> None:
        """Synchronously emit any queued chunks for a session on teardown so
        the final output isn't lost. Other sessions' chunks are left queued.
        Best-effort: a 401 here (token already stale at teardown) drops the
        final chunk rather than requeuing onto a session that's going away."""
        with self._lock:
            mine = [e for e in self._queue if e[0] == session_id]
            self._queue = deque(e for e in self._queue if e[0] != session_id)
        for sid, event, data in self._coalesce(mine):
            self._send(sid, event, data)

    def forget(self, session_id: str) -> None:
        """Drop all per-session state on teardown (call AFTER flush) so the
        token client's caches and the retry guard stay bounded to live
        sessions on the long-running daemon."""
        with self._lock:
            self._auth_retries.pop(session_id, None)
        self._tokens.forget(session_id)
