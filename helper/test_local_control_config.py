"""Tests for the helper config gate `local_control_enabled`.

Covers:
  - an old on-disk config without the `local_control_enabled` key
    loads with the field defaulted to False (backward compat: opt-out
    is the privacy default)
  - set_local_control_enabled flips the value and persists it
  - a fresh save round-trips the new key back through load()
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
    """Redirect helper.CONFIG_PATH at a tmp file so we never touch
    the user's real ~/.cli-pulse-helper.json.
    """
    target = tmp_path / "helper.json"
    monkeypatch.setattr(helper, "CONFIG_PATH", target)
    return target


def _write_legacy(path: Path, **overrides):
    base = {
        "device_id": "dev-1",
        "user_id": "user-1",
        "device_name": "Test Mac",
        "helper_version": "1.0.0",
        "helper_secret": "abc123",
    }
    base.update(overrides)
    path.write_text(json.dumps(base))


def test_legacy_config_without_key_loads_with_default_false(tmp_config):
    _write_legacy(tmp_config)
    cfg = helper.load_config()
    assert cfg.local_control_enabled is False


def test_set_local_control_enabled_persists_true_then_false(tmp_config):
    _write_legacy(tmp_config)
    assert helper.set_local_control_enabled(True) is True
    cfg_after = helper.load_config()
    assert cfg_after.local_control_enabled is True

    assert helper.set_local_control_enabled(False) is False
    cfg_after2 = helper.load_config()
    assert cfg_after2.local_control_enabled is False


def test_save_round_trips_local_control_enabled_key(tmp_config):
    _write_legacy(tmp_config, local_control_enabled=True)
    cfg = helper.load_config()
    assert cfg.local_control_enabled is True

    cfg.local_control_enabled = False
    helper.save_config(cfg)
    raw = json.loads(tmp_config.read_text())
    assert raw["local_control_enabled"] is False
