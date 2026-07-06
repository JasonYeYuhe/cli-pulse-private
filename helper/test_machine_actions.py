"""Tests for the M1 same-UID process-kill guard (machine_actions.py).

The whole point of the module is that every OS touchpoint is injected, so
these tests exercise the full guard matrix — same-UID, pid≤1, kernel_task,
launchd, the helper itself, a non-existent pid, and the
SIGTERM→grace→SIGKILL escalation — WITHOUT spawning a single real process,
using a fake clock + a fake process table.
"""
from __future__ import annotations

import signal
import sys
import unittest
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import machine_actions as ma  # noqa: E402
from machine_actions import (  # noqa: E402
    CODE_NOT_FOUND,
    CODE_NOT_PERMITTED,
    CODE_PROTECTED,
    CODE_RATE_LIMITED,
    MachineActions,
)


class FakeClock:
    """Monotonic-ish fake clock. `sleep` advances it deterministically so a
    grace/escalation loop terminates instantly under test."""

    def __init__(self) -> None:
        self.t = 1000.0

    def now(self) -> float:
        return self.t

    def sleep(self, dt: float) -> None:
        self.t += dt


class FakeProc:
    """A single fake process: owner uid, comm, and a scripted liveness."""

    def __init__(self, uid: int, comm: str, *, dies_after_signal: int | None = None,
                 alive: bool = True) -> None:
        self.uid = uid
        self.comm = comm
        # If set, the process dies once it receives this signal number.
        self.dies_after_signal = dies_after_signal
        self.alive = alive
        self.signals: list[int] = []


class FakeOS:
    """A fake process table backing proc_info / signal / alive callables."""

    def __init__(self, my_uid: int = 501, my_pid: int = 9999, my_ppid: int = 1) -> None:
        self.my_uid = my_uid
        self.my_pid = my_pid
        self.my_ppid = my_ppid
        self.table: dict[int, FakeProc] = {}

    def add(self, pid: int, proc: FakeProc) -> None:
        self.table[pid] = proc

    def proc_info(self, pid: int):
        p = self.table.get(pid)
        if p is None or not p.alive:
            return None
        return (p.uid, p.comm)

    def signal(self, pid: int, sig: int) -> None:
        p = self.table.get(pid)
        if p is None or not p.alive:
            raise ProcessLookupError(pid)
        if sig == 0:
            return  # liveness probe — no-op on a live process
        p.signals.append(sig)
        if sig == signal.SIGKILL:
            p.alive = False
        elif p.dies_after_signal is not None and sig == p.dies_after_signal:
            p.alive = False

    def alive(self, pid: int) -> bool:
        p = self.table.get(pid)
        return bool(p and p.alive)


def _actions(fos: FakeOS, clock: FakeClock, **kw) -> MachineActions:
    return MachineActions(
        getuid=lambda: fos.my_uid,
        getpid=lambda: fos.my_pid,
        getppid=lambda: fos.my_ppid,
        proc_info=fos.proc_info,
        signal_fn=fos.signal,
        alive_fn=fos.alive,
        clock=clock.now,
        sleep_fn=clock.sleep,
        grace_s=2.0,
        poll_interval_s=0.1,
        sigkill_confirm_s=0.5,
        **kw,
    )


