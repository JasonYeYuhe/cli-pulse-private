"""Machine-health collection (System Monitor slice S2).

Root-free, UNSANDBOXED-helper-only. Reads via CLI oracles proven on Apple
Silicon (`ps` / `ioreg AppleSmartBattery` / `pmset`). The native SMC / IOReport
/ IOHID sensors (die temps, fan RPM, power draw, per-core freq) land in S3 as a
separate module whose readings merge into `capability` + the metrics blob here.

Two consumers, deliberately different shapes:
  * the UDS `get_machine_snapshot` method → the RICH, LOCAL snapshot (incl. the
    per-process table + byte-level memory) for the Mac app's Machine view.
  * `heartbeat_metrics()` → the COMPACT `p_metrics` blob synced to `devices`
    (battery + thermal + capability). Per DEV_PLAN §4 the per-process table is
    NEVER synced (privacy + volume) — only the small fixed device-health summary.

Everything here is fail-soft: a collector that hits an error returns safe
defaults (None / empty), never raises — a broken sensor read must never break
the heartbeat or the UDS reply. Mirrors `system_collector.collect_all`.
"""
from __future__ import annotations

import logging
import os
import plistlib
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional

logger = logging.getLogger("cli_pulse.machine")

# Battery-state enum accepted by the v0.63 helper_heartbeat RPC.
_BATTERY_STATES = ("charging", "discharging", "charged", "none", "unknown")


@dataclass
class ProcessInfo:
    pid: int
    name: str
    cpu_percent: float
    rss_mb: float
    # Owner UID. Surfaced so the Mac app can offer the M1 "End Process"
    # affordance ONLY on same-UID rows (a root/other-user pid can't be
    # killed without the future root helper). NEVER synced — the whole
    # per-process table stays local (see module docstring).
    uid: int = -1
    # Process state (v1.38.1 Suspend/Resume): "running" | "stopped" | "other".
    # Derived from the BSD `ps` STAT column (T→stopped, Z→other, else running).
    # The Mac app uses it to choose Suspend vs Resume + render a "Paused" badge.
    # Defaults to "running" so an OLD helper (no state column) and any
    # unparseable row degrade to the safe, actionable value. NEVER synced.
    state: str = "running"


@dataclass
class BatteryThermal:
    """Battery health + system thermal state. All fields Optional — None means
    "not available on this device" (e.g. a desktop Mac has no battery node)."""
    has_battery: bool = False
    charge_pct: Optional[int] = None
    state: Optional[str] = None            # charging|discharging|charged|none|unknown
    cycle_count: Optional[int] = None
    health_pct: Optional[float] = None     # AppleRawMaxCapacity / DesignCapacity * 100
    design_capacity: Optional[int] = None  # mAh
    current_capacity: Optional[int] = None # mAh (AppleRawMaxCapacity)
    battery_temp_c: Optional[float] = None
    adapter_watts: Optional[float] = None
    thermal_state: Optional[int] = None    # NSProcessInfo.thermalState-style 0..3


@dataclass
class MachineSnapshot:
    collected_at: str
    cpu_percent: int
    memory_percent: int
    memory_used_bytes: int
    memory_total_bytes: int
    battery: BatteryThermal
    top_processes: list[ProcessInfo]
    capability: dict[str, bool]
    # S3 fills this with the native sensor block (temps/fans/power/freq); None
    # until then. Kept here so the UDS snapshot has one place for everything.
    sensors: Optional[dict] = None


# ── pure parsers (unit-tested with fixtures; no subprocess) ─────────


def _normalize_state(raw: str) -> str:
    """Map a BSD `ps` STAT column to "running" | "stopped" | "other".

    Only the FIRST char is the primary state code; the rest are modifiers
    (e.g. "Ss", "S+", "R<", "TN", "SNs", "Us") and the whole token never
    contains a space (confirmed on macOS), so it splits cleanly as one field.
      * 'T' → stopped   (SIGSTOP'd or traced — the Suspend/Resume target)
      * 'Z' → other     (zombie/defunct — not actionable; no Suspend/Resume)
      * everything else (R/S/I/U/…) → running
    """
    if not raw:
        return "running"
    c = raw[0]
    if c == "T":
        return "stopped"
    if c == "Z":
        return "other"
    return "running"


