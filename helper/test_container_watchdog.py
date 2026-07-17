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
import threading
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


def test_unpersistable_counter_refuses_to_respawn(monkeypatch, tmp_path):
    """review: agy + codex — my first version of this test was FICTION.

    It ran a single boot and asserted `codes == [75] or token is None`, which is
    satisfied by the very bug it was named after. If the counter can't be
    written, every boot re-reads 0 → attempts=1 → 1 <= max → exit, forever: the
    unbounded loop, resurrected through the mechanism meant to bound it.

    An uncountable respawn IS an unbounded one, so we now refuse to respawn at
    all and go straight to degraded. This drives SIX consecutive boots and
    asserts we never exit.
    """
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))
    monkeypatch.setattr(h.Path, "mkdir",
                        lambda *a, **k: (_ for _ in ()).throw(OSError("read-only")))
    monkeypatch.setattr(h.Path, "write_text",
                        lambda *a, **k: (_ for _ in ()).throw(OSError("read-only")))
    unwritable = tmp_path / "nope" / ".count"

    for _ in range(6):
        token = h._rotate_token_or_respawn(lambda: time.sleep(0.4), timeout=0.1,
                                           counter_path=unwritable, max_respawns=3)
        assert token is None, "must start degraded when the budget can't be tracked"
    assert codes == [], (
        f"an uncountable respawn is an unbounded one — must not exit at all, got {codes}"
    )


def test_corrupt_counter_cannot_reopen_the_loop(monkeypatch, counter):
    """review: codex — int() parses '-1000000' happily, and a negative count
    keeps `attempts <= max_respawns` true for a million restarts. Out-of-range
    values must read as 'budget spent', failing toward degraded, not toward a
    loop."""
    monkeypatch.setattr(h.os, "_exit", lambda code: None)
    for bad in ("-1000000", "-1", "999999"):
        counter.write_text(bad)
        assert h._read_respawn_count(counter) == h._MAX_CONTAINER_RESPAWNS, (
            f"{bad!r} must clamp to 'spent', not reopen the respawn budget"
        )
    counter.write_text("2")
    assert h._read_respawn_count(counter) == 2, "sane values pass through"
    counter.write_text("garbage")
    assert h._read_respawn_count(counter) == 0, "unparseable → 0"


def test_rotation_exception_resets_the_consecutive_run(monkeypatch, counter):
    """review: codex — a raise is NOT a stall: the container answered inside the
    deadline. Leaving the count set would let an unrelated later stall skip its
    retries and drop straight to degraded."""
    monkeypatch.setattr(h.os, "_exit", lambda code: None)
    counter.write_text("2")

    with pytest.raises(ValueError):
        h._rotate_token_or_respawn(lambda: (_ for _ in ()).throw(ValueError("boom")),
                                   timeout=1.0, counter_path=counter)

    assert counter.read_text() == "0", "a fast raise must end the stall run"


def test_rotation_exception_propagates(monkeypatch, counter):
    codes: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: codes.append(code))

    def boom():
        raise ValueError("rotation blew up")

    with pytest.raises(ValueError, match="blew up"):
        h._rotate_token_or_respawn(boom, timeout=0.2, counter_path=counter)

    time.sleep(0.35)
    assert codes == [], "must not exit when rotation raises — the caller handles it"


def test_abandoned_worker_still_lands_its_token_for_the_next_start(monkeypatch, counter, tmp_path):
    """Abandoning the stalled worker must not lose the token permanently: if the
    open ever completes, the token lands on disk and the NEXT helper start uses
    it.

    Note this is NOT a claim that a degraded helper heals itself in place — it
    doesn't. Degraded skips the socket entirely (it lives in the stalled
    container), so nothing is re-reading the token; the local surface returns
    only on restart. An earlier draft of this test asserted in-place self-heal,
    which was true only of a design that bound the socket anyway — the design
    agy showed would hang the daemon.
    """
    monkeypatch.setattr(h.os, "_exit", lambda code: None)
    counter.write_text("3")  # budget spent → this boot goes degraded
    token_file = tmp_path / "helper-auth-token"
    released = threading.Event()

    def slow_rotate():
        released.wait(5.0)              # the stalled container open
        token_file.write_text("HEALED-TOKEN")   # ...eventually completes
        return "HEALED-TOKEN"

    token = h._rotate_token_or_respawn(slow_rotate, timeout=0.15,
                                       counter_path=counter, max_respawns=3)
    assert token is None, "degraded start: no token yet"

    # The worker was abandoned, not killed. Let its stalled write land.
    released.set()
    for _ in range(50):
        if token_file.exists():
            break
        time.sleep(0.05)

    from local_auth_token import load_token
    assert load_token(token_file) == "HEALED-TOKEN", (
        "the abandoned worker must still land its token, and load_token must see "
        "it — this is what makes degraded mode self-healing rather than a dead end"
    )


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
