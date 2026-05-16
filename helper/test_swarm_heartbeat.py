"""Tests for S1b `_swarm_heartbeat` — the edge-aggregated upload."""

from __future__ import annotations

import sys
from pathlib import Path
from types import SimpleNamespace

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as cph  # noqa: E402
import swarm  # noqa: E402


def _cfg(enabled: bool):
    return SimpleNamespace(
        device_id="dev-1", helper_secret="acct-secret", swarm_enabled=enabled
    )


def _capture_rpc(monkeypatch):
    calls = []
    monkeypatch.setattr(
        cph, "supabase_rpc",
        lambda name, params, **kw: calls.append((name, params, kw)),
    )
    return calls


def test_disabled_gate_uploads_nothing(monkeypatch):
    calls = _capture_rpc(monkeypatch)
    # Even if there IS local state, a disabled gate must not POST.
    monkeypatch.setattr(
        swarm.SwarmStore, "rollup", lambda self: [{"swarm_key": "k"}]
    )
    cph._swarm_heartbeat(_cfg(False))
    assert calls == []


def test_enabled_but_empty_rollup_uploads_nothing(monkeypatch):
    calls = _capture_rpc(monkeypatch)
    monkeypatch.setattr(swarm.SwarmStore, "rollup", lambda self: [])
    cph._swarm_heartbeat(_cfg(True))
    assert calls == []


def test_enabled_with_rollup_posts_expected_shape(monkeypatch):
    calls = _capture_rpc(monkeypatch)
    rollup = [
        {"swarm_key": "k1", "handle": "swarm-k1", "agents": 3, "blocked": 1},
        {"swarm_key": "k2", "handle": "swarm-k2", "agents": 1, "blocked": 0},
    ]
    monkeypatch.setattr(swarm.SwarmStore, "rollup", lambda self: rollup)
    cph._swarm_heartbeat(_cfg(True))

    assert len(calls) == 1
    name, params, _ = calls[0]
    assert name == "remote_helper_swarm_heartbeat"
    assert params["p_device_id"] == "dev-1"
    assert params["p_helper_secret"] == "acct-secret"
    assert params["p_swarms"] == rollup
    # Heartbeat carries the rolled-up summary, NOT raw events (R1-A4).
    assert all("swarm_key" in s for s in params["p_swarms"])


def test_rpc_failure_is_soft(monkeypatch):
    """RK1: a missing RPC (S2 not yet deployed) or network error must
    NEVER raise out of the daemon cycle."""
    def boom(*a, **k):
        raise RuntimeError("function remote_helper_swarm_heartbeat does not exist")

    monkeypatch.setattr(cph, "supabase_rpc", boom)
    monkeypatch.setattr(
        swarm.SwarmStore, "rollup", lambda self: [{"swarm_key": "k"}]
    )
    # No exception escapes.
    cph._swarm_heartbeat(_cfg(True))


def test_store_read_failure_is_soft(monkeypatch):
    def boom(self):
        raise OSError("state file vanished")

    monkeypatch.setattr(swarm.SwarmStore, "rollup", boom)
    calls = _capture_rpc(monkeypatch)
    cph._swarm_heartbeat(_cfg(True))
    assert calls == []  # nothing posted, nothing raised