class TestKillGuardMatrix(unittest.TestCase):
    def test_same_uid_sigterm_clean_exit(self):
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "python3", dies_after_signal=signal.SIGTERM))
        clock = FakeClock()
        res = _actions(fos, clock).kill_process(1234)
        self.assertTrue(res["terminated"])
        self.assertFalse(res["escalated"])
        self.assertIsNone(res["error"])
        self.assertEqual(fos.table[1234].signals, [signal.SIGTERM])

    def test_sigterm_then_sigkill_escalation(self):
        # Process ignores SIGTERM → survives the grace window → SIGKILL.
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "stubborn", dies_after_signal=None))
        clock = FakeClock()
        res = _actions(fos, clock).kill_process(1234)
        self.assertTrue(res["terminated"])
        self.assertTrue(res["escalated"])
        self.assertIn(signal.SIGTERM, fos.table[1234].signals)
        self.assertIn(signal.SIGKILL, fos.table[1234].signals)

    def test_pid_one_protected(self):
        fos = FakeOS()
        res = _actions(fos, FakeClock()).kill_process(1)
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertFalse(res["terminated"])

    def test_pid_zero_and_negative_protected(self):
        fos = FakeOS()
        a = _actions(fos, FakeClock())
        self.assertEqual(a.kill_process(0)["code"], CODE_PROTECTED)
        self.assertEqual(a.kill_process(-5)["code"], CODE_PROTECTED)

    def test_kernel_task_protected_by_name(self):
        # Even if (contrived) it were same-UID, the comm deny-list refuses it.
        fos = FakeOS()
        fos.add(500, FakeProc(501, "kernel_task"))
        res = _actions(fos, FakeClock()).kill_process(500)
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertEqual(fos.table[500].signals, [])  # never signalled

    def test_launchd_protected_by_name(self):
        fos = FakeOS()
        fos.add(700, FakeProc(501, "launchd"))
        res = _actions(fos, FakeClock()).kill_process(700)
        self.assertEqual(res["code"], CODE_PROTECTED)

    def test_windowserver_protected_by_name(self):
        fos = FakeOS()
        fos.add(701, FakeProc(501, "WindowServer"))
        res = _actions(fos, FakeClock()).kill_process(701)
        self.assertEqual(res["code"], CODE_PROTECTED)

    def test_helper_self_protected(self):
        fos = FakeOS(my_pid=9999)
        fos.add(9999, FakeProc(501, "cli_pulse_helper"))
        res = _actions(fos, FakeClock()).kill_process(9999)
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertEqual(fos.table[9999].signals, [])

    def test_helper_parent_protected(self):
        fos = FakeOS(my_ppid=4242)
        fos.add(4242, FakeProc(501, "launchd"))
        res = _actions(fos, FakeClock()).kill_process(4242)
        self.assertEqual(res["code"], CODE_PROTECTED)

    def test_helper_binary_protected_by_name_even_other_pid(self):
        # A *second* helper process (not the running daemon's pid) is still
        # protected by name.
        fos = FakeOS(my_pid=9999)
        fos.add(5555, FakeProc(501, "cli_pulse_helper"))
        res = _actions(fos, FakeClock()).kill_process(5555)
        self.assertEqual(res["code"], CODE_PROTECTED)

    def test_other_uid_refused(self):
        fos = FakeOS(my_uid=501)
        fos.add(2000, FakeProc(0, "some_root_daemon"))  # root-owned
        res = _actions(fos, FakeClock()).kill_process(2000)
        self.assertEqual(res["code"], CODE_NOT_PERMITTED)
        self.assertEqual(fos.table[2000].signals, [])   # never signalled

    def test_nonexistent_pid(self):
        fos = FakeOS()
        res = _actions(fos, FakeClock()).kill_process(31337)
        self.assertEqual(res["code"], CODE_NOT_FOUND)

    def test_already_dead_between_lookup_and_signal(self):
        # proc_info says alive, but the process exits before SIGTERM lands
        # (ProcessLookupError) → treated as a successful termination.
        fos = FakeOS()
        p = FakeProc(501, "gone")
        fos.add(1234, p)

        def racing_signal(pid: int, sig: int) -> None:
            # First real signal: pretend it already exited.
            raise ProcessLookupError(pid)

        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 1, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=racing_signal,
            alive_fn=fos.alive, clock=FakeClock().now, sleep_fn=lambda _dt: None,
        )
        res = a.kill_process(1234)
        self.assertTrue(res["terminated"])
        self.assertFalse(res["escalated"])
        self.assertIsNone(res["error"])

    def test_same_uid_eperm_on_sigterm_is_protected_not_other_user(self):
        # A same-UID SIP/entitlement-protected process (e.g. a same-user Apple
        # agent) passes the same-UID + deny-list guards, then the kernel refuses
        # the signal with EPERM. That must surface as "protected", NOT the false
        # "belongs to another user" (process_not_permitted).
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "ScreenTimeAgent"))

        def eperm_signal(pid, sig):
            if sig == 0:
                return
            raise PermissionError(1, "Operation not permitted")

        clock = FakeClock()
        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 1, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=eperm_signal,
            alive_fn=fos.alive, clock=clock.now, sleep_fn=clock.sleep,
        )
        res = a.kill_process(1234)
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertFalse(res["terminated"])

    def test_survives_sigkill_reports_not_terminated(self):
        # A process still alive after SIGKILL + the confirm window (e.g. stuck in
        # uninterruptible-sleep 'D' on disk/NFS I/O) must report terminated=False,
        # escalated=True — the field the UI surfaces as a "may still be exiting"
        # warning.
        fos = FakeOS()
        p = FakeProc(501, "stuck", dies_after_signal=None)
        fos.add(1234, p)

        def unkillable_signal(pid, sig):
            if sig == 0:
                return
            p.signals.append(sig)  # record but never dies

        clock = FakeClock()  # sleep advances it so the grace/confirm loops end
        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 1, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=unkillable_signal,
            alive_fn=lambda pid: True,  # never confirmed dead
            clock=clock.now, sleep_fn=clock.sleep,
        )
        res = a.kill_process(1234)
        self.assertFalse(res["terminated"])
        self.assertTrue(res["escalated"])
        self.assertIsNone(res["error"])   # signalled, just not confirmed dead
        self.assertIn(signal.SIGKILL, p.signals)

    def test_non_int_pid_protected(self):
        fos = FakeOS()
        a = _actions(fos, FakeClock())
        self.assertEqual(a.kill_process("1234")["code"], CODE_PROTECTED)  # type: ignore[arg-type]
        self.assertEqual(a.kill_process(True)["code"], CODE_PROTECTED)    # bool is not a pid


