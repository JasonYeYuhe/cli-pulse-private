"""_rotate_token_best_effort: the startup app-group-container deadline.

The helper's first container access stalls under launchd — a TCC
`kTCCServiceSystemPolicyAppData` consult (1–10s, >20s tail), NOT containermanagerd.
The decisive property is that the cost is **per-process and never shared**, so
nothing ever gets "warm".

1.29.0 didn't know that. It waited 12s then `os._exit(75)` so launchd's KeepAlive
would respawn "against a now-warmer containermanagerd" — but each respawn starts a
fresh full-price consult and meets the same ceiling. FIELD RESULT: 2,816 respawns
across 10h07m on the owner's Mac, never once binding the socket. The helper was
invisibly dead all night.

So: wait it out (bounded to the real distribution), NEVER exit, and if the wait
expires, skip the local surface entirely — the socket lives inside the stalled
container, so binding would hang the daemon outright.

Covered here: a fast rotation returns its token; a slow-but-completing one (the
case the 12s ceiling kept killing) still returns; a stall returns None rather than
exiting (the whole point); an exception propagates; a stalled worker still lands
its token for the next start; and the security property that makes a token-less
start safe.
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


def test_fast_rotation_returns_the_token(monkeypatch):
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))

    token = h._rotate_token_best_effort(lambda: "TOKEN-OK", timeout=5.0)

    assert token == "TOKEN-OK"
    time.sleep(0.05)
    assert exits == [], "the happy path must never exit"


def test_slow_but_completing_rotation_still_returns_its_token(monkeypatch):
    """The case 1.29.0's 12s ceiling kept KILLING. The TCC consult is routinely
    slow under launchd (1–10s) and then COMPLETES; the old code hard-exited into
    a fresh full-price consult instead of waiting the extra moment.
    """
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))

    def slow_but_completes():
        time.sleep(0.4)
        return "TOKEN-SLOW"

    token = h._rotate_token_best_effort(slow_but_completes, timeout=5.0)

    assert token == "TOKEN-SLOW", "a slow-but-completing consult must not be abandoned"
    assert exits == []


def test_stall_returns_none_and_never_exits(monkeypatch):
    """The regression that matters. 1.29.0 called os._exit(75) here and launchd
    respawned it into the same stall 2,816 times over 10h07m. A respawn cannot
    help: the TCC consult is per-process, so the retry re-pays full price and
    meets the same ceiling.
    """
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))
    start = time.monotonic()

    token = h._rotate_token_best_effort(lambda: time.sleep(3.0), timeout=0.2)
    elapsed = time.monotonic() - start

    assert token is None, "a stall must report 'no token', not hang or exit"
    assert exits == [], (
        "must NOT exit — an exit is a respawn, and respawning is what caused the "
        "10h outage this function exists to prevent"
    )
    assert elapsed < 1.0, f"must give up at the deadline, not wait out the stall: {elapsed:.2f}s"


def test_stalled_worker_still_lands_its_token_for_the_next_start(monkeypatch, tmp_path):
    """Abandoning the worker must not lose the token permanently: the thread is a
    daemon (it cannot keep the interpreter alive), and if the stalled open ever
    completes it writes the token, which the NEXT start reads.

    Explicitly NOT a claim that a token-less start heals itself in place. It
    can't: that start skips the socket entirely (the socket lives in the stalled
    container), so nothing is re-reading the token.
    """
    monkeypatch.setattr(h.os, "_exit", lambda code: None)
    token_file = tmp_path / "helper-auth-token"
    released = threading.Event()

    def stalled_then_completes():
        released.wait(5.0)
        token_file.write_text("LATE-TOKEN")
        return "LATE-TOKEN"

    assert h._rotate_token_best_effort(stalled_then_completes, timeout=0.15) is None

    released.set()                       # the TCC consult finally returns
    for _ in range(50):
        if token_file.exists():
            break
        time.sleep(0.05)

    from local_auth_token import load_token
    assert load_token(token_file) == "LATE-TOKEN", (
        "the abandoned worker must still land its token for the next start"
    )


def test_rotation_exception_propagates(monkeypatch):
    """A raise is not a stall — the container answered. The caller already treats
    a token failure as best-effort and binds anyway, which is safe precisely
    because the container demonstrably responded.
    """
    exits: list[int] = []
    monkeypatch.setattr(h.os, "_exit", lambda code: exits.append(code))

    with pytest.raises(ValueError, match="blew up"):
        h._rotate_token_best_effort(
            lambda: (_ for _ in ()).throw(ValueError("rotation blew up")),
            timeout=1.0,
        )

    time.sleep(0.2)
    assert exits == []


def test_empty_token_never_authenticates():
    """What makes a token-less start safe. If the socket ever IS bound without a
    token, `_get_token()` yields "" — and an empty expected token must never
    match, on a socket any local process can connect(2) to.
    """
    from local_auth_token import compare
    assert compare("", "") is False
    assert compare("", "anything") is False
    assert compare("real-token", "") is False
    assert compare("real-token", "real-token") is True
