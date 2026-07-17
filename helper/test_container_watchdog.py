"""_rotate_token_or_respawn: the startup app-group-container deadline.

The first container access (rotate_token's os.open) can stall under launchd for
reasons not root-caused. 1.29.0 hard-exited so launchd's KeepAlive would respawn
"against a warm container" — on the premise the stall self-clears within seconds
of login. FIELD-DISPROVEN 2026-07-17: it respawned 2,816 times over 10h07m on a
warm, awake machine and never bound its socket. The helper was invisibly dead.

So the respawn is now BOUNDED, then we start degraded (no token, socket still
binds) — the behaviour the daemon() call site already documents for a token
failure. These tests cover: fast success (+ counter reset), a stall inside the
respawn budget (hard-exit 75, counter incremented), a stall past the budget
(returns None instead of exiting, counter reset), exception passthrough, and the
security property that makes degraded mode safe — an empty token never
authenticates.
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as h  # noqa: E402


import pytest  # noqa: E402


@pytest.fixture()
def counter(tmp_path):
    return tmp_path / ".container-respawn-count"


def test_fast_rotation_returns_token_and_does_not_exit(monkeypatch, counter):
    calls: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: calls.append(code))
    counter.write_text("2")  # a previous stall left the counter dirty

    token = h._rotate_token_or_respawn(lambda: "TOKEN-OK", timeout=5.0,
                                       counter_path=counter)

    assert token == "TOKEN-OK"
    time.sleep(0.05)
    assert calls == [], "must not exit on a fast rotation"
    assert counter.read_text() == "0", (
        "a success must RESET the counter — otherwise a few stalls spread over "
        "unrelated restarts would eventually push a healthy helper into "
        "degraded mode"
    )


def test_stall_within_budget_hard_exits_for_respawn(monkeypatch, counter):
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))
    start = time.monotonic()

    def slow_rotate():
        time.sleep(1.0)          # still stuck when the deadline passes
        return "LATE"

    h._rotate_token_or_respawn(slow_rotate, timeout=0.2, counter_path=counter,
                               max_respawns=3)
    elapsed = time.monotonic() - start

    assert codes == [75], "must exit EX_TEMPFAIL so KeepAlive respawns"
    assert elapsed < 0.9, (
        f"must give up at the deadline, not wait out the stalled call: {elapsed:.3f}s"
    )
    assert counter.read_text() == "1", "each respawn must be counted"


def test_stall_past_budget_starts_degraded_instead_of_looping(monkeypatch, counter):
    """The whole point of this revision. 1.29.0 looped 2,816 times / 10h here."""
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))
    counter.write_text("3")  # budget already spent by earlier restarts

    token = h._rotate_token_or_respawn(lambda: time.sleep(1.0), timeout=0.2,
                                       counter_path=counter, max_respawns=3)

    assert codes == [], "must NOT exit once the respawn budget is spent"
    assert token is None, "must report 'no token' so the caller starts degraded"
    assert counter.read_text() == "0", "counter resets once we stop retrying"


class _ProcessExited(Exception):
    """Faithful stand-in for os._exit: it NEVER returns, so a test that lets it
    fall through isn't testing the real control flow."""


def test_respawn_budget_is_actually_bounded(monkeypatch, counter):
    """The invariant that 1.29.0 lacked: a persistent stall must reach a
    degraded start in a BOUNDED number of restarts, never loop. Field evidence:
    2,816 respawns / 10h07m.

    Asserts "at most N CONSECUTIVE respawns before giving up", not "at most N
    ever": giving up resets the counter on purpose, because a later boot may be
    a genuinely different situation (a real cold login) and deserves its
    retries. That can't re-loop in production — the degraded process STAYS
    ALIVE, so nothing restarts it.
    """
    exits: list[int] = []

    def fake_exit(code):
        exits.append(code)
        raise _ProcessExited()

    monkeypatch.setattr(h.os, "_exit", fake_exit)

    outcomes: list[str] = []
    for _ in range(6):           # six consecutive stalled boots
        try:
            r = h._rotate_token_or_respawn(lambda: time.sleep(0.6), timeout=0.1,
                                           counter_path=counter, max_respawns=3)
            outcomes.append("degraded" if r is None else "token")
        except _ProcessExited:
            outcomes.append("exit")

    assert "degraded" in outcomes, "must eventually start degraded, never loop forever"
    before = outcomes[:outcomes.index("degraded")]
    assert all(o == "exit" for o in before)
    assert len(before) <= 3, f"gave up only after {len(before)} respawns, want <=3"


def test_unreadable_counter_still_bounds_the_loop(monkeypatch, tmp_path):
    """A counter we can't persist must not resurrect the infinite loop: the
    read falls back to 0, so we spend the budget on every boot but STILL exit
    the stall path — never an unbounded hang."""
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))
    unwritable = tmp_path / "nope" / "deep" / ".count"
    monkeypatch.setattr(h.Path, "mkdir", lambda *a, **k: (_ for _ in ()).throw(OSError("ro")))

    token = h._rotate_token_or_respawn(lambda: time.sleep(0.5), timeout=0.1,
                                       counter_path=unwritable, max_respawns=1)
    # Budget=1 and count reads 0 → this boot respawns; it never hangs.
    assert codes == [75] or token is None


def test_rotation_exception_propagates(monkeypatch, counter):
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))

    def boom():
        raise ValueError("rotation blew up")

    with pytest.raises(ValueError, match="blew up"):
        h._rotate_token_or_respawn(boom, timeout=0.2, counter_path=counter)

    time.sleep(0.35)
    assert codes == [], "must not exit when rotation raises — the caller handles it"


def test_empty_token_never_authenticates():
    """The security property that makes degraded mode safe. Starting without a
    token leaves the expected token empty; if compare() treated that as a match,
    the degraded path would be an auth BYPASS on a socket any local process can
    connect to.
    """
    from local_auth_token import compare
    assert compare("", "") is False
    assert compare("", "anything") is False
    assert compare("real-token", "") is False
    assert compare("real-token", "real-token") is True
