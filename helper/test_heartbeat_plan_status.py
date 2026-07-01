"""v0.60: heartbeat() forwards provider_plan_status (on success) and omits it
(on compute failure, so the server's coalesce preserves the last-known value)."""

from __future__ import annotations

import argparse
import sys
import types
from pathlib import Path

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as h  # noqa: E402
import provider_spawners  # noqa: E402


def _capture(monkeypatch, plan_fn):
    monkeypatch.setattr(
        h, "load_config",
        lambda: types.SimpleNamespace(device_id="dev-1", helper_secret="sec"),
    )
    monkeypatch.setattr(
        h, "collect_device_snapshot",
        lambda: types.SimpleNamespace(cpu_usage=3, memory_usage=7),
    )
    monkeypatch.setattr(h, "collect_sessions", lambda: [])
    captured: dict = {}
    monkeypatch.setattr(
        h, "supabase_rpc",
        lambda name, params: captured.update({"name": name, "params": params}),
    )
    monkeypatch.setattr(provider_spawners, "provider_plan_statuses", plan_fn)
    return captured


def test_heartbeat_includes_plan_status_on_success(monkeypatch):
    captured = _capture(monkeypatch, lambda: {"codex": "off_plan", "gemini": "on_plan"})
    h.heartbeat(argparse.Namespace())
    assert captured["name"] == "helper_heartbeat"
    assert captured["params"]["p_provider_plan_status"] == {
        "codex": "off_plan", "gemini": "on_plan",
    }


def test_heartbeat_sends_empty_map_when_nothing_decisive(monkeypatch):
    # Reachable but no decisive statuses -> {} is authoritative (clears warning).
    captured = _capture(monkeypatch, dict)
    h.heartbeat(argparse.Namespace())
    assert captured["params"]["p_provider_plan_status"] == {}


def test_heartbeat_omits_plan_status_on_failure(monkeypatch):
    def boom():
        raise RuntimeError("compute failed")

    captured = _capture(monkeypatch, boom)
    h.heartbeat(argparse.Namespace())
    # Omitted -> server coalesce preserves last-known (never clobbers to {}).
    assert "p_provider_plan_status" not in captured["params"]
    # The rest of the heartbeat still went out.
    assert captured["params"]["p_device_id"] == "dev-1"
