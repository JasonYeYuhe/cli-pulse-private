"""Bridge to the native `clipulse-sensors` Swift binary (System Monitor S3).

Locates + invokes the unsandboxed sensor reader, parses its one-shot JSON, and
returns a validated `sensors` dict (die temps / fan RPM / CPU-GPU-ANE power +
a capability map) for machine_collector to merge into the heartbeat metrics and
the local UDS snapshot.

Fail-soft by design: if the binary is missing (fanless/older install, sandboxed
build, dev tree without a build) or errors, read_sensors() returns None and the
machine monitor gracefully degrades to the S2 feature set (temps/fans/power
capability stay false). No native sensor code ever runs in-process here — it's a
separate signed binary, so the sandbox story is unchanged.
"""
from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional

logger = logging.getLogger("cli_pulse.sensor_bridge")

_BINARY_NAME = "clipulse-sensors"

# Numeric metric keys the binary may emit; everything else is ignored so a future
# binary can't smuggle arbitrary keys into the heartbeat payload.
_NUMERIC_KEYS = frozenset({
    "cpu_power_w", "gpu_power_w", "ane_power_w", "system_power_w",
    "cpu_temp_c", "gpu_temp_c", "fan_rpm", "fan_max_rpm",
})


def _candidate_paths() -> list[Path]:
    """Where the sensor binary might live, most-specific first."""
    paths: list[Path] = []
    env = os.environ.get("CLIPULSE_SENSORS_BIN")
    if env:
        paths.append(Path(env))
    # Next to the running helper — the .pkg installs the binary here
    # (~/Library/CLI-Pulse-Helper/clipulse-sensors alongside cli_pulse_helper).
    try:
        paths.append(Path(sys.argv[0]).resolve().parent / _BINARY_NAME)
    except Exception:  # noqa: BLE001
        pass
    here = Path(__file__).resolve().parent
    paths.append(here / _BINARY_NAME)
    # Dev-tree build outputs (running from source, not the frozen .pkg).
    repo = here.parent
    for rel in (
        Path("SensorProbe") / ".build" / "release" / _BINARY_NAME,
        Path("SensorProbe") / ".build" / "arm64-apple-macosx" / "release" / _BINARY_NAME,
    ):
        paths.append(repo / rel)
    return paths


def find_binary() -> Optional[Path]:
    for p in _candidate_paths():
        try:
            if p.is_file() and os.access(p, os.X_OK):
                return p
        except OSError:
            continue
    return None


def parse_output(text: str) -> Optional[dict]:
    """Validate + normalize the binary's JSON. Pure; unit-tested."""
    try:
        data = json.loads(text)
    except (ValueError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    out: dict = {}
    for k in _NUMERIC_KEYS:
        v = data.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[k] = v
    cap = data.get("capability")
    if isinstance(cap, dict):
        clean = {k: v for k, v in cap.items() if isinstance(v, bool)}
        if clean:
            out["capability"] = clean
    return out or None


def read_sensors(timeout: float = 4.0, sample_ms: int = 300) -> Optional[dict]:
    """Invoke the sensor binary and return the validated sensors dict, or None."""
    binary = find_binary()
    if binary is None:
        return None
    try:
        proc = subprocess.run(
            [str(binary), "--sample-ms", str(sample_ms)],
            capture_output=True, text=True, timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        logger.debug("clipulse-sensors invocation failed: %s", exc)
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    return parse_output(proc.stdout)
