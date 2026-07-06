"""Guarded same-UID process actions for the Machine tab (M1 + v1.38.1).

NO root. The unsandboxed user LaunchAgent helper already runs as the user
and may `kill(2)` / `SIGSTOP` / `SIGCONT` its own same-UID processes; this
module adds the guardrails the bare syscalls lack:

  * a **same-UID owner check** — root / other-user pids are refused (that
    needs the future M2 root helper, deliberately out of scope here);
  * a **deny-list of critical targets** — pid ≤ 1, `kernel_task`,
    `launchd`, `WindowServer`, `loginwindow`, and the helper itself;
  * for **suspend**, an additional belt-and-suspenders deny of the
    helper's own managed-session child pids so a user can't freeze a
    session they are driving from the app;
  * a **SIGTERM → grace window → SIGKILL** escalation (kill only —
    suspend/resume are immediate, no escalation);
  * a **sliding-window rate limit** so a flood is rejected. The limiter is
    SHARED across kill + suspend + resume (one budget throttles a flood
    across every verb).

The two public entry points — `kill_process` (M1) and `signal_process`
(v1.38.1 Suspend/Resume) — run the SAME validate → same-UID → deny-list →
rate-limit prologue (`_authorize`), so the guards can't drift between the
destructive and the reversible verb.

Everything that touches the OS is injected (`proc_info` / `signal_fn` /
`alive_fn` / `clock` / `sleep_fn` / `managed_pids_fn`) so the whole guard
matrix is unit-testable without spawning real processes.

Neither entry point raises for an *operational* refusal — each returns a
structured dict (`{terminated, escalated, error, code}` for kill,
`{signaled, action, error, code}` for signal). The UDS server
(`local_session_server`) maps a non-None `code` to a wire-level error
that the Swift `SessionControlErrorMapping` turns into a user message.

Idempotence (suspend/resume): SIGCONT on an already-running process and
SIGSTOP on an already-stopped process are harmless kernel no-ops, so
`signal_process` reports ok without needing to read state first.

Security note (TOCTOU): the owner-uid + comm are re-read from `ps` at the
moment of the kill, NOT trusted from the (possibly stale) snapshot the UI
rendered — so a pid that was recycled to a root/protected process between
snapshot and click is caught. A residual micro-window between that `ps`
read and `kill(2)` remains, but for a *same-UID* kill it grants no
privilege the caller (same user) doesn't already have; the race-free
`audit_token` design is reserved for the ROOT path (M2), per DEV_PLAN.
"""
from __future__ import annotations

import collections
import logging
import os
import signal
import subprocess
import threading
from typing import Callable, Iterable, Optional

logger = logging.getLogger("cli_pulse.machine_actions")

# ── wire error codes (forwarded verbatim as reply error.code) ──────
# Kept in lockstep with the Swift `SessionControlErrorMapping` cases.
CODE_NOT_FOUND = "process_not_found"
CODE_PROTECTED = "process_protected"
CODE_NOT_PERMITTED = "process_not_permitted"
CODE_RATE_LIMITED = "rate_limited"
CODE_INTERNAL = "internal"

# comm basenames we never signal, regardless of owner uid. The same-UID
# check already refuses all of these on a normal account (they run as
# root), but we deny by name too as defense-in-depth against a pid that
# was recycled to one of them between snapshot and kill, and against the
# rare same-UID edge. Matched case-insensitively on the basename.
_PROTECTED_COMM = frozenset({
    "kernel_task",
    "launchd",
    "windowserver",
    "loginwindow",
    "logind",
    # The helper's own frozen binary + the macOS app. Killing the running
    # daemon is separately blocked by the self-pid guard, but a second
    # helper process (or the app) is protected by name so the Machine tab
    # can never turn the feature against the thing hosting it.
    "cli_pulse_helper",
    "cli pulse bar",
})


def _basename(comm: str) -> str:
    """Last path component of a comm string (defensive — `ps -c` already
    yields the basename, but `ps` without `-c` or a future caller might
    hand us a full path)."""
    return os.path.basename(comm.strip())


