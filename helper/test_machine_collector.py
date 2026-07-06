from __future__ import annotations

import plistlib
import unittest

import machine_collector as mc


class TestParseTopProcesses(unittest.TestCase):
    SAMPLE = (
        "  PID   UID  %CPU    RSS COMM\n"
        "  429     0  21.9  67512 WindowServer\n"
        "33608   501  39.7 648848 Google Chrome Helper (Renderer)\n"
        " 3942   501   5.8  29536 cli_pulse_helper\n"
    )

    def test_parses_and_ranks(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=10)
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0].pid, 429)
        self.assertEqual(rows[0].name, "WindowServer")
        self.assertAlmostEqual(rows[0].cpu_percent, 21.9)
        # RSS 67512 KiB -> ~65.9 MB
        self.assertAlmostEqual(rows[0].rss_mb, round(67512 / 1024.0, 1))

    def test_uid_column_parsed(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=10)
        self.assertEqual(rows[0].uid, 0)      # WindowServer runs as root
        self.assertEqual(rows[1].uid, 501)    # user-owned
        self.assertEqual(rows[2].uid, 501)

    def test_non_digit_uid_falls_back(self):
        sample = "  429     x  21.9  67512 WindowServer\n"
        rows = mc.parse_top_processes(sample, limit=10)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0].uid, -1)

    def test_comm_with_spaces_is_preserved(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=10)
        self.assertEqual(rows[1].name, "Google Chrome Helper (Renderer)")

    def test_header_row_skipped(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=10)
        self.assertTrue(all(r.name != "COMM" for r in rows))

    def test_limit_respected(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=1)
        self.assertEqual(len(rows), 1)

    def test_empty_and_malformed(self):
        self.assertEqual(mc.parse_top_processes("", limit=5), [])
        # Rows with fewer than 5 whitespace-separated fields are skipped.
        self.assertEqual(mc.parse_top_processes("garbage\nx y\n", limit=5), [])
        self.assertEqual(mc.parse_top_processes("1 2 3 4\n", limit=5), [])


class TestParseIoregBattery(unittest.TestCase):
    def _plist(self, node: dict) -> bytes:
        return plistlib.dumps([node])

    def test_laptop_battery(self):
        node = {
            "CycleCount": 59, "DesignCapacity": 8694,
            "AppleRawMaxCapacity": 8262, "AppleRawCurrentCapacity": 8262,
            "MaxCapacity": 100, "Temperature": 3098,
            "ExternalConnected": True, "IsCharging": False, "FullyCharged": True,
            "AdapterDetails": {"Watts": 65},
        }
        bt = mc.parse_ioreg_battery(self._plist(node))
        self.assertTrue(bt.has_battery)
        self.assertEqual(bt.cycle_count, 59)
        self.assertEqual(bt.design_capacity, 8694)
        self.assertEqual(bt.current_capacity, 8262)
        self.assertAlmostEqual(bt.health_pct, round(8262 / 8694 * 100, 1))
        self.assertAlmostEqual(bt.battery_temp_c, 30.98, places=1)  # 3098 / 100
        self.assertEqual(bt.adapter_watts, 65.0)
        self.assertEqual(bt.state, "charged")  # external + not charging

    def test_discharging_state_and_zero_adapter(self):
        node = {"CycleCount": 10, "DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
                "Temperature": 3000, "ExternalConnected": False, "IsCharging": False}
        bt = mc.parse_ioreg_battery(self._plist(node))
        self.assertEqual(bt.state, "discharging")
        self.assertEqual(bt.adapter_watts, 0.0)   # on battery -> 0 W in

    def test_charging_state(self):
        node = {"DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
                "ExternalConnected": True, "IsCharging": True, "AdapterDetails": {"Watts": 96}}
        bt = mc.parse_ioreg_battery(self._plist(node))
        self.assertEqual(bt.state, "charging")
        self.assertEqual(bt.adapter_watts, 96.0)

    def test_desktop_no_battery(self):
        # Empty output (Mac mini / Studio) -> no battery.
        bt = mc.parse_ioreg_battery(b"")
        self.assertFalse(bt.has_battery)
        self.assertIsNone(bt.health_pct)

    def test_malformed_plist(self):
        bt = mc.parse_ioreg_battery(b"not a plist")
        self.assertFalse(bt.has_battery)

    def test_absurd_temperature_dropped(self):
        node = {"DesignCapacity": 5000, "AppleRawMaxCapacity": 4800,
                "Temperature": 99999, "ExternalConnected": True, "IsCharging": False}
        bt = mc.parse_ioreg_battery(self._plist(node))
        self.assertIsNone(bt.battery_temp_c)  # out of sane window -> None


