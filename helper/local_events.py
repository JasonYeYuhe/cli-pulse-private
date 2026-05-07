"""Local event broker for Phase 3 Iter 2B streaming.

The macOS app `subscribe_events` over UDS to receive a live stream of
session events (output_delta, status changes, approval lifecycle,
heartbeat). The broker decouples publishers (PTY drain loop, approval
registry, lifecycle posters in `RemoteAgentManager`) from subscribers
(per-connection writer threads in `local_session_server`).

Critical invariants:

  * **Non-blocking publish.** `publish()` MUST NOT block on a slow
    subscriber. It either enqueues into a bounded per-subscriber queue
    or drops/coalesces the event. The PTY drain loop runs inside the
    single-writer executor; if publish ever blocked, a stalled
    subscriber would freeze every other session's command pipeline.

  * **Per-subscriber isolation.** Each subscriber owns its queue and
    its writer thread. One slow subscriber cannot delay events to
    another, and cannot block the publisher.

  * **Output-delta drop policy.** When a subscriber's queue is full,
    `output_delta` events are eligible for being dropped (oldest
    output first, so the stream stays roughly real-time rather than
    falling further behind). The macOS app has a `list_sessions` /
    `get_pending_approvals` snapshot fallback for security-critical
    state; transient output truncation is acceptable, lost approval
    events would not be.

  * **Approval / status events are protected.** When the queue is
    full, the broker first drops the oldest output_delta to make room
    for an approval_requested / approval_resolved / session_status /
    session_stopped event. If no output_delta is available to drop
    AND the queue is full of non-droppable events, the subscriber is
    marked **overflowed** — the writer thread on its next dequeue
    will see a sentinel, send an `error` event downstream, and tear
    the subscription down. This is the right "fail loud" behaviour:
    the macOS app re-subscribes via `list_sessions` snapshot to
    recover security state.

The wire shape of every event is a JSON object with:

    {"event": "<type>", "session_id": "<uuid|null>", "ts": <float>, ...}

The broker doesn't validate the event schema beyond requiring a
top-level `"event"` key — payload shape is whatever publishers emit
plus the broker-injected `ts` and (for `output_delta`) a per-session
monotonic `seq`.
"""
from __future__ import annotations

import logging
import queue
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Callable

logger = logging.getLogger("cli_pulse.local_events")

# Default bounded queue size per subscriber. Each item is one event
# dict; in practice an output_delta event is ~3.5 KB after PTY
# coalescing, so 256 items × 4 KB ≈ 1 MB worst case per subscriber.
DEFAULT_QUEUE_MAX = 256

# Heartbeat interval (s). The broker spawns a single thread that
# `publish_to_all` a heartbeat event so subscribers can detect a dead
# helper. The Swift client's idle timeout should be ≥ 2× this value.
HEARTBEAT_INTERVAL_S = 15.0

# Sentinel pushed onto a subscriber's queue by `close()` so the writer
# thread breaks out of its blocking get(). Also used by overflow.
class _CloseSentinel:
    pass


_CLOSE = _CloseSentinel()


class _OverflowSentinel(_CloseSentinel):
    """Subclass so `isinstance(item, _CloseSentinel)` covers both."""

    pass


_OVERFLOW = _OverflowSentinel()


@dataclass
class Subscription:
    """Per-subscriber state. The UDS server's per-connection thread
    creates one of these via `EventBroker.subscribe(...)`, then loops
    on `next(timeout)` writing each event as a length-prefixed frame.
    """

    subscription_id: int
    session_filter: str | None       # None = subscribe to all sessions
    _queue: queue.Queue
    _closed: threading.Event = field(default_factory=threading.Event)
    # Stats for tests + debugging. Read without lock — int writes on
    # CPython are atomic for our purposes.
    enqueued: int = 0
    delivered: int = 0
    dropped_output: int = 0
    overflowed: bool = False

    def next(self, timeout: float | None = None) -> dict[str, Any] | None:
        """Block up to `timeout` seconds for the next event. Returns
        the event dict, or None if the subscription was closed
        (peer disconnected or broker shut down). Raises nothing.

        On overflow the subscription returns one synthetic
        `{"event": "error", "code": "subscriber_overflow", ...}` then
        a None.
        """
        if self._closed.is_set():
            return None
        try:
            item = self._queue.get(timeout=timeout) if timeout is not None else self._queue.get()
        except queue.Empty:
            return None
        if isinstance(item, _OverflowSentinel):
            self.overflowed = True
            self._closed.set()
            return {
                "event": "error",
                "code": "subscriber_overflow",
                "message": "subscription queue overflowed; reconnect via list_sessions snapshot",
                "ts": time.time(),
            }
        if isinstance(item, _CloseSentinel):
            self._closed.set()
            return None
        self.delivered += 1
        return item

    def close(self) -> None:
        """Idempotently close. After calling, `next()` returns None."""
        if self._closed.is_set():
            return
        self._closed.set()
        # Wake any blocking get() — non-fatal if queue is already full
        # (the writer thread is closing anyway).
        try:
            self._queue.put_nowait(_CLOSE)
        except queue.Full:
            pass

    def is_closed(self) -> bool:
        return self._closed.is_set()