class TestSignalGuardMatrix(unittest.TestCase):
    """suspend/resume (SIGSTOP/SIGCONT) run the SAME guard prologue as kill —
    same-UID / pid≤1 / deny-list / self / other-UID / rate-limit — but signal
    immediately (no escalation). ProcessLookupError → not_found (unlike kill,
    where a vanished pid is a success); PermissionError → protected."""

    def test_same_uid_suspend_sends_sigstop(self):
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "python3"))
        res = _actions(fos, FakeClock()).signal_process(1234, "suspend")
        self.assertTrue(res["signaled"])
        self.assertEqual(res["action"], "suspend")
        self.assertIsNone(res["code"])
        self.assertEqual(fos.table[1234].signals, [signal.SIGSTOP])

    def test_same_uid_resume_sends_sigcont(self):
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "python3"))
        res = _actions(fos, FakeClock()).signal_process(1234, "resume")
        self.assertTrue(res["signaled"])
        self.assertEqual(fos.table[1234].signals, [signal.SIGCONT])

    def test_unknown_action_rejected(self):
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "python3"))
        res = _actions(fos, FakeClock()).signal_process(1234, "wobble")
        self.assertFalse(res["signaled"])
        self.assertIsNotNone(res["error"])
        self.assertEqual(fos.table[1234].signals, [])  # never signalled

    def test_pid_one_protected(self):
        res = _actions(FakeOS(), FakeClock()).signal_process(1, "suspend")
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertFalse(res["signaled"])

    def test_kernel_task_protected_by_name(self):
        fos = FakeOS()
        fos.add(500, FakeProc(501, "kernel_task"))
        res = _actions(fos, FakeClock()).signal_process(500, "suspend")
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertEqual(fos.table[500].signals, [])

    def test_self_protected(self):
        fos = FakeOS(my_pid=9999)
        fos.add(9999, FakeProc(501, "cli_pulse_helper"))
        res = _actions(fos, FakeClock()).signal_process(9999, "suspend")
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertEqual(fos.table[9999].signals, [])

    def test_other_uid_refused(self):
        fos = FakeOS(my_uid=501)
        fos.add(2000, FakeProc(0, "some_root_daemon"))
        res = _actions(fos, FakeClock()).signal_process(2000, "resume")
        self.assertEqual(res["code"], CODE_NOT_PERMITTED)
        self.assertEqual(fos.table[2000].signals, [])

    def test_missing_pid_is_not_found(self):
        res = _actions(FakeOS(), FakeClock()).signal_process(31337, "suspend")
        self.assertEqual(res["code"], CODE_NOT_FOUND)

    def test_vanished_at_signal_is_not_found(self):
        # proc_info says alive, but the process exits before the signal lands.
        # Unlike kill (success), suspend/resume of a vanished pid → not_found.
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "gone"))

        def racing_signal(pid, sig):
            raise ProcessLookupError(pid)

        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 1, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=racing_signal,
            alive_fn=fos.alive, clock=FakeClock().now, sleep_fn=lambda _dt: None,
        )
        res = a.signal_process(1234, "suspend")
        self.assertEqual(res["code"], CODE_NOT_FOUND)
        self.assertFalse(res["signaled"])

    def test_eperm_is_protected_not_other_user(self):
        # Same-UID SIP-protected process refuses the signal with EPERM → must
        # surface as protected, NOT the false "belongs to another user".
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "ScreenTimeAgent"))

        def eperm_signal(pid, sig):
            raise PermissionError(1, "Operation not permitted")

        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 1, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=eperm_signal,
            alive_fn=fos.alive, clock=FakeClock().now, sleep_fn=lambda _dt: None,
        )
        res = a.signal_process(1234, "suspend")
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertFalse(res["signaled"])

    def test_idempotent_double_suspend_is_ok(self):
        # SIGSTOP on an already-stopped process is a harmless no-op — the guard
        # doesn't read state, and a second SIGSTOP just reports ok again.
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "python3"))
        a = _actions(fos, FakeClock(), rate_limit=10)
        self.assertTrue(a.signal_process(1234, "suspend")["signaled"])
        self.assertTrue(a.signal_process(1234, "suspend")["signaled"])
        self.assertEqual(fos.table[1234].signals, [signal.SIGSTOP, signal.SIGSTOP])

    def test_non_int_pid_protected(self):
        a = _actions(FakeOS(), FakeClock())
        self.assertEqual(a.signal_process("1234", "suspend")["code"], CODE_PROTECTED)  # type: ignore[arg-type]
        self.assertEqual(a.signal_process(True, "suspend")["code"], CODE_PROTECTED)


