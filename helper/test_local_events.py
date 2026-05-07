"""Tests for the local event broker (Phase 3 Iter 2B).

Coverage:
  - subscribe + publish round-trips
  - per-session filter only delivers matching events
  - publish_to_all ignores filter (heartbeat)
  - bounded queue: output_delta dropped when queue full
  - non-droppable event evicts oldest output_delta to fit
  - subscriber overflow tears down the subscription with an error
    sentinel + the broker forgets it
  - close idempotent + wakes blocking next()
  - publish on closed broker is a no-op
  - heartbeat thread can be disabled (interval=None) for tests
"""
from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from local_events import EventBroker  # noqa: E402


# ── basic publish / subscribe ─────────────────────────────


def test_subscribe_receives_published_event():
    b = EventBroker(heartbeat_interval_s=None)
    sub = b.subscribe()
    delivered = b.publish({"event": "hello", "session_id": "S1"})
    assert delivered == 1
    out = sub.next(timeout=0.5)
    assert out is not None
    assert out["event"] == "hello"
    assert out["session_id"] == "S1"
    assert "ts" in out
    b.close()


def test_subscribe_filter_drops_other_sessions():
    b = EventBroker(heartbeat_interval_s=None)
    sub = b.subscribe(session_filter="S1")
    b.publish({"event": "x", "session_id": "S2"})
    b.publish({"event": "x", "session_id": "S1"})
    out = sub.next(timeout=0.5)
    assert out is not None
    assert out["session_id"] == "S1"
    # Second poll: no more events.
    assert sub.next(timeout=0.05) is None or sub.is_closed()
    b.close()


def test_subscribe_filter_none_receives_everything():
    b = EventBroker(heartbeat_interval_s=None)
    sub = b.subscribe(session_filter=None)
    b.publish({"event": "x", "session_id": "S1"})
    b.publish({"event": "y", "session_id": "S2"})
    received = []
    for _ in range(2):
        e = sub.next(timeout=0.5)
        if e is None:
            break
        received.append(e["session_id"])
    assert set(received) == {"S1", "S2"}
    b.close()


def test_publish_to_all_ignores_filter():
    b = EventBroker(heartbeat_interval_s=None)
    sub = b.subscribe(session_filter="only-me")
    b.publish_to_all({"event": "heartbeat"})
    out = sub.next(timeout=0.5)
    assert out is not None
    assert out["event"] == "heartbeat"
    b.close()


# ── backpressure / drop policy ────────────────────────────


def test_output_delta_dropped_when_queue_full():
    b = EventBroker(queue_max=2, heartbeat_interval_s=None)
    sub = b.subscribe()
    # Fill with 2 output_deltas.
    b.publish({"event": "output_delta", "session_id": "S", "payload": "1"})
    b.publish({"event": "output_delta", "session_id": "S", "payload": "2"})
    # Third would overflow — drop policy says drop the new output_delta.
    b.publish({"event": "output_delta", "session_id": "S", "payload": "3"})
    assert sub.dropped_output >= 1
    # Drain — first two survived; third was dropped.
    seen = []
    for _ in range(3):
        e = sub.next(timeout=0.05)
        if e is None:
            break
        seen.append(e["payload"])
    assert seen == ["1", "2"]
    b.close()


def test_non_droppable_evicts_oldest_output_delta():
    """When a status arrives and the queue is full of output_delta,
    the oldest output_delta is evicted to make room.
    """
    b = EventBroker(queue_max=2, heartbeat_interval_s=None)
    sub = b.subscribe()
    b.publish({"event": "output_delta", "session_id": "S", "payload": "old"})
    b.publish({"event": "output_delta", "session_id": "S", "payload": "newer"})
    b.publish({"event": "session_status", "session_id": "S", "status": "stopped"})
    seen_events = []
    for _ in range(3):
        e = sub.next(timeout=0.05)
        if e is None:
            break
        seen_events.append(e["event"])
    # Eviction kept the newer output_delta + the status.
    assert "session_status" in seen_events
    assert seen_events.count("output_delta") == 1
    assert sub.dropped_output >= 1
    b.close()


def test_subscriber_overflow_tears_down_with_error():
    """When the queue is full of non-droppable events, the next
    non-droppable arrival overflows the subscriber and the broker
    detaches it.
    """
    b = EventBroker(queue_max=2, heartbeat_interval_s=None)
    sub = b.subscribe()
    # Fill with non-droppable events.
    b.publish({"event": "session_status", "session_id": "S", "status": "running"})
    b.publish({"event": "approval_requested", "session_id": "S", "approval_id": "A"})
    # Third non-droppable triggers overflow.
    b.publish({"event": "approval_resolved", "session_id": "S", "approval_id": "A"})
    # Drain. Eventually we should see the synthetic overflow error.
    saw_overflow = False
    for _ in range(5):
        e = sub.next(timeout=0.1)
        if e is None:
            break
        if e["event"] == "error" and e.get("code") == "subscriber_overflow":
            saw_overflow = True
            break
    assert saw_overflow
    # And the broker forgot us.
    assert b.subscriber_count() == 0
    b.close()


# ── close / lifecycle ─────────────────────────────────────


def test_close_idempotent_and_wakes_blocking_next():
    b = EventBroker(heartbeat_interval_s=None)
    sub = b.subscribe()
    result_holder: list = []

    def reader():
        result_holder.append(sub.next(timeout=2.0))

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    time.sleep(0.05)
    b.close()
    b.close()  # idempotent
    t.join(timeout=1.0)
    assert not t.is_alive()
    assert result_holder == [None]


def test_publish_on_closed_broker_is_noop():
    b = EventBroker(heartbeat_interval_s=None)
    sub = b.subscribe()
    b.close()
    delivered = b.publish({"event": "x", "session_id": "S"})
    assert delivered == 0
    assert sub.is_closed() or sub.next(timeout=0.05) is None


def test_publish_requires_event_key():
    b = EventBroker(heartbeat_interval_s=None)
    with pytest.raises(ValueError):
        b.publish({"session_id": "S"})  # type: ignore[arg-type]
    b.close()


# ── stats ─────────────────────────────────────────────────


def test_subscriber_count_reflects_active_subs():
    b = EventBroker(heartbeat_interval_s=None)
    assert b.subscriber_count() == 0
    s1 = b.subscribe()
    s2 = b.subscribe()
    assert b.subscriber_count() == 2
    b.unsubscribe(s1)
    assert b.subscriber_count() == 1
    b.unsubscribe(s2)
    assert b.subscriber_count() == 0
    b.close()