class EventBroker:
    """Fan-out broker. Thread-safe; publishers and subscribers live on
    different threads.

    Subscribers can filter to one session id (the macOS UI mostly
    cares about the row the user is looking at). Filter = None
    receives every session's events plus broadcast frames (heartbeat,
    broker-shutdown).
    """

    def __init__(
        self,
        *,
        queue_max: int = DEFAULT_QUEUE_MAX,
        heartbeat_interval_s: float | None = HEARTBEAT_INTERVAL_S,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self._lock = threading.Lock()
        self._subs: dict[int, Subscription] = {}
        self._next_id = 0
        self._queue_max = max(1, queue_max)
        self._clock = clock
        self._closed = threading.Event()

        # Heartbeat thread. None when interval == 0 / None (used by
        # tests to avoid a dangling thread).
        self._heartbeat_interval = heartbeat_interval_s
        self._heartbeat_thread: threading.Thread | None = None
        if heartbeat_interval_s and heartbeat_interval_s > 0:
            self._heartbeat_thread = threading.Thread(
                target=self._heartbeat_loop,
                name="cli-pulse-event-broker-heartbeat",
                daemon=True,
            )
            self._heartbeat_thread.start()

    # ── subscriber management ───────────────────────────────

    def subscribe(self, *, session_filter: str | None = None) -> Subscription:
        """Allocate a new subscription. The caller is responsible for
        eventually calling `close()` (the UDS server does this in its
        connection-thread `finally` block).
        """
        sub = Subscription(
            subscription_id=0,
            session_filter=session_filter,
            _queue=queue.Queue(maxsize=self._queue_max),
        )
        with self._lock:
            if self._closed.is_set():
                # Broker is shutting down; hand back a closed sub so
                # the caller's read loop exits immediately.
                sub.close()
                return sub
            self._next_id += 1
            sub.subscription_id = self._next_id
            self._subs[sub.subscription_id] = sub
        logger.debug(
            "event-broker: subscribed sub=%d filter=%s",
            sub.subscription_id, session_filter or "<all>",
        )
        return sub

    def unsubscribe(self, sub: Subscription) -> None:
        with self._lock:
            self._subs.pop(sub.subscription_id, None)
        sub.close()

    def subscriber_count(self) -> int:
        with self._lock:
            return len(self._subs)

    # ── publish ─────────────────────────────────────────────

    def publish(self, event: dict[str, Any]) -> int:
        """Fan event out to every subscriber whose filter matches.
        Non-blocking; returns the number of subscribers the event was
        enqueued into (after dropping by policy).

        `event` MUST contain a `"event"` key; if the publisher hasn't
        injected `ts`, the broker stamps it.
        """
        if "event" not in event:
            raise ValueError("publish: event dict missing 'event' key")
        if "ts" not in event:
            event["ts"] = self._clock()
        if self._closed.is_set():
            return 0
        target_session = event.get("session_id")
        # Snapshot subscribers under lock; deliver outside lock so a
        # slow queue.put_nowait can't pin the broker (it never blocks,
        # but defending in depth is cheap).
        with self._lock:
            subs = list(self._subs.values())
        delivered = 0
        for sub in subs:
            if sub.is_closed():
                continue
            if sub.session_filter is not None and target_session is not None:
                if sub.session_filter != target_session:
                    continue
            if self._enqueue(sub, event):
                delivered += 1
        return delivered

    def publish_to_all(self, event: dict[str, Any]) -> int:
        """Like `publish` but ignores `session_filter` and delivers to
        every subscriber. Used for heartbeats and broker-shutdown
        notifications.
        """
        if "event" not in event:
            raise ValueError("publish_to_all: event dict missing 'event' key")
        if "ts" not in event:
            event["ts"] = self._clock()
        if self._closed.is_set():
            return 0
        with self._lock:
            subs = list(self._subs.values())
        delivered = 0
        for sub in subs:
            if sub.is_closed():
                continue
            if self._enqueue(sub, event):
                delivered += 1
        return delivered

    # ── enqueue with drop policy ────────────────────────────

    def _enqueue(self, sub: Subscription, event: dict[str, Any]) -> bool:
        """Try to enqueue. Returns True if enqueued (possibly after
        dropping older output_delta). Returns False if the subscriber
        was overflowed and torn down.
        """
        is_output_delta = event.get("event") == "output_delta"
        try:
            sub._queue.put_nowait(event)
            sub.enqueued += 1
            return True
        except queue.Full:
            pass
        # Queue full. If THIS event is droppable (output_delta), drop
        # the new one rather than displacing a possibly-critical one.
        if is_output_delta:
            sub.dropped_output += 1
            return False
        # Non-droppable: try to evict the oldest output_delta to make
        # room. Worst case we walk the whole queue.
        if self._evict_one_output_delta(sub):
            try:
                sub._queue.put_nowait(event)
                sub.enqueued += 1
                return True
            except queue.Full:
                pass
        # No output_delta to evict OR re-put failed. Mark the subscriber
        # overflowed and detach it from the broker so future publishes
        # skip it. We DO NOT close the subscription here — the writer
        # thread on its next read will see the OVERFLOW sentinel and
        # both synthesise the typed error event AND close itself.
        # That way any events already in the queue are still delivered
        # before the connection tears down.
        try:
            self._evict_oldest(sub)
            sub._queue.put_nowait(_OVERFLOW)
        except queue.Full:
            pass
        with self._lock:
            self._subs.pop(sub.subscription_id, None)
        logger.warning(
            "event-broker: subscriber %d overflowed; detached",
            sub.subscription_id,
        )
        return False

    @staticmethod
    def _evict_one_output_delta(sub: Subscription) -> bool:
        """Walk the queue removing one (oldest) `output_delta` event.
        Items popped that are NOT output_delta are re-inserted in their
        original order (we use a temporary list because Python's
        `queue.Queue` doesn't support peek). Returns True if one was
        evicted. Approximate-fairness: we only ever scan the queue's
        current contents; concurrent enqueue can race in (impossible
        in practice — the publisher is single-threaded per call site).
        """
        keep: list[Any] = []
        evicted = False
        # Drain everything, evict first output_delta found.
        while True:
            try:
                item = sub._queue.get_nowait()
            except queue.Empty:
                break
            if not evicted and isinstance(item, dict) and item.get("event") == "output_delta":
                evicted = True
                sub.dropped_output += 1
                continue
            keep.append(item)
        # Re-insert in original order.
        for item in keep:
            try:
                sub._queue.put_nowait(item)
            except queue.Full:
                # Lost a re-insert — drop it on the floor. Should be
                # impossible because we only just drained.
                pass
        return evicted

    @staticmethod
    def _evict_oldest(sub: Subscription) -> None:
        try:
            sub._queue.get_nowait()
        except queue.Empty:
            pass

    # ── lifecycle ───────────────────────────────────────────

    def close(self) -> None:
        """Stop the heartbeat thread + close every subscription.
        Idempotent.
        """
        if self._closed.is_set():
            return
        self._closed.set()
        with self._lock:
            subs = list(self._subs.values())
            self._subs.clear()
        for sub in subs:
            sub.close()
        if self._heartbeat_thread is not None:
            # Don't join — the loop wakes within heartbeat_interval s
            # by checking _closed.is_set(). Joining would block helper
            # shutdown by up to that much.
            self._heartbeat_thread = None

    def _heartbeat_loop(self) -> None:
        interval = self._heartbeat_interval or 0
        if interval <= 0:
            return
        while not self._closed.is_set():
            # Sleep in small slices so close() takes effect promptly.
            slept = 0.0
            while slept < interval and not self._closed.is_set():
                time.sleep(min(0.5, interval - slept))
                slept += 0.5
            if self._closed.is_set():
                return
            self.publish_to_all({"event": "heartbeat"})