def parse_top_processes(ps_stdout: str, limit: Optional[int] = 12) -> list[ProcessInfo]:
    """Parse `ps -Aceo pid,uid,pcpu,rss,state,comm` output (order preserved).

    Six columns now (v1.38.1 adds `state` before `comm`): the BSD STAT column
    is a single space-free token, so `split(None, 5)` isolates it and keeps the
    trailing free-form `comm` (which may contain spaces, e.g. "Google Chrome
    Helper (Renderer)"). A header row and any malformed row are skipped. Returns
    at most `limit` rows (all rows when `limit is None`). The `uid` column gates
    the "End Process" / Suspend affordances to same-UID rows; `state` chooses
    Suspend vs Resume.
    """
    rows: list[ProcessInfo] = []
    for line in ps_stdout.splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(None, 5)
        if len(parts) < 6:
            continue
        pid_s, uid_s, cpu_s, rss_s, state_s, comm = parts
        if not pid_s.isdigit():   # header row ("PID UID %CPU RSS STAT COMM") or junk
            continue
        try:
            rows.append(ProcessInfo(
                pid=int(pid_s),
                name=comm.strip(),
                cpu_percent=round(float(cpu_s), 1),
                rss_mb=round(int(rss_s) / 1024.0, 1),
                uid=int(uid_s) if uid_s.isdigit() else -1,
                state=_normalize_state(state_s),
            ))
        except (ValueError, TypeError):
            continue
        if limit is not None and len(rows) >= limit:
            break
    return rows


# Default size of each ranked slice (top-N-by-CPU and top-N-by-mem) unioned
# into the Machine tab's process list. ~25 each so a memory sort is faithful
# (a real mem ranking, not just a re-sort of the top-CPU set) and the app's
# "Show more" reveals a meaningful set beyond its default top-10.
_PROCESS_UNION_N = 25


def build_process_list(
    r_stdout: str,
    m_stdout: str,
    *,
    current_uid: int,
    top_n: int = _PROCESS_UNION_N,
) -> list[ProcessInfo]:
    """Merge the CPU-sorted (`ps … -r`) and memory-sorted (`ps … -m`) process
    lists into ONE deduped table for the Machine tab (v1.38.1 B2), and
    force-include every same-UID *stopped* process (B1 vanishing-process fix).

    Why a union: a client-side "sort by memory" is only faithful if the helper
    actually returned the memory-heavy processes — top-CPU alone would miss a
    quiet-but-huge process. So we take top-`top_n`-by-CPU ∪ top-`top_n`-by-mem,
    deduped by pid.

    Why force-include stopped same-UID procs: a suspended process immediately
    drops to ~0% CPU and (unless it's memory-heavy) falls out of BOTH ranked
    slices on the next 2 s refresh — the row would vanish and the user could no
    longer Resume it. We scan the SAME full `-r` output (no extra `ps`) for
    same-UID rows in state 'stopped' and pin them in. A paused process therefore
    never drops off the list while stopped.

    Result is sorted CPU-desc so an OLD app (pre-B2, no client-side sort) still
    renders a sensible top-N-by-CPU from `.prefix(10)`.
    """
    cpu_rows = parse_top_processes(r_stdout, limit=None)   # full -r scan, CPU desc
    mem_rows = parse_top_processes(m_stdout, limit=top_n)  # top-N by memory
    seen: set[int] = set()
    union: list[ProcessInfo] = []

    def _add(p: ProcessInfo) -> None:
        if p.pid not in seen:
            seen.add(p.pid)
            union.append(p)

    for p in cpu_rows[:top_n]:      # top-N by CPU
        _add(p)
    for p in mem_rows:              # top-N by memory
        _add(p)
    for p in cpu_rows:              # force-union: every same-UID stopped proc
        if p.state == "stopped" and p.uid == current_uid:
            _add(p)

    union.sort(key=lambda p: p.cpu_percent, reverse=True)
    return union


def _as_int(value) -> Optional[int]:
    try:
        if isinstance(value, bool):
            return None
        return int(value)
    except (TypeError, ValueError):
        return None


def _as_float(value) -> Optional[float]:
    try:
        if isinstance(value, bool):
            return None
        return float(value)
    except (TypeError, ValueError):
        return None