class TestParsePmset(unittest.TestCase):
    def test_charge_and_state_charged(self):
        text = ("Now drawing from 'AC Power'\n"
                " -InternalBattery-0 (id=24182883)\t100%; charged; 0:00 remaining present: true\n")
        charge, state = mc.parse_pmset_charge(text)
        self.assertEqual(charge, 100)
        self.assertEqual(state, "charged")

    def test_charge_and_state_discharging(self):
        text = (" -InternalBattery-0 (id=1)\t72%; discharging; 3:15 remaining present: true\n")
        charge, state = mc.parse_pmset_charge(text)
        self.assertEqual(charge, 72)
        self.assertEqual(state, "discharging")

    def test_thermal_nominal(self):
        text = ("Note: No thermal warning level has been recorded\n"
                "Note: No performance warning level has been recorded\n")
        self.assertEqual(mc.parse_pmset_thermal(text), 0)

    def test_thermal_throttling_levels(self):
        self.assertEqual(mc.parse_pmset_thermal("CPU_Speed_Limit = 100"), 0)
        self.assertEqual(mc.parse_pmset_thermal("CPU_Speed_Limit = 80"), 1)
        self.assertEqual(mc.parse_pmset_thermal("CPU_Speed_Limit = 60"), 2)
        self.assertEqual(mc.parse_pmset_thermal("CPU_Speed_Limit = 30"), 3)

    def test_thermal_unknown(self):
        self.assertIsNone(mc.parse_pmset_thermal("something unrelated"))


class TestParseVmStatMemory(unittest.TestCase):
    SAMPLE = (
        "Mach Virtual Memory Statistics: (page size of 16384 bytes)\n"
        "Pages free:                          10000.\n"
        "Pages active:                        20000.\n"
        "Pages inactive:                      15000.\n"
        "Pages wired down:                    30000.\n"
        "Pages occupied by compressor:        5000.\n"
    )

    def test_used_and_percent(self):
        total = 17_179_869_184
        used, pct = mc.parse_vm_stat_memory(self.SAMPLE, total)
        # active + wired + compressor = 55000 pages * 16384
        self.assertEqual(used, 55000 * 16384)
        self.assertEqual(pct, int(used / total * 100))

    def test_zero_total_safe(self):
        used, pct = mc.parse_vm_stat_memory(self.SAMPLE, 0)
        self.assertEqual(pct, 0)


class TestBuildCapability(unittest.TestCase):
    def test_battery_present(self):
        bt = mc.BatteryThermal(has_battery=True, thermal_state=0)
        cap = mc.build_capability(bt, None)
        self.assertTrue(cap["process_table"])
        self.assertTrue(cap["battery"])
        self.assertTrue(cap["thermal_state"])
        self.assertFalse(cap["temps"])  # S3
        self.assertFalse(cap["fans"])
        self.assertFalse(cap["power"])

    def test_build_capability_excludes_kill_process(self):
        # M1: kill_process is a LOCAL-only control capability. It must NOT be in
        # build_capability, because build_capability feeds the compact heartbeat
        # synced to `devices` and a "can kill" flag is meaningless remotely.
        bt = mc.BatteryThermal(has_battery=False, thermal_state=None)
        cap = mc.build_capability(bt, None)
        self.assertNotIn("kill_process", cap)

    def test_local_control_capability_has_kill(self):
        self.assertTrue(mc.local_control_capability()["kill_process"])

    def test_desktop_no_battery(self):
        bt = mc.BatteryThermal(has_battery=False, thermal_state=None)
        cap = mc.build_capability(bt, None)
        self.assertFalse(cap["battery"])
        self.assertFalse(cap["thermal_state"])

    def test_sensors_flip_flags(self):
        bt = mc.BatteryThermal(has_battery=True, thermal_state=0)
        sensors = {"capability": {"temps": True, "fans": True, "power": True}}
        cap = mc.build_capability(bt, sensors)
        self.assertTrue(cap["temps"])
        self.assertTrue(cap["fans"])
        self.assertTrue(cap["power"])


