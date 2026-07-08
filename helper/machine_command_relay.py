"""Machine-command relay (v1.41 "Mobile Machine", Track B helper side).

Bridges the cloud `machine_commands` queue to the Mac APP executor. The Python
helper CANNOT speak NSXPC to the root fan daemon, so it does NOT execute fan/LPM
commands itself — it only RELAYS:

  * daemon loop (~1 Hz) → `pull_from_cloud()` drains pending machine commands
    from Supabase (`remote_helper_pull_machine_commands`) into a local queue,
    but ONLY when the Mac app executor is alive + opted-in (see `should_pull`).
  * Mac app (DEVID, `RemoteMachineExecutor`) polls the UDS ~2 s:
      - `pull_machine_commands`         → `drain_for_app()` hands over the queue.
      - `report_machine_control_state`  → `report_control_state()` records the
        executor's live {remote_fan, remote_lpm, boost_active, boost_target_rpm}.
      - `complete_machine_command`      → `complete()` writes the typed result
        back to Supabase (`remote_helper_complete_machine_command`).
  * the heartbeat folds `heartbeat_metrics_fragment()` into `p_metrics` so the
    phone renders ONLY the controls the Mac will honor (honest capability map)
    and sees honest fan-boost state.

WHY gate pulling on a fresh executor report: a fan command must never be pulled
(→ marked `delivered`) when no executor is around to run it — it would be
orphaned instead of expiring server-side (60 s). So the relay only pulls after
the executor has reported within `_CONTROL_FRESH_S`. When the executor goes away
(app quit / opt-in off), the fragment actively clears `machine_controls` + boost
so the phone HIDES the controls rather than showing stale ones.

The fan dead-man heartbeat NEVER lives here — it stays in the Mac app executor +
the root daemon (2.5 s beat / 8 s dead-man). This relay carries requests only.

Thread-safety: the daemon loop (pull + heartbeat) and the UDS connection threads
all touch this concurrently; ONE lock guards all mutable state. Every method is
fail-soft — a relay error must never break the heartbeat or the daemon loop.
"""
from __future__ import annotations

import logging
import threading
import time
from typing import Any, Callable, Optional

logger = logging.getLogger("cli_pulse.machine_relay")

# A reported control state is "fresh" for this long. The executor reports on its
# ~2 s poll, so 15 s tolerates a few missed polls before we treat it as gone.
_CONTROL_FRESH_S = 15.0

# Defense-in-depth: a command pulled (→ marked `delivered` server-side) but not
# drained by the app within this window is DROPPED on the next drain, so a fan
# command can never actuate late (app quit between pull and drain, relaunched
# hours later). Matches the 60 s server-side pickup expiry. PR-4's executor also
# enforces the command's own TTL against created_at — this is the helper-side backstop.
_QUEUE_MAX_AGE_S = 60.0

# Completion statuses the helper will forward to the cloud (mirrors the RPC).
_COMPLETION_STATUSES = ("done", "failed")


def _as_bool(value: Any) -> bool:
    return value is True


def _as_pos_int(value: Any) -> Optional[int]:
    # A JSON bool is an int subclass — reject it explicitly.
    if isinstance(value, bool):
        return None
    if isinstance(value, int) and value > 0:
        return value
    return None