def parse_ioreg_battery(plist_bytes: bytes) -> BatteryThermal:
    """Parse `ioreg -r -c AppleSmartBattery -a` (XML plist).

    Empty output (a desktop Mac with no battery node) or an unparseable blob
    yields has_battery=False. Health % = AppleRawMaxCapacity / DesignCapacity.
    Temperature is in units of 0.01 °C (3098 -> 30.98 °C). State is derived from
    the reliable ExternalConnected + IsCharging booleans (the messy pmset state
    word is only a fallback in the collector).
    """
    if not plist_bytes:
        return BatteryThermal(has_battery=False)
    try:
        data = plistlib.loads(plist_bytes)
    except Exception:  # noqa: BLE001 — malformed plist -> no battery
        return BatteryThermal(has_battery=False)

    node = None
    if isinstance(data, list) and data and isinstance(data[0], dict):
        node = data[0]
    elif isinstance(data, dict):
        node = data
    if not node:
        return BatteryThermal(has_battery=False)

    design = _as_int(node.get("DesignCapacity"))
    raw_max = _as_int(node.get("AppleRawMaxCapacity")) or _as_int(node.get("MaxCapacity"))
    cycle = _as_int(node.get("CycleCount"))
    temp_raw = _as_int(node.get("Temperature"))
    ext = bool(node.get("ExternalConnected"))
    charging = bool(node.get("IsCharging"))

    health = None
    if design and raw_max and design > 0:
        health = round(raw_max / design * 100.0, 1)

    battery_temp_c = None
    if temp_raw is not None and 0 < temp_raw < 20000:   # 0.01 °C units, sane window
        battery_temp_c = round(temp_raw / 100.0, 1)

    adapter = node.get("AdapterDetails")
    watts = _as_float(adapter.get("Watts")) if isinstance(adapter, dict) else None
    if not ext:
        adapter_watts: Optional[float] = 0.0     # on battery -> 0 W in
    elif watts and watts > 0:
        adapter_watts = watts
    else:
        adapter_watts = None                     # plugged but wattage unknown

    state = "discharging" if not ext else ("charging" if charging else "charged")

    return BatteryThermal(
        has_battery=True,
        state=state,
        cycle_count=cycle,
        health_pct=health,
        design_capacity=design,
        current_capacity=raw_max,
        battery_temp_c=battery_temp_c,
        adapter_watts=adapter_watts,
    )


def parse_pmset_charge(text: str) -> tuple[Optional[int], Optional[str]]:
    """Parse `pmset -g batt`: returns (charge_pct, state_word).

    e.g. " -InternalBattery-0 (id=...) 100%; charged; 0:00 remaining ...".
    state_word is normalized to the RPC enum, or None if absent/unrecognized.
    """
    charge = None
    m = re.search(r"(\d{1,3})%", text)
    if m:
        val = int(m.group(1))
        if 0 <= val <= 100:
            charge = val

    state = None
    low = text.lower()
    if "discharging" in low:
        state = "discharging"
    elif "charging" in low or "finishing charge" in low:
        state = "charging"
    elif "charged" in low:
        state = "charged"
    return charge, state


def parse_pmset_thermal(text: str) -> Optional[int]:
    """Map `pmset -g therm` to an NSProcessInfo.thermalState-style 0..3.

    Coarse but honest and root-free; S3's native module can refine to the exact
    ProcessInfo enum. A healthy Mac prints "No thermal warning level has been
    recorded" -> 0 (nominal). When throttling, `CPU_Speed_Limit` drops below 100.
    """
    low = text.lower()
    m = re.search(r"cpu_speed_limit\s*=?\s*(\d{1,3})", low)
    if m:
        limit = int(m.group(1))
        if limit >= 100:
            return 0
        if limit >= 75:
            return 1
        if limit >= 50:
            return 2
        return 3
    if "no thermal warning level has been recorded" in low:
        return 0
    # A recorded thermal warning without a speed-limit line → at least "fair".
    if "thermal" in low and "warning" in low:
        return 1
    return None


def parse_vm_stat_memory(vm_stat_out: str, total_bytes: int) -> tuple[int, int]:
    """Return (used_bytes, memory_percent) from `vm_stat` output + hw.memsize.

    "Used" = active + wired + compressor pages (matches system_collector's
    percent definition) so the byte figure and the percent agree.
    """
    page_size = 4096
    hm = re.search(r"page size of (\d+) bytes", vm_stat_out)
    if hm:
        page_size = int(hm.group(1))
    values: dict[str, int] = {}
    for line in vm_stat_out.splitlines():
        if ":" not in line:
            continue
        key, raw = line.split(":", 1)
        digits = re.sub(r"[^0-9]", "", raw)
        if digits:
            values[key.strip()] = int(digits)
    active_pages = (
        values.get("Pages active", 0)
        + values.get("Pages wired down", 0)
        + values.get("Pages occupied by compressor", 0)
    )
    used_bytes = active_pages * page_size
    if total_bytes <= 0:
        return used_bytes, 0
    pct = max(0, min(100, int(used_bytes / total_bytes * 100)))
    return used_bytes, pct