class TestMachineSnapshotDict(unittest.TestCase):
    def test_top_processes_include_uid(self):
        snap = mc.MachineSnapshot(
            collected_at="2026-07-06T00:00:00+00:00",
            cpu_percent=10, memory_percent=50,
            memory_used_bytes=1, memory_total_bytes=2,
            battery=mc.BatteryThermal(has_battery=False),
            top_processes=[mc.ProcessInfo(pid=42, name="foo", cpu_percent=1.0,
                                          rss_mb=2.0, uid=501)],
            capability={**mc.build_capability(mc.BatteryThermal(), None),
                        **mc.local_control_capability()},
        )
        d = mc.machine_snapshot_dict(snap)
        self.assertEqual(d["top_processes"][0]["uid"], 501)
        self.assertTrue(d["capability"]["kill_process"])

    def test_collect_machine_snapshot_advertises_kill_locally(self):
        # The real local snapshot (shells out to ps/ioreg/etc. on macOS) carries
        # the local-only kill_process capability that build_capability omits.
        snap = mc.collect_machine_snapshot(limit=1)
        self.assertTrue(snap.capability.get("kill_process"))


class TestHeartbeatMetrics(unittest.TestCase):
    def _patch_battery(self, bt: mc.BatteryThermal):
        mc.collect_battery_thermal = lambda: bt  # type: ignore[assignment]

    def setUp(self):
        self._orig = mc.collect_battery_thermal

    def tearDown(self):
        mc.collect_battery_thermal = self._orig  # type: ignore[assignment]

    def test_omits_none_values(self):
        self._patch_battery(mc.BatteryThermal(
            has_battery=True, charge_pct=100, state="charged", cycle_count=59,
            health_pct=95.0, design_capacity=8694, current_capacity=8262,
            battery_temp_c=31.0, adapter_watts=65.0, thermal_state=0))
        m = mc.heartbeat_metrics()
        self.assertEqual(m["battery_state"], "charged")
        self.assertEqual(m["battery_cycle_count"], 59)
        self.assertEqual(m["thermal_state"], 0)
        self.assertIn("capability", m)
        # No per-process rows ever synced.
        self.assertNotIn("top_processes", m)
        # M1: the local-only kill_process capability must never reach the cloud.
        self.assertNotIn("kill_process", m["capability"])

    def test_desktop_no_battery_still_returns_capability(self):
        self._patch_battery(mc.BatteryThermal(has_battery=False, thermal_state=0))
        m = mc.heartbeat_metrics()
        self.assertIsNotNone(m)
        self.assertFalse(m["capability"]["battery"])
        self.assertEqual(m["thermal_state"], 0)
        # Battery fields absent (None omitted).
        self.assertNotIn("battery_cycle_count", m)

    def test_invalid_battery_state_omitted(self):
        self._patch_battery(mc.BatteryThermal(has_battery=True, state="weird", thermal_state=0))
        m = mc.heartbeat_metrics()
        self.assertNotIn("battery_state", m)

    def test_sensors_merged(self):
        self._patch_battery(mc.BatteryThermal(has_battery=True, thermal_state=0))
        sensors = {"cpu_power_w": 12.5, "cpu_temp_c": 55.0, "fan_rpm": 1980,
                   "capability": {"temps": True, "fans": True, "power": True}}
        m = mc.heartbeat_metrics(sensors=sensors)
        self.assertEqual(m["cpu_power_w"], 12.5)
        self.assertEqual(m["fan_rpm"], 1980)
        self.assertTrue(m["capability"]["temps"])


if __name__ == "__main__":
    unittest.main()