class MachineCommandRelay:
    """Cloud ↔ Mac-app relay for device-scoped fan/LPM commands. See module doc."""

    def __init__(
        self,
        rpc_caller: Callable[..., Any],
        device_id: str,
        helper_secret: str,
        *,
        clock: Callable[[], float] = time.monotonic,
        control_fresh_s: float = _CONTROL_FRESH_S,
        queue_max_age_s: float = _QUEUE_MAX_AGE_S,
    ) -> None:
        self._rpc_caller = rpc_caller
        self._device_id = device_id
        self._helper_secret = helper_secret
        self._clock = clock
        self._control_fresh_s = control_fresh_s
        self._queue_max_age_s = queue_max_age_s
        self._lock = threading.Lock()
        self._queue: list[tuple[float, dict]] = []  # (pulled_at, cmd) awaiting drain
        self._control_state: Optional[dict] = None  # last executor report
        self._reported_at: float = 0.0

    # ── executor liveness ────────────────────────────────────────────

    def _control_is_fresh_locked(self) -> bool:
        return (
            self._control_state is not None
            and (self._clock() - self._reported_at) <= self._control_fresh_s
        )

    def should_pull(self) -> bool:
        """Only pull from the cloud when a fresh executor report says the Mac
        can currently honor at least one remote control. Otherwise the command
        is left to expire server-side (60 s) instead of being orphaned."""
        with self._lock:
            if not self._control_is_fresh_locked():
                return False
            st = self._control_state or {}
            return bool(st.get("remote_fan")) or bool(st.get("remote_lpm"))

    # ── cloud → local (daemon loop, ~1 Hz) ───────────────────────────

    def pull_from_cloud(self, max_commands: int = 10) -> int:
        """Pull pending machine commands into the local queue. Returns the count
        pulled (0 on gate-closed / error / empty). Never raises."""
        if not self.should_pull():
            return 0
        try:
            result = self._rpc_caller(
                "remote_helper_pull_machine_commands",
                {
                    "p_device_id": self._device_id,
                    "p_helper_secret": self._helper_secret,
                    "p_max": max_commands,
                },
            )
        except Exception as exc:  # noqa: BLE001 — daemon loop must keep running
            logger.debug("pull_machine_commands skipped: %s", exc)
            return 0
        if not isinstance(result, list) or not result:
            return 0
        picked = [c for c in result if isinstance(c, dict) and c.get("id")]
        if not picked:
            return 0
        now = self._clock()
        with self._lock:
            self._queue.extend((now, c) for c in picked)
        logger.info("relayed %d machine command(s) from cloud queue", len(picked))
        return len(picked)

    # ── local → app (UDS: pull_machine_commands) ─────────────────────

    def drain_for_app(self) -> list[dict]:
        """Hand the queued commands to the app executor and clear the queue.
        The commands are already `delivered` server-side (marked at pull); the
        executor acks each via `complete`. Drops any command pulled more than
        `queue_max_age_s` ago so a late fan command can never actuate (see
        _QUEUE_MAX_AGE_S)."""
        now = self._clock()
        with self._lock:
            queued = self._queue
            self._queue = []
        fresh = [cmd for (pulled_at, cmd) in queued if (now - pulled_at) <= self._queue_max_age_s]
        dropped = len(queued) - len(fresh)
        if dropped:
            logger.info("dropped %d stale machine command(s) on drain", dropped)
        return fresh

    # ── app → cloud (UDS: complete_machine_command) ──────────────────

    def complete(
        self, command_id: str, status: str, result: Optional[dict] = None
    ) -> dict:
        """Forward the executor's typed completion to the cloud. Raises
        ValueError on a bad status (the UDS layer maps it to bad_request)."""
        if status not in _COMPLETION_STATUSES:
            raise ValueError(f"invalid completion status: {status!r}")
        payload: dict = {
            "p_device_id": self._device_id,
            "p_helper_secret": self._helper_secret,
            "p_command_id": command_id,
            "p_status": status,
        }
        if isinstance(result, dict) and result:
            payload["p_result"] = result
        self._rpc_caller("remote_helper_complete_machine_command", payload)
        return {"status": "ok"}

    # ── app → local (UDS: report_machine_control_state) ──────────────

    def report_control_state(self, state: dict) -> None:
        """Record the executor's live control state (called ~every 2 s). Only
        the four known fields are kept; everything else is dropped."""
        normalized = {
            "remote_fan": _as_bool(state.get("remote_fan")),
            "remote_lpm": _as_bool(state.get("remote_lpm")),
            "boost_active": _as_bool(state.get("boost_active")),
            "boost_target_rpm": _as_pos_int(state.get("boost_target_rpm")),
        }
        with self._lock:
            self._control_state = normalized
            self._reported_at = self._clock()

    # ── local → heartbeat (fold into p_metrics) ──────────────────────

    def heartbeat_metrics_fragment(self) -> dict:
        """The machine-control slice of the heartbeat's p_metrics.

        Fresh executor report → honest {machine_controls, fan_boost_active,
        fan_boost_target_rpm}. Stale/none (executor gone) → actively clear
        machine_controls + boost so the phone HIDES the controls (the RPC's
        coalesce would otherwise preserve the last-known, leaving ghost UI)."""
        with self._lock:
            if not self._control_is_fresh_locked():
                return {"machine_controls": {}, "fan_boost_active": False}
            st = self._control_state or {}
            frag: dict = {
                "machine_controls": {
                    "remote_fan": bool(st.get("remote_fan")),
                    "remote_lpm": bool(st.get("remote_lpm")),
                },
                "fan_boost_active": bool(st.get("boost_active")),
            }
            rpm = st.get("boost_target_rpm")
            if isinstance(rpm, int) and not isinstance(rpm, bool) and rpm > 0:
                frag["fan_boost_target_rpm"] = rpm
            return frag
