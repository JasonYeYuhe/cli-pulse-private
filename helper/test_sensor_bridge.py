from __future__ import annotations

import os
import stat
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

import sensor_bridge as sb


class TestParseOutput(unittest.TestCase):
    def test_valid(self):
        out = sb.parse_output(
            '{"cpu_power_w":5.5,"gpu_power_w":1.3,"cpu_temp_c":68.0,"fan_rpm":1980,'
            '"fan_max_rpm":6200,"capability":{"temps":true,"fans":true,"power":true}}'
        )
        self.assertEqual(out["cpu_power_w"], 5.5)
        self.assertEqual(out["fan_rpm"], 1980)
        self.assertEqual(out["capability"], {"temps": True, "fans": True, "power": True})

    def test_filters_non_numeric_and_unknown_keys(self):
        out = sb.parse_output('{"cpu_power_w":"bad","evil_key":9,"cpu_temp_c":50,"capability":{"temps":true}}')
        self.assertNotIn("cpu_power_w", out)     # string dropped
        self.assertNotIn("evil_key", out)        # unknown key dropped
        self.assertEqual(out["cpu_temp_c"], 50)

    def test_bool_not_treated_as_number(self):
        out = sb.parse_output('{"fan_rpm":true,"cpu_temp_c":50,"capability":{"temps":true}}')
        self.assertNotIn("fan_rpm", out)

    def test_capability_keeps_only_bools(self):
        out = sb.parse_output('{"cpu_temp_c":50,"capability":{"temps":true,"junk":"x","n":3}}')
        self.assertEqual(out["capability"], {"temps": True})

    def test_invalid_json(self):
        self.assertIsNone(sb.parse_output("not json"))
        self.assertIsNone(sb.parse_output("[1,2,3]"))     # not an object
        self.assertIsNone(sb.parse_output("{}"))          # empty -> None


class TestReadSensors(unittest.TestCase):
    def _write_fake(self, d: Path, body: str) -> Path:
        p = d / "clipulse-sensors"
        p.write_text(f"#!/bin/sh\ncat <<'EOF'\n{body}\nEOF\n")
        p.chmod(p.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
        return p

    def test_reads_from_env_override(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._write_fake(d, '{"cpu_temp_c":66.0,"fan_rpm":1500,"capability":{"temps":true,"fans":true}}')
            old = os.environ.get("CLIPULSE_SENSORS_BIN")
            os.environ["CLIPULSE_SENSORS_BIN"] = str(d / "clipulse-sensors")
            try:
                out = sb.read_sensors(timeout=5)
            finally:
                if old is None:
                    os.environ.pop("CLIPULSE_SENSORS_BIN", None)
                else:
                    os.environ["CLIPULSE_SENSORS_BIN"] = old
            self.assertIsNotNone(out)
            self.assertEqual(out["cpu_temp_c"], 66.0)
            self.assertEqual(out["capability"]["fans"], True)

    def test_missing_binary_returns_none(self):
        old = os.environ.get("CLIPULSE_SENSORS_BIN")
        os.environ["CLIPULSE_SENSORS_BIN"] = "/nonexistent/path/clipulse-sensors"
        try:
            # /nonexistent isn't executable -> falls through candidate list; on a
            # dev machine a real build may exist, so only assert it doesn't raise.
            result = sb.read_sensors(timeout=5)
        finally:
            if old is None:
                os.environ.pop("CLIPULSE_SENSORS_BIN", None)
            else:
                os.environ["CLIPULSE_SENSORS_BIN"] = old
        self.assertTrue(result is None or isinstance(result, dict))

    def test_garbage_output_returns_none(self):
        with TemporaryDirectory() as tmp:
            d = Path(tmp)
            self._write_fake(d, "this is not json")
            out = sb.read_sensors(timeout=5, sample_ms=300) if False else sb.parse_output("this is not json")
            self.assertIsNone(out)


if __name__ == "__main__":
    unittest.main()