class TestSharedRateLimit(unittest.TestCase):
    """One rate budget across kill + suspend + resume (a flood across verbs is
    throttled as a whole)."""

    def test_flood_across_verbs_is_rejected(self):
        fos = FakeOS()
        clock = FakeClock()
        for pid in (10, 11, 12):
            fos.add(pid, FakeProc(501, f"p{pid}", dies_after_signal=signal.SIGTERM))
        a = _actions(fos, clock, rate_limit=2, rate_window_s=100.0)
        # One kill + one suspend consume the whole budget of 2…
        self.assertIsNone(a.kill_process(10)["code"])
        self.assertIsNone(a.signal_process(11, "suspend")["code"])
        # …so the third action (a resume) is rate-limited, whatever the verb.
        third = a.signal_process(12, "resume")
        self.assertEqual(third["code"], CODE_RATE_LIMITED)
        self.assertEqual(fos.table[12].signals, [])   # never signalled

    def test_refused_action_does_not_spend_budget(self):
        # A protected/other-uid refusal must not consume a rate token (matches
        # M1 ordering: rate is the LAST guard step).
        fos = FakeOS(my_uid=501)
        fos.add(10, FakeProc(501, "mine", dies_after_signal=signal.SIGTERM))
        fos.add(20, FakeProc(0, "root_daemon"))     # other-uid → refused pre-rate
        a = _actions(fos, FakeClock(), rate_limit=1, rate_window_s=100.0)
        self.assertEqual(a.signal_process(20, "suspend")["code"], CODE_NOT_PERMITTED)
        # The refusal above didn't spend the single token, so this one is allowed.
        self.assertIsNone(a.signal_process(10, "suspend")["code"])


