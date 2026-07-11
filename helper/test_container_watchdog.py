"""v1.29.0 P0: _rotate_token_or_respawn watchdog.

macOS 26.5 cold-login containermanagerd race — the first app-group container
access (rotate_token's os.open) can block forever under launchd. The watchdog
converts that permanent silent hang into a hard-exit so the LaunchAgent's
KeepAlive respawns the helper against a warm container. These tests exercise
the three paths without touching a real container: fast success, hang -> exit,
and exception passthrough.
"""
from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as h  # noqa: E402


def test_fast_rotation_returns_token_and_does_not_exit(monkeypatch):
    calls: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: calls.append(code))

    token = h._rotate_token_or_respawn(lambda: "TOKEN-OK", timeout=5.0)

    assert token == "TOKEN-OK"
    # Give any (erroneously-armed) watchdog well past a fast call to misfire.
    time.sleep(0.05)
    assert calls == [], "watchdog must not fire on a fast rotation"


def test_hang_triggers_hard_exit_for_respawn(monkeypatch):
    exited = threading.Event()
    codes: list[int] = []
    fired_at: list[float] = []
    start = time.monotonic()

    def fake_exit(code):
        codes.append(code)
        fired_at.append(time.monotonic() - start)
        exited.set()
        # Real os._exit never returns; the fake does so the test thread lives.

    monkeypatch.setattr(h.os, "_exit", fake_exit)

    def slow_rotate():
        # Simulates the container os.open blocking well past the ceiling. (In
        # production the real os._exit would kill the process here; the fake
        # lets the sleep finish, so we assert on WHEN the watchdog fired.)
        time.sleep(1.0)
        return "LATE"

    h._rotate_token_or_respawn(slow_rotate, timeout=0.2)

    assert exited.wait(2.0), "watchdog must hard-exit when the access hangs"
    assert codes == [75], "must exit EX_TEMPFAIL so KeepAlive respawns"
    # The watchdog fired near the ceiling, not after the full (1.0s) slow call.
    assert fired_at[0] < 0.9, f"watchdog fired too late: {fired_at[0]:.3f}s"


def test_rotation_exception_propagates_and_cancels_watchdog(monkeypatch):
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))

    def boom():
        raise ValueError("rotation blew up")

    try:
        h._rotate_token_or_respawn(boom, timeout=0.2)
    except ValueError as exc:
        assert "blew up" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("exception from rotate_token must propagate")

    # Watchdog must have been cancelled on the exception path — wait past the
    # ceiling and confirm it never fired.
    time.sleep(0.35)
    assert codes == [], "watchdog must be cancelled when rotation raises"