# ── collectors (shell out to CLI oracles; fail-soft) ────────────────


def _run(argv: list[str], *, timeout: float = 5.0, binary: bool = False):
    try:
        proc = subprocess.run(
            argv, capture_output=True, timeout=timeout,
            text=not binary,
        )
        if proc.returncode != 0:
            return None
        return proc.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as exc:
        logger.debug("%s failed: %s", argv[0], exc)
        return None


_PS_COLUMNS = "pid,uid,pcpu,rss,state,comm"


def collect_top_processes(limit: int = _PROCESS_UNION_N) -> list[ProcessInfo]:
    """Union of top-`limit`-by-CPU (`ps … -r`) and top-`limit`-by-mem
    (`ps … -m`), plus every same-UID stopped process (see `build_process_list`).
    Two cheap `ps` calls; returns [] only if BOTH fail."""
    r_out = _run(["ps", "-Aceo", _PS_COLUMNS, "-r"], timeout=10.0)
    m_out = _run(["ps", "-Aceo", _PS_COLUMNS, "-m"], timeout=10.0)
    if not r_out and not m_out:
        return []
    try:
        current_uid = os.getuid()
    except (AttributeError, OSError):   # non-POSIX / restricted — no same-UID pin
        current_uid = -1
    return build_process_list(r_out or "", m_out or "",
                              current_uid=current_uid, top_n=limit)


def collect_battery_thermal() -> BatteryThermal:
    # Battery health / capacity / temp / adapter from AppleSmartBattery IORegistry.
    ioreg_out = _run(["ioreg", "-r", "-c", "AppleSmartBattery", "-a"], binary=True)
    bt = parse_ioreg_battery(ioreg_out or b"")

    # Charge % (+ fallback state) from Power-Sources-backed pmset.
    pmset_out = _run(["pmset", "-g", "batt"])
    if pmset_out:
        charge, pmset_state = parse_pmset_charge(pmset_out)
        if charge is not None:
            bt.charge_pct = charge
            if not bt.has_battery:
                bt.has_battery = True   # pmset saw a battery ioreg didn't parse
        if bt.state is None and pmset_state:
            bt.state = pmset_state

    # System thermal pressure.
    therm_out = _run(["pmset", "-g", "therm"])
    if therm_out is not None:
        bt.thermal_state = parse_pmset_thermal(therm_out)
    return bt


def collect_memory() -> tuple[int, int, int]:
    """Return (memory_percent, used_bytes, total_bytes)."""
    total = 0
    try:
        out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True,
                             text=True, timeout=5)
        if out.returncode == 0 and out.stdout.strip().isdigit():
            total = int(out.stdout.strip())
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        total = 0
    vm_out = _run(["vm_stat"])
    if not vm_out:
        return 0, 0, total
    used_bytes, pct = parse_vm_stat_memory(vm_out, total)
    return pct, used_bytes, total


def collect_cpu_percent() -> int:
    """Coarse load-average-based CPU% (same definition as system_collector)."""
    try:
        cpu_count = max(os.cpu_count() or 1, 1)
        load = os.getloadavg()[0]
        return max(0, min(100, int(load / cpu_count * 100)))
    except (OSError, AttributeError):
        return 0


def build_capability(battery: BatteryThermal, sensors: Optional[dict]) -> dict[str, bool]:
    """Honest per-device "what can this Mac report" map. Phones render off this
    so a desktop shows no battery card and a fanless Air shows no fan gauge."""
    cap = {
        "process_table": True,
        "battery": bool(battery.has_battery),
        "thermal_state": battery.thermal_state is not None,
        # S3 native sensors — false until the module reports them.
        "temps": False,
        "fans": False,
        "power": False,
    }
    if isinstance(sensors, dict):
        caps_from_sensors = sensors.get("capability")
        if isinstance(caps_from_sensors, dict):
            for k, v in caps_from_sensors.items():
                if isinstance(v, bool):
                    cap[k] = v
    return cap