class TestManagedChildDenyForSuspend(unittest.TestCase):
    """Belt-and-suspenders: `suspend` refuses the helper's own managed-session
    child pids (so a user can't freeze a session they're driving). Resume and
    kill are unaffected (resuming a session you froze elsewhere is fine)."""

    def _actions_with_managed(self, fos, clock, managed):
        return MachineActions(
            getuid=lambda: fos.my_uid, getpid=lambda: fos.my_pid,
            getppid=lambda: fos.my_ppid, proc_info=fos.proc_info,
            signal_fn=fos.signal, alive_fn=fos.alive,
            clock=clock.now, sleep_fn=clock.sleep,
            managed_pids_fn=lambda: managed,
        )

    def test_suspend_managed_child_refused(self):
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "claude"))
        a = self._actions_with_managed(fos, FakeClock(), {1234})
        res = a.signal_process(1234, "suspend")
        self.assertEqual(res["code"], CODE_PROTECTED)
        self.assertEqual(fos.table[1234].signals, [])   # never frozen

    def test_resume_managed_child_allowed(self):
        # Resume is exempt — un-freezing a managed session is safe/desirable.
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "claude"))
        a = self._actions_with_managed(fos, FakeClock(), {1234})
        self.assertTrue(a.signal_process(1234, "resume")["signaled"])

    def test_managed_pids_fn_raising_is_soft(self):
        # A broken accessor must NOT block a legitimate suspend.
        fos = FakeOS()
        fos.add(1234, FakeProc(501, "python3"))

        def boom():
            raise RuntimeError("manager exploded")

        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 9999, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=fos.signal, alive_fn=fos.alive,
            clock=FakeClock().now, sleep_fn=lambda _dt: None,
            managed_pids_fn=boom,
        )
        self.assertTrue(a.signal_process(1234, "suspend")["signaled"])


class TestRateLimit(unittest.TestCase):
    def test_flood_is_rejected(self):
        fos = FakeOS()
        clock = FakeClock()
        # 3 killable same-UID processes; limit of 2 in the window.
        for pid in (10, 11, 12):
            fos.add(pid, FakeProc(501, f"p{pid}", dies_after_signal=signal.SIGTERM))
        a = _actions(fos, clock, rate_limit=2, rate_window_s=100.0)
        self.assertIsNone(a.kill_process(10)["code"])
        self.assertIsNone(a.kill_process(11)["code"])
        # Third within the window → rate limited (never signalled).
        third = a.kill_process(12)
        self.assertEqual(third["code"], CODE_RATE_LIMITED)
        self.assertEqual(fos.table[12].signals, [])

    def test_window_slides(self):
        fos = FakeOS()
        clock = FakeClock()
        for pid in (10, 11):
            fos.add(pid, FakeProc(501, f"p{pid}", dies_after_signal=signal.SIGTERM))
        a = _actions(fos, clock, rate_limit=1, rate_window_s=5.0)
        self.assertIsNone(a.kill_process(10)["code"])
        # Advance past the window → the next kill is allowed again.
        clock.t += 6.0
        self.assertIsNone(a.kill_process(11)["code"])


