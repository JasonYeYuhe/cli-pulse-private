"""Single-writer executor for the helper daemon.

Phase 3 Iter 1 introduces two concurrent producers of mutations against
`RemoteAgentManager`:

  * the existing daemon poll loop (runs `tick()` every second to dispatch
    Supabase-queued commands), and
  * the new local UDS server (a per-connection thread per local-app
    request — `start_session`, `list_sessions`, `stop_session`).

Without serialization the two producers can race on `_sessions`, the
PTY transport, and the per-session event_seq counter. This module
provides the single owner of those mutations: a worker thread that pulls
work items off a `queue.Queue` and runs them one at a time. Producers
get back a `Future` they can `result(timeout=…)` on without blocking the
worker.

Design intent for Phase 3 Iter 2B:

  * Iter 2B will introduce per-session hook approval waits that may
    block for several seconds. Those waits MUST happen off the worker
    thread, otherwise a single in-flight approval would freeze every
    other session's command pipeline.
  * The Future API here is condition-variable-friendly precisely so a
    caller can `submit(start_long_op).result(timeout=...)` from a
    *worker-thread-spawned helper thread* without holding the worker.
    Iter 2B will introduce that secondary worker; Iter 1 only needs
    the single-writer guarantee.

The executor is intentionally minimal:

  * No priority queue. FIFO ordering is what the helper needs — a
    typed prompt should not jump ahead of an earlier `start`.
  * No cancellation. Cancelling an in-flight job mid-PTY-write would
    leave the child in an undefined state. Iter 2B will add a
    cooperative cancellation flag for hook waits, not for arbitrary
    callables.
  * No exception suppression. Producer-side exceptions propagate via
    `Future.result()`; the worker just logs and moves on.
"""
from __future__ import annotations

import logging
import queue
import threading
from typing import Any, Callable

logger = logging.getLogger("cli_pulse.local_executor")

# Sentinel pushed onto the queue by `shutdown()` to wake the worker
# thread out of its blocking `get()`. Anything truthy works; we use a
# class so a stray `None` payload from a buggy producer can't masquerade
# as the stop signal.
class _StopSentinel:
    pass


_STOP = _StopSentinel()


class Future:
    """Condition-variable-backed result holder.

    Usage:
        fut = executor.submit(do_thing, arg)
        result = fut.result(timeout=5.0)   # blocks; raises on error or timeout

    Callers can also poll `done()` if they want to integrate with a
    larger select-style loop, but the primary API is `result(timeout)`.
    """

    __slots__ = ("_cond", "_done", "_value", "_exc")

    def __init__(self) -> None:
        self._cond = threading.Condition()
        self._done = False
        self._value: Any = None
        self._exc: BaseException | None = None

    def done(self) -> bool:
        with self._cond:
            return self._done

    def result(self, timeout: float | None = None) -> Any:
        """Block until the future resolves. Raises the worker-side
        exception (if any) or `TimeoutError` if `timeout` elapses
        first.
        """
        with self._cond:
            if not self._done:
                self._cond.wait(timeout=timeout)
            if not self._done:
                raise TimeoutError(f"future not ready after {timeout}s")
            if self._exc is not None:
                raise self._exc
            return self._value

    # Internal — only the worker thread should call these.
    def _set_result(self, value: Any) -> None:
        with self._cond:
            self._value = value
            self._done = True
            self._cond.notify_all()

    def _set_exception(self, exc: BaseException) -> None:
        with self._cond:
            self._exc = exc
            self._done = True
            self._cond.notify_all()


class LocalExecutor:
    """Single-writer executor. One worker thread, FIFO `queue.Queue`.

    The worker thread is daemonic so a hung job during interpreter
    shutdown doesn't pin the process — the daemon's signal handler is
    responsible for calling `shutdown()` so a clean exit can drain
    queued work.
    """

    def __init__(self, name: str = "cli-pulse-local-executor") -> None:
        self._queue: "queue.Queue[tuple[Future, Callable[..., Any], tuple, dict] | _StopSentinel]" = (
            queue.Queue()
        )
        self._stopped = threading.Event()
        self._worker = threading.Thread(target=self._run, name=name, daemon=True)
        self._worker.start()

    def submit(self, fn: Callable[..., Any], *args: Any, **kwargs: Any) -> Future:
        """Enqueue `fn(*args, **kwargs)`. Returns a Future the caller
        can `result(timeout=…)` on. Raises RuntimeError if the executor
        has been shut down.
        """
        if self._stopped.is_set():
            raise RuntimeError("executor already shut down")
        fut = Future()
        self._queue.put((fut, fn, args, kwargs))
        return fut

    def submit_and_wait(
        self, fn: Callable[..., Any], *args: Any, timeout: float | None = None, **kwargs: Any
    ) -> Any:
        """Convenience wrapper: submit and block on the result. Equivalent to
        `submit(fn, *args, **kwargs).result(timeout=timeout)`. Useful for
        the common UDS-server pattern where the connection thread wants a
        synchronous reply.
        """
        return self.submit(fn, *args, **kwargs).result(timeout=timeout)

    def shutdown(self, wait: bool = True, timeout: float | None = None) -> None:
        """Stop accepting new work and (optionally) wait for the worker
        to drain. Idempotent.

        Once shut down, further `submit()` calls raise RuntimeError.
        Pending futures whose work hadn't started yet receive a
        RuntimeError so callers don't block forever on `result()`.
        """
        if self._stopped.is_set():
            return
        self._stopped.set()
        self._queue.put(_STOP)
        if wait:
            self._worker.join(timeout=timeout)
        # Drain any callers still waiting on un-started futures.
        # (Started-but-unfinished futures will resolve naturally as
        # their job completes.)
        while True:
            try:
                item = self._queue.get_nowait()
            except queue.Empty:
                break
            if isinstance(item, _StopSentinel):
                continue
            fut, _fn, _args, _kwargs = item
            fut._set_exception(RuntimeError("executor shut down before job ran"))

    # ── worker ──────────────────────────────────────────────

    def _run(self) -> None:
        while True:
            item = self._queue.get()
            if isinstance(item, _StopSentinel):
                return
            fut, fn, args, kwargs = item
            try:
                value = fn(*args, **kwargs)
                fut._set_result(value)
            except BaseException as exc:  # noqa: BLE001 — preserve all exceptions for the caller
                # Log so a misbehaving callable shows up in helper.log
                # even if no caller is waiting on the future.
                logger.warning("executor job %s raised: %s", getattr(fn, "__name__", fn), exc)
                fut._set_exception(exc)