def local_control_capability() -> dict[str, bool]:
    """LOCAL-ONLY control capabilities — advertised in the UDS snapshot but
    deliberately NOT merged into `build_capability` (which feeds the compact
    heartbeat synced to `devices`).

    M1: the unsandboxed user LaunchAgent can always kill(2) its own same-UID
    processes, so `kill_process` is true here. v1.38.1 adds `suspend_process`
    (SIGSTOP/SIGCONT — the same same-UID, no-root privilege posture). Both are
    meaningless in the cloud / mobile view (you can't signal a process
    remotely), so they stay out of the synced blob. A key is absent on older
    helpers, so a new Mac app talking to an old helper naturally sees no
    capability and hides the affordance. The app ADDITIONALLY gates on
    #if DEVID_BUILD + a Settings toggle + a same-UID row + an inline confirm.
    """
    return {"kill_process": True, "suspend_process": True}


def collect_machine_snapshot(limit: int = _PROCESS_UNION_N,
                             sensors: Optional[dict] = None) -> MachineSnapshot:
    """Full LOCAL snapshot for the UDS `get_machine_snapshot` method."""
    battery = collect_battery_thermal()
    mem_pct, used_bytes, total_bytes = collect_memory()
    capability = build_capability(battery, sensors)
    capability.update(local_control_capability())   # local-only controls (M1)
    return MachineSnapshot(
        collected_at=datetime.now(timezone.utc).isoformat(),
        cpu_percent=collect_cpu_percent(),
        memory_percent=mem_pct,
        memory_used_bytes=used_bytes,
        memory_total_bytes=total_bytes,
        battery=battery,
        top_processes=collect_top_processes(limit=limit),
        capability=capability,
        sensors=sensors,
    )


def machine_snapshot_dict(snap: MachineSnapshot) -> dict:
    """JSON-serializable dict for the UDS reply."""
    b = snap.battery
    return {
        "collected_at": snap.collected_at,
        "cpu_percent": snap.cpu_percent,
        "memory_percent": snap.memory_percent,
        "memory_used_bytes": snap.memory_used_bytes,
        "memory_total_bytes": snap.memory_total_bytes,
        "battery": {
            "has_battery": b.has_battery,
            "charge_pct": b.charge_pct,
            "state": b.state,
            "cycle_count": b.cycle_count,
            "health_pct": b.health_pct,
            "design_capacity": b.design_capacity,
            "current_capacity": b.current_capacity,
            "battery_temp_c": b.battery_temp_c,
            "adapter_watts": b.adapter_watts,
            "thermal_state": b.thermal_state,
        },
        "top_processes": [
            {"pid": p.pid, "name": p.name, "cpu_percent": p.cpu_percent,
             "rss_mb": p.rss_mb, "uid": p.uid, "state": p.state}
            for p in snap.top_processes
        ],
        "capability": snap.capability,
        "sensors": snap.sensors,
    }


def heartbeat_metrics(sensors: Optional[dict] = None) -> Optional[dict]:
    """Compact `p_metrics` blob for helper_heartbeat (synced to `devices`).

    Battery + thermal + capability (+ S3 native sensors when supplied). NEVER
    includes the per-process table. Omits None values so the RPC's per-field
    coalesce preserves last-known for anything we couldn't read this cycle.
    Returns None only if literally nothing could be collected (so the daemon
    omits p_metrics entirely and the server preserves everything).
    """
    try:
        battery = collect_battery_thermal()
    except Exception as exc:  # noqa: BLE001 — must never break the heartbeat
        logger.debug("collect_battery_thermal failed: %s", exc)
        battery = BatteryThermal()

    metrics: dict = {}
    if battery.state in _BATTERY_STATES:
        metrics["battery_state"] = battery.state
    for key, val in (
        ("battery_charge_pct", battery.charge_pct),
        ("battery_cycle_count", battery.cycle_count),
        ("battery_health_pct", battery.health_pct),
        ("battery_design_capacity", battery.design_capacity),
        ("battery_current_capacity", battery.current_capacity),
        ("battery_temp_c", battery.battery_temp_c),
        ("adapter_watts", battery.adapter_watts),
        ("thermal_state", battery.thermal_state),
    ):
        if val is not None:
            metrics[key] = val

    # S3: merge native sensor readings (die temps, fans, power) into the blob.
    if isinstance(sensors, dict):
        for key, val in sensors.items():
            if key == "capability":
                continue
            if val is not None:
                metrics[key] = val

    metrics["capability"] = build_capability(battery, sensors)

    # Always at least a capability map + (usually) thermal_state -> return it.
    return metrics or None