class TestPsProcInfoParsing(unittest.TestCase):
    """The default proc_info shells out to `ps`; parse its output shape."""

    def test_parses_uid_and_comm(self):
        captured = {}

        def fake_run(argv, **kw):
            captured["argv"] = argv

            class R:
                returncode = 0
                stdout = "  501 Google Chrome\n"
            return R()

        orig = ma.subprocess.run
        ma.subprocess.run = fake_run  # type: ignore[assignment]
        try:
            info = ma._ps_proc_info(1234)
        finally:
            ma.subprocess.run = orig  # type: ignore[assignment]
        self.assertEqual(info, (501, "Google Chrome"))
        self.assertIn("-p", captured["argv"])

    def test_missing_process_returns_none(self):
        def fake_run(argv, **kw):
            class R:
                returncode = 1
                stdout = ""
            return R()

        orig = ma.subprocess.run
        ma.subprocess.run = fake_run  # type: ignore[assignment]
        try:
            self.assertIsNone(ma._ps_proc_info(1234))
        finally:
            ma.subprocess.run = orig  # type: ignore[assignment]


class TestZombieLiveness(unittest.TestCase):
    """A killed child becomes a zombie until reaped; `os.kill(pid, 0)` still
    succeeds for it, so `_default_alive` must rule out the 'Z' state — else a
    kill of one of the helper's own managed sessions falsely reports survival."""

    def _patch_ps_state(self, state: str):
        def fake_run(argv, **kw):
            class R:
                returncode = 0
                stdout = state + "\n"
            return R()
        return fake_run

    def test_zombie_reported_dead(self):
        orig = ma.subprocess.run
        ma.subprocess.run = self._patch_ps_state("Z")  # type: ignore[assignment]
        try:
            # signal 0 "succeeds" (process still in table) but it's a zombie.
            self.assertFalse(ma._default_alive(1234, lambda pid, sig: None))
        finally:
            ma.subprocess.run = orig  # type: ignore[assignment]

    def test_live_process_reported_alive(self):
        orig = ma.subprocess.run
        ma.subprocess.run = self._patch_ps_state("S")  # sleeping = alive
        try:
            self.assertTrue(ma._default_alive(1234, lambda pid, sig: None))
        finally:
            ma.subprocess.run = orig  # type: ignore[assignment]

    def test_gone_process_fast_path(self):
        # ProcessLookupError → dead without ever consulting ps.
        def boom(pid, sig):
            raise ProcessLookupError(pid)
        self.assertFalse(ma._default_alive(1234, boom))

    def test_zombie_child_terminated_not_escalated(self):
        # End-to-end through kill_process: a same-UID process that goes zombie
        # on SIGTERM must report terminated=True, escalated=False (no needless
        # SIGKILL), matching the real-OS child-reap behaviour.
        fos = FakeOS()

        class ZombieProc(FakeProc):
            def __init__(self):
                super().__init__(501, "managed_sess")
                self.zombied = False

        p = ZombieProc()
        fos.add(1234, p)

        def signal_fn(pid, sig):
            if sig == 0:
                if pid not in fos.table or not fos.table[pid].alive:
                    raise ProcessLookupError(pid)
                return
            fos.table[pid].signals.append(sig)
            if sig == signal.SIGTERM:
                fos.table[pid].zombied = True  # dies but lingers as a zombie

        def alive_fn(pid):
            pr = fos.table.get(pid)
            if pr is None:
                return False
            # A zombie is reported dead (mirrors the real _default_alive).
            return not getattr(pr, "zombied", False)

        a = MachineActions(
            getuid=lambda: 501, getpid=lambda: 1, getppid=lambda: 1,
            proc_info=fos.proc_info, signal_fn=signal_fn, alive_fn=alive_fn,
            clock=FakeClock().now, sleep_fn=lambda _dt: None,
        )
        res = a.kill_process(1234)
        self.assertTrue(res["terminated"])
        self.assertFalse(res["escalated"])
        self.assertEqual(p.signals, [signal.SIGTERM])  # never SIGKILL


if __name__ == "__main__":
    unittest.main()
