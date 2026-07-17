"""_rotate_token_best_effort — the bounded, non-fatal wait on the app-group
container's TCC consult.

Supersedes test_container_watchdog.py. The old contract hard-exited 75 so
launchd would respawn the helper against a "warm" container; there is no such
thing — the kTCCServiceSystemPolicyAppData consult is per-process and costs
1-10s under launchd every single time, so respawning just restarted it and the
helper looped forever. See
PROJECT_FIX_2026-07-17_helper-launchd-tcc-appdata-consult.md.

The contract these tests pin: return the token when it arrives in time, return
None (never exit) when it doesn't, let the in-flight rotation finish anyway,
and propagate a real rotation error.
"""
from __future__ import annotations

import builtins
import sys
import threading
import time
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as h  # noqa: E402


def test_fast_rotation_returns_token_and_does_not_exit(monkeypatch):
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))

    token = h._rotate_token_best_effort(lambda: "TOKEN-OK", timeout=5.0)

    assert token == "TOKEN-OK"
    assert exits == [], "the fast path must never exit"


def test_slow_consult_returns_none_without_exiting_or_respawning(monkeypatch):
    """The regression that mattered: a consult past the ceiling used to
    os._exit(75) into an infinite launchd respawn loop. It must now degrade to
    a token-less start, which the caller already handles.
    """
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))

    released = threading.Event()

    def slow_rotate():
        released.wait(5.0)  # outlives the ceiling below
        return "LATE-TOKEN"

    started = time.monotonic()
    token = h._rotate_token_best_effort(slow_rotate, timeout=0.2)
    elapsed = time.monotonic() - started

    assert token is None, "an overrunning consult yields None, not a token"
    assert exits == [], "must NOT exit — respawning cannot speed up a TCC consult"
    # Returned at the ceiling rather than blocking for the whole slow call:
    # startup proceeds and the socket binds while the rotation runs on.
    assert elapsed < 1.0, f"returned too late: {elapsed:.3f}s"
    released.set()


def test_late_rotation_still_completes_in_background(monkeypatch):
    """Returning None must not abandon the rotation: the token still gets
    written, which is what lets `_get_token()`'s per-request disk read start
    authenticating without a restart.
    """
    monkeypatch.setattr(h.os, "_exit", lambda code: None)

    released = threading.Event()
    wrote = threading.Event()

    def slow_rotate():
        released.wait(5.0)
        wrote.set()  # stands in for the on-disk token write
        return "LATE-TOKEN"

    assert h._rotate_token_best_effort(slow_rotate, timeout=0.2) is None

    released.set()
    assert wrote.wait(5.0), "the in-flight rotation must still finish and write"


def test_rotation_exception_propagates(monkeypatch):
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))

    def boom():
        raise ValueError("rotation blew up")

    try:
        h._rotate_token_best_effort(boom, timeout=5.0)
    except ValueError as exc:
        assert "blew up" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("exception from rotate_token must propagate")

    assert exits == [], "an exception is the caller's to handle, not an exit"


def test_token_path_for_log_never_raises(monkeypatch):
    """The slow-path warning interpolates this; a diagnostic must not be able
    to take down the startup path it is describing.
    """
    assert isinstance(h._token_path_for_log(), str)

    real_import = builtins.__import__

    def boom_import(name, *a, **kw):
        if name == "local_auth_token":
            raise ImportError("frozen archive unavailable")
        return real_import(name, *a, **kw)

    monkeypatch.setattr(builtins, "__import__", boom_import)
    assert h._token_path_for_log() == "<app-group container>"