def _ps_proc_info(pid: int) -> Optional[tuple[int, str]]:
    """Return `(owner_uid, comm_basename)` for `pid`, or None if the pid
    does not exist / can't be read. Uses `ps -c -o uid=,comm=` so comm is
    the executable basename (matches the snapshot's `-c` collection)."""
    try:
        proc = subprocess.run(
            ["ps", "-c", "-o", "uid=,comm=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        logger.debug("ps lookup for pid %s failed: %s", pid, exc)
        return None
    if proc.returncode != 0:
        return None
    line = proc.stdout.strip()
    if not line:
        return None
    parts = line.split(None, 1)
    if not parts or not parts[0].isdigit():
        return None
    uid = int(parts[0])
    comm = parts[1].strip() if len(parts) > 1 else ""
    return uid, comm


def _is_zombie(pid: int) -> bool:
    """True iff `pid` is a zombie (state 'Z' — terminated but not yet reaped
    by its parent). Can't tell → False (don't over-claim death)."""
    try:
        proc = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)],
            capture_output=True, text=True, timeout=5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return False
    if proc.returncode != 0:
        return False
    return proc.stdout.strip().startswith("Z")


def _default_alive(pid: int, signal_fn: Callable[[int, int], None]) -> bool:
    """Liveness probe. True = alive, False = gone.

    `os.kill(pid, 0)` succeeds for a **zombie** — a process we (or its real
    parent) killed but that hasn't been reaped yet. A zombie is effectively
    dead, so when signal 0 says "exists" we additionally rule out the zombie
    state. This matters when the target is one of the helper's OWN children (a
    managed session): SIGTERM leaves a zombie the helper reaps asynchronously,
    and without this check the grace loop would falsely see it "survive",
    needlessly escalate to SIGKILL, and report terminated=False. The fast path
    (ProcessLookupError → dead) covers non-child processes, whose real parent
    reaps them, so the extra `ps` only runs while a pid still lingers.
    """
    try:
        signal_fn(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return False
    return not _is_zombie(pid)


def _result(*, terminated: bool = False, escalated: bool = False,
            error: Optional[str] = None, code: Optional[str] = None) -> dict:
    return {"terminated": terminated, "escalated": escalated,
            "error": error, "code": code}


def _signal_result(*, action: str, signaled: bool = False,
                   error: Optional[str] = None, code: Optional[str] = None) -> dict:
    """Result of `signal_process`. `signaled` is True when the SIGSTOP/SIGCONT
    was delivered (or the pid was already in the requested state — a harmless
    idempotent no-op). On refusal `error`/`code` are set and `signaled` False.
    Mirrors `_result` so the UDS handler maps `code` the same way for both
    verbs."""
    return {"signaled": signaled, "action": action, "error": error, "code": code}


class MachineActions:
    """Stateful (rate-limit window) process-action guard. Construct once
    per helper; `kill_process` is safe to call from multiple connection
    threads (the rate window is lock-guarded)."""

    def __init__(
        self,
        *,
        getuid: Callable[[], int] = os.getuid,
        getpid: Callable[[], int] = os.getpid,
        getppid: Callable[[], int] = os.getppid,
        proc_info: Optional[Callable[[int], Optional[tuple[int, str]]]] = None,
        signal_fn: Callable[[int, int], None] = os.kill,
        alive_fn: Optional[Callable[[int], bool]] = None,
        clock: Callable[[], float] = None,  # type: ignore[assignment]
        sleep_fn: Callable[[float], None] = None,  # type: ignore[assignment]
        grace_s: float = 2.0,
        poll_interval_s: float = 0.1,
        sigkill_confirm_s: float = 0.5,
        rate_limit: int = 5,
        rate_window_s: float = 10.0,
        protected_comm: frozenset[str] = _PROTECTED_COMM,
        managed_pids_fn: Optional[Callable[[], "Iterable[int]"]] = None,
    ) -> None:
        import time as _time  # local so a monkeypatched module-level time
        self._getuid = getuid
        self._getpid = getpid
        self._getppid = getppid
        self._proc_info = proc_info or _ps_proc_info
        self._signal = signal_fn
        self._alive = alive_fn or (lambda pid: _default_alive(pid, signal_fn))
        # Belt-and-suspenders (v1.38.1): the helper's own managed-session child
        # pids. `suspend` refuses these so a user can't freeze a session they're
        # driving from the app. None ⇒ feature off (unit tests, unpaired helper).
        # Best-effort + fail-soft: a raising callable is treated as "no managed
        # pids" so it can never break a legitimate action.
        self._managed_pids_fn = managed_pids_fn
        self._clock = clock or _time.monotonic
        self._sleep = sleep_fn or _time.sleep
        self._grace_s = grace_s
        self._poll_interval_s = poll_interval_s
        self._sigkill_confirm_s = sigkill_confirm_s
        self._rate_limit = rate_limit
        self._rate_window_s = rate_window_s
        self._protected_comm = frozenset(c.lower() for c in protected_comm)
        self._recent: collections.deque[float] = collections.deque()
        self._lock = threading.Lock()

    # ── public ──────────────────────────────────────────────

    def kill_process(self, pid: int) -> dict:
        """Validate + terminate `pid` (same-UID only). Returns
        `{terminated, escalated, error, code}`; `error`/`code` are None on
        success. Never raises for an operational refusal."""
        error, code, comm = self._authorize(pid)
        if error is not None:
            return _result(error=error, code=code)
        logger.info("kill_process pid=%s comm=%r → SIGTERM", pid, comm)
        return self._terminate(pid)

    def signal_process(self, pid: int, action: str) -> dict:
        """Suspend (`SIGSTOP`) or resume (`SIGCONT`) a same-UID process.

        Runs the SAME guard prologue as `kill_process` (validate → same-UID →
        deny-list → shared rate limit), then delivers the signal IMMEDIATELY —
        no SIGTERM→grace→SIGKILL escalation (that's the kill path). Returns
        `{signaled, action, error, code}`; never raises for an operational
        refusal.

        `action` must be "suspend" or "resume". Idempotent: SIGCONT on a
        running process / SIGSTOP on a stopped one is a harmless kernel no-op
        that reports `signaled=True`. `ProcessLookupError` (the pid vanished
        between the ps read and the signal) maps to `process_not_found`;
        `PermissionError` (same-UID but SIP/entitlement-protected) maps to
        `process_protected` — mirrors the M1 EPERM-is-protected fix."""
        if action not in ("suspend", "resume"):
            return _signal_result(action=action,
                                  error=f"unknown action {action!r}",
                                  code=CODE_INTERNAL)
        error, code, comm = self._authorize(pid, suspend=(action == "suspend"))
        if error is not None:
            return _signal_result(action=action, error=error, code=code)
        sig = signal.SIGSTOP if action == "suspend" else signal.SIGCONT
        logger.info("signal_process pid=%s comm=%r action=%s", pid, comm, action)
        try:
            self._signal(pid, sig)
        except ProcessLookupError:
            # Unlike kill (where a vanished pid is a successful termination),
            # a vanished suspend/resume target is "not found" — the user's
            # intended target no longer exists to act on.
            return _signal_result(action=action, error="no such process",
                                  code=CODE_NOT_FOUND)
        except PermissionError:
            # Same-UID was proven in _authorize, so EPERM here means a
            # kernel/SIP-protected process, NOT another user's — surface as
            # protected (never the false "belongs to another user").
            return _signal_result(
                action=action,
                error="the system does not permit signalling this process",
                code=CODE_PROTECTED)
        except OSError as exc:
            return _signal_result(action=action, error=f"{action} failed: {exc}",
                                  code=CODE_INTERNAL)
        return _signal_result(action=action, signaled=True)

    # ── internal ────────────────────────────────────────────

    def _authorize(self, pid: int, *, suspend: bool = False
                   ) -> tuple[Optional[str], Optional[str], Optional[str]]:
        """Shared guard prologue for kill + suspend + resume. Returns
        `(error, code, comm)`: on refusal `error`/`code` are set and `comm`
        is None; on success all-clear `error`/`code` are None and `comm` is
        the validated process comm.

        A rate-limit token is consumed ONLY on a fully-authorized call — the
        last step, exactly like the original M1 ordering — so a refused action
        (protected / other-user / missing) never spends budget. The limiter is
        shared across every verb (one flood budget).

        `suspend=True` adds the belt-and-suspenders managed-session deny-list.
        """
        # 1. type / range. pid ≤ 1 is the init/kernel band → protected.
        if not isinstance(pid, int) or isinstance(pid, bool):
            return "pid must be an integer", CODE_PROTECTED, None
        if pid <= 1:
            return "pid ≤ 1 is protected", CODE_PROTECTED, None

        # 2. never signal the helper itself (running daemon) or its parent
        #    (launchd). Cheap, and independent of the ps lookup below.
        if pid == self._getpid() or pid == self._getppid():
            return "refusing to signal the helper itself", CODE_PROTECTED, None

        # 3. authoritative owner + comm at signal-time (TOCTOU-tight — see
        #    module docstring). A None here means the pid vanished.
        info = self._proc_info(pid)
        if info is None:
            return "no such process", CODE_NOT_FOUND, None
        owner_uid, comm = info

        # 4. same-UID only. Root / other-user pids need the M2 root helper.
        if owner_uid != self._getuid():
            return ("process is owned by another user (same-UID only)",
                    CODE_NOT_PERMITTED, None)

        # 5. protected comm deny-list (defense-in-depth over the uid check).
        if _basename(comm).lower() in self._protected_comm:
            return f"{comm!r} is a protected system process", CODE_PROTECTED, None

        # 6. suspend-only: never freeze a CLI Pulse managed session the user is
        #    driving from the app (belt-and-suspenders; the real IPC-deadlock
        #    hazard is already bounded by per-session PTY read threads).
        if suspend and self._is_managed_child(pid):
            return ("refusing to suspend a CLI Pulse managed session",
                    CODE_PROTECTED, None)

        # 7. rate limit — reject a flood before we start signalling. Shared
        #    budget across kill + suspend + resume.
        if not self._allow_rate():
            return "too many process actions; slow down", CODE_RATE_LIMITED, None

        return None, None, comm

    def _is_managed_child(self, pid: int) -> bool:
        """True iff `pid` is one of the helper's own managed-session child
        pids. Fail-soft: a missing or raising `managed_pids_fn` is treated as
        "not managed" so it can never wrongly refuse a legitimate suspend."""
        if self._managed_pids_fn is None:
            return False
        try:
            return pid in set(self._managed_pids_fn())
        except Exception:  # noqa: BLE001 — a broken accessor must not block actions
            logger.debug("managed_pids_fn raised; treating pid %s as unmanaged", pid)
            return False

    def _allow_rate(self) -> bool:
        now = self._clock()
        with self._lock:
            cutoff = now - self._rate_window_s
            while self._recent and self._recent[0] <= cutoff:
                self._recent.popleft()
            if len(self._recent) >= self._rate_limit:
                return False
            self._recent.append(now)
            return True

    def _terminate(self, pid: int) -> dict:
        # SIGTERM first — let the process clean up.
        try:
            self._signal(pid, signal.SIGTERM)
        except ProcessLookupError:
            return _result(terminated=True)          # already gone
        except PermissionError:
            # Same-UID was already proven at step 4, so an EPERM here means the
            # kernel/SIP protects THIS specific process (e.g. a same-user Apple
            # platform-binary agent that refuses signals). It's "protected",
            # NOT another user's process — using CODE_NOT_PERMITTED here would
            # surface the false "belongs to another user" message.
            return _result(error="the system does not permit ending this process",
                           code=CODE_PROTECTED)
        except OSError as exc:
            return _result(error=f"SIGTERM failed: {exc}", code=CODE_INTERNAL)

        # Grace window — poll for a clean exit.
        deadline = self._clock() + self._grace_s
        while self._clock() < deadline:
            if not self._alive(pid):
                return _result(terminated=True, escalated=False)
            self._sleep(self._poll_interval_s)

        # Still alive → escalate to SIGKILL (can't be caught).
        if not self._alive(pid):
            return _result(terminated=True, escalated=False)
        logger.info("kill_process pid=%s survived grace → SIGKILL", pid)
        try:
            self._signal(pid, signal.SIGKILL)
        except ProcessLookupError:
            return _result(terminated=True, escalated=True)
        except PermissionError:
            # Symmetric with the SIGTERM branch: a same-UID EPERM is a
            # kernel/SIP-protected process, not a cross-user refusal.
            return _result(terminated=False, escalated=True,
                           error="the system does not permit ending this process",
                           code=CODE_PROTECTED)
        except OSError as exc:
            return _result(terminated=False, escalated=True,
                           error=f"SIGKILL failed: {exc}", code=CODE_INTERNAL)

        # Brief confirm that SIGKILL took.
        kdeadline = self._clock() + self._sigkill_confirm_s
        while self._clock() < kdeadline:
            if not self._alive(pid):
                return _result(terminated=True, escalated=True)
            self._sleep(self._poll_interval_s)
        return _result(terminated=not self._alive(pid), escalated=True)
