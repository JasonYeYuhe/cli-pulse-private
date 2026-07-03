"""R0 (2026-07-03 deep review) — the one-time broadcast-gate flip migration.

helper ≤1.23.0 persisted its then-default `remote_realtime_broadcast_enabled=
False` into ~/.cli-pulse-helper.json on ANY save_config (pair / Local Control
toggle) — an incidental value, never a user decision. Without migration, that
explicit False silently defeats the helper 1.24.0 default-ON fleet flip for
exactly the cohort that used the terminal. load_config() strips the stale key
ONCE and stamps `r0_flip_migrated`; every EXPLICIT post-migration False (the
documented ops kill switch) is honored forever after.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

import cli_pulse_helper as helper  # noqa: E402


@pytest.fixture
def tmp_config(tmp_path, monkeypatch):
    """Redirect helper.CONFIG_PATH at a tmp file so we never touch the user's
    real ~/.cli-pulse-helper.json."""
    target = tmp_path / "helper.json"
    monkeypatch.setattr(helper, "CONFIG_PATH", target)
    return target


def _write(path: Path, **overrides):
    base = {
        "device_id": "dev-1",
        "user_id": "user-1",
        "device_name": "Test Mac",
        "helper_version": "1.23.0",
        "helper_secret": "abc123",
    }
    base.update(overrides)
    path.write_text(json.dumps(base))


def test_stale_1_23_false_is_migrated_to_default_on(tmp_config):
    # The exact on-disk shape a 1.23.0 pair/save left behind: explicit false,
    # no marker. Must load True (the 1.24.0 default) — the flip applies.
    _write(tmp_config, remote_realtime_broadcast_enabled=False)
    cfg = helper.load_config()
    assert cfg.remote_realtime_broadcast_enabled is True
    assert cfg.r0_flip_migrated is True


def test_migration_is_persisted_so_it_runs_once(tmp_config):
    _write(tmp_config, remote_realtime_broadcast_enabled=False)
    helper.load_config()
    on_disk = json.loads(tmp_config.read_text())
    # Marker stamped + stale key stripped, atomically, at first load.
    assert on_disk["r0_flip_migrated"] is True
    assert "remote_realtime_broadcast_enabled" not in on_disk


def test_post_migration_explicit_false_is_honored_kill_switch(tmp_config):
    # The documented ops kill switch: an explicit False written AFTER the
    # migration (marker present) must be respected — never re-flipped.
    _write(
        tmp_config,
        remote_realtime_broadcast_enabled=False,
        r0_flip_migrated=True,
    )
    cfg = helper.load_config()
    assert cfg.remote_realtime_broadcast_enabled is False
    # And it survives repeated loads (no rewrite happens).
    cfg2 = helper.load_config()
    assert cfg2.remote_realtime_broadcast_enabled is False


def test_absent_key_no_marker_loads_default_on_and_stamps(tmp_config):
    # Pre-1.23 config (key never persisted): default ON + marker stamped.
    _write(tmp_config)
    cfg = helper.load_config()
    assert cfg.remote_realtime_broadcast_enabled is True
    assert json.loads(tmp_config.read_text())["r0_flip_migrated"] is True


def test_save_config_round_trips_marker_and_gate(tmp_config):
    # A fresh 1.24.0 save persists marker=True; a subsequent load respects an
    # ops flip to False (save → hand-edit → load).
    _write(tmp_config)
    cfg = helper.load_config()
    helper.save_config(cfg)
    on_disk = json.loads(tmp_config.read_text())
    assert on_disk["r0_flip_migrated"] is True
    assert on_disk["remote_realtime_broadcast_enabled"] is True
    on_disk["remote_realtime_broadcast_enabled"] = False  # ops kill switch
    tmp_config.write_text(json.dumps(on_disk))
    assert helper.load_config().remote_realtime_broadcast_enabled is False


def test_1_23_stale_true_survives_migration(tmp_config):
    # The owner's test Mac hand-set True on 1.23.0 (the flag's only documented
    # use pre-flip). Migration strips the key → default True → same outcome.
    _write(tmp_config, remote_realtime_broadcast_enabled=True)
    cfg = helper.load_config()
    assert cfg.remote_realtime_broadcast_enabled is True
