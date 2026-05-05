"""Tests for the single-writer LocalExecutor.

Covers:
  - submit + result happy path
  - exception propagation through Future.result()
  - timeout on a slow job
  - serialized execution: even with N concurrent producers the worker
    runs jobs one at a time
  - shutdown drains pending futures with RuntimeError so callers don't
    block forever
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

from local_executor import LocalExecutor  # noqa: E402


def test_submit_and_result_returns_value():
    ex = LocalExecutor()
    try:
        fut = ex.submit(lambda x, y: x + y, 2, 3)
        assert fut.result(timeout=1.0) == 5
    finally:
        ex.shutdown()


def test_exception_propagates_through_future():
    ex = LocalExecutor()
    try:
        def boom():
            raise ValueError("kaboom")
        fut = ex.submit(boom)
        with pytest.raises(ValueError, match="kaboom"):
            fut.result(timeout=1.0)
    finally:
        ex.shutdown()


def test_result_timeout_raises_timeout_error():
    ex = LocalExecutor()
    try:
        # Submit two jobs: first blocks the worker, second's result()
        # cannot resolve until the first finishes — so the second
        # caller's tight timeout fires.
        block = threading.Event()

        def waiter():
            block.wait(timeout=2.0)
            return "done"

        slow_fut = ex.submit(waiter)
        # The slow job is now occupying the worker. A second submit
        # queues; .result(timeout=0.05) must raise TimeoutError.
        late_fut = ex.submit(lambda: 42)
        with pytest.raises(TimeoutError):
            late_fut.result(timeout=0.05)
        # Release the slow job so the executor drains naturally.
        block.set()
        assert slow_fut.result(timeout=1.0) == "done"
        assert late_fut.result(timeout=1.0) == 42
    finally:
        ex.shutdown()


def test_serialized_execution_no_overlap():
    """Even with many producer threads piling jobs in concurrently,
    the worker must run them one at a time. We assert "no overlap" by
    incrementing then decrementing a counter inside each job and
    checking the counter never exceeds 1.
    """
    ex = LocalExecutor()
    counter_lock = threading.Lock()
    inflight = [0]
    seen_max = [0]

    def job():
        with counter_lock:
            inflight[0] += 1
            if inflight[0] > seen_max[0]:
                seen_max[0] = inflight[0]
        time.sleep(0.005)
        with counter_lock:
            inflight[0] -= 1
        return True

    try:
        futs = [ex.submit(job) for _ in range(50)]
        for f in futs:
            assert f.result(timeout=2.0) is True
        assert seen_max[0] == 1
    finally:
        ex.shutdown()


def test_shutdown_drains_pending_futures():
    ex = LocalExecutor()
    block = threading.Event()
    started = threading.Event()

    def waiter():
        # Signal that the worker has popped THIS job before queuing the
        # rest — otherwise a fast `shutdown()` can drain `waiter` itself
        # along with the pending lambdas, since the worker thread may
        # not have started yet.
        started.set()
        block.wait(timeout=2.0)
        return "ok"

    occupy = ex.submit(waiter)         # blocks the worker
    assert started.wait(timeout=1.0), "worker never picked up the blocking job"
    pending = [ex.submit(lambda: 1) for _ in range(5)]
    # Shutdown without draining — the unstarted jobs should error out.
    ex.shutdown(wait=False)
    block.set()
    # The job that was running completes normally — its future was
    # already taken off the queue before shutdown's drain ran.
    assert occupy.result(timeout=1.0) == "ok"
    for f in pending:
        with pytest.raises(RuntimeError, match="executor shut down"):
            f.result(timeout=1.0)


def test_submit_after_shutdown_raises():
    ex = LocalExecutor()
    ex.shutdown()
    with pytest.raises(RuntimeError):
        ex.submit(lambda: 1)


def test_shutdown_is_idempotent():
    ex = LocalExecutor()
    ex.shutdown()
    ex.shutdown()  # must not raise
