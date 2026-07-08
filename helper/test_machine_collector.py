from __future__ import annotations

import plistlib
import unittest

import machine_collector as mc


class TestParseTopProcesses(unittest.TestCase):
    # v1.38.1: six columns now — `state` (BSD STAT) sits before `comm`.
    SAMPLE = (
        "  PID   UID  %CPU    RSS STAT COMM\n"
        "  429     0  21.9  67512 Ss   WindowServer\n"
        "33608   501  39.7 648848 S    Google Chrome Helper (Renderer)\n"
        " 3942   501   5.8  29536 S    cli_pulse_helper\n"
        "  555   501   0.0   1376 T    paused_zsh\n"
        "  777   501   0.0      0 Z    defunct_proc\n"
    )

    def test_parses_and_ranks(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=10)
        self.assertEqual(len(rows), 5)
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

    def test_state_column_normalized(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=10)
        by_pid = {r.pid: r for r in rows}
        self.assertEqual(by_pid[429].state, "running")   # "Ss" → running
        self.assertEqual(by_pid[33608].state, "running") # "S"  → running
        self.assertEqual(by_pid[555].state, "stopped")   # "T"  → stopped
        self.assertEqual(by_pid[777].state, "other")     # "Z"  → other (zombie)

    def test_state_helper_direct(self):
        self.assertEqual(mc._normalize_state("T"), "stopped")
        self.assertEqual(mc._normalize_state("TN"), "stopped")   # first char wins
        self.assertEqual(mc._normalize_state("Z"), "other")
        self.assertEqual(mc._normalize_state("R"), "running")
        self.assertEqual(mc._normalize_state("S+"), "running")
        self.assertEqual(mc._normalize_state(""), "running")     # empty → safe default

    def test_non_digit_uid_falls_back(self):
        sample = "  429     x  21.9  67512 S    WindowServer\n"
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

    def test_limit_none_returns_all(self):
        rows = mc.parse_top_processes(self.SAMPLE, limit=None)
        self.assertEqual(len(rows), 5)

    def test_empty_and_malformed(self):
        self.assertEqual(mc.parse_top_processes("", limit=5), [])
        # Rows with fewer than 6 whitespace-separated fields are skipped.
        self.assertEqual(mc.parse_top_processes("garbage\nx y\n", limit=5), [])
        self.assertEqual(mc.parse_top_processes("1 2 3 4\n", limit=5), [])
        self.assertEqual(mc.parse_top_processes("1 2 3 4 5\n", limit=5), [])  # 5 fields still short


class TestBuildProcessList(unittest.TestCase):
    """The union of top-N-by-CPU (`-r`) and top-N-by-mem (`-m`), plus the
    force-inclusion of every same-UID stopped process (vanishing-process fix)."""

    R = (
        "  PID   UID  %CPU    RSS STAT COMM\n"
        "  100   501  90.0   1000 R    hot\n"
        "  200   501  10.0   2000 S    mid\n"
        "  300   501   0.0    500 S    idle\n"
        "  400   501   0.0   9000 S    bigmem\n"       # memory-heavy, low CPU
        "  500   501   0.0    128 T    paused_mine\n"  # stopped, same-uid, tiny → vanishing risk
        "  600     0   0.0    128 T    paused_root\n"  # stopped, OTHER uid → NOT force-pinned
    )
    # -m is the SAME set re-sorted by memory (bigmem first).
    M = (
        "  PID   UID  %CPU    RSS STAT COMM\n"
        "  400   501   0.0   9000 S    bigmem\n"
        "  200   501  10.0   2000 S    mid\n"
        "  100   501  90.0   1000 R    hot\n"
        "  300   501   0.0    500 S    idle\n"
        "  500   501   0.0    128 T    paused_mine\n"
        "  600     0   0.0    128 T    paused_root\n"
    )

    def test_union_dedupes_and_covers_both_ranks(self):
        # top_n=2: CPU top-2 = {100, 200}; mem top-2 = {400, 200}. Union covers
        # the memory-heavy 400 that a CPU-only list would miss, deduped (200 once).
        rows = mc.build_process_list(self.R, self.M, current_uid=501, top_n=2)
        pids = [r.pid for r in rows]
        self.assertIn(100, pids)
        self.assertIn(200, pids)
        self.assertIn(400, pids)         # memory-heavy, absent from CPU top-2
        self.assertEqual(len(pids), len(set(pids)))  # deduped

    def test_vanishing_stopped_same_uid_always_included(self):
        # pid 500 is stopped, same-uid, and NOT in top-2-by-CPU nor top-2-by-mem
        # — the exact vanishing case. It MUST still appear so the user can resume.
        rows = mc.build_process_list(self.R, self.M, current_uid=501, top_n=2)
        p500 = next((r for r in rows if r.pid == 500), None)
        self.assertIsNotNone(p500, "stopped same-uid proc must not vanish")
        self.assertEqual(p500.state, "stopped")

    def test_stopped_other_uid_not_force_included(self):
        # A root-owned stopped process the user can't resume is NOT pinned in
        # (only same-uid stopped procs are force-unioned).
        rows = mc.build_process_list(self.R, self.M, current_uid=501, top_n=2)
        self.assertNotIn(600, [r.pid for r in rows])

    def test_result_sorted_cpu_desc(self):
        # CPU-desc so an OLD (pre-sort) client still shows a sensible top-N.
        rows = mc.build_process_list(self.R, self.M, current_uid=501, top_n=6)
        cpus = [r.cpu_percent for r in rows]
        self.assertEqual(cpus, sorted(cpus, reverse=True))

    def test_empty_inputs(self):
        self.assertEqual(mc.build_process_list("", "", current_uid=501), [])


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

    def test_local_control_capability_has_suspend(self):
        # v1.38.1: suspend_process is the second LOCAL-only control capability.
        self.assertTrue(mc.local_control_capability()["suspend_process"])

    def test_build_capability_excludes_suspend_process(self):
        # Like kill_process, suspend_process must NOT reach the synced heartbeat.
        cap = mc.build_capability(mc.BatteryThermal(has_battery=False), None)
        self.assertNotIn("suspend_process", cap)

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
                                          rss_mb=2.0, uid=501, state="stopped")],
            capability={**mc.build_capability(mc.BatteryThermal(), None),
                        **mc.local_control_capability()},
        )
        d = mc.machine_snapshot_dict(snap)
        self.assertEqual(d["top_processes"][0]["uid"], 501)
        # v1.38.1: the per-process state ships in the LOCAL snapshot rows.
        self.assertEqual(d["top_processes"][0]["state"], "stopped")
        self.assertTrue(d["capability"]["kill_process"])
        self.assertTrue(d["capability"]["suspend_process"])

    def test_collect_machine_snapshot_advertises_kill_locally(self):
        # The real local snapshot (shells out to ps/ioreg/etc. on macOS) carries
        # the local-only kill_process capability that build_capability omits.
        snap = mc.collect_machine_snapshot(limit=1)
        self.assertTrue(snap.capability.get("kill_process"))


class TestSystemExtraMetrics(unittest.TestCase):
    def test_parse_swapusage(self):
        used, total = mc.parse_swapusage("total = 3072.00M  used = 2285.50M  free = 786.50M  (encrypted)")
        self.assertEqual(total, int(3072.0 * 1024 ** 2))
        self.assertEqual(used, int(2285.5 * 1024 ** 2))

    def test_parse_swapusage_gigabytes_and_missing(self):
        used, total = mc.parse_swapusage("total = 2.00G  used = 0.50G  free = 1.50G")
        self.assertEqual(total, 2 * 1024 ** 3)
        self.assertEqual(used, int(0.5 * 1024 ** 3))
        self.assertEqual(mc.parse_swapusage("garbage"), (None, None))

    def test_parse_boottime(self):
        self.assertEqual(mc.parse_boottime_sec("{ sec = 1782641564, usec = 405122 } Sun Jun 28"), 1782641564)
        self.assertIsNone(mc.parse_boottime_sec("no numbers here"))

    def test_parse_lpm(self):
        self.assertIs(mc.parse_lpm(" lowpowermode         1"), True)
        self.assertIs(mc.parse_lpm("hibernatemode 0\n lowpowermode 0"), False)
        self.assertIsNone(mc.parse_lpm("no such setting here"))

    def test_memory_pressure_levels(self):
        self.assertEqual(mc.memory_pressure_level(40, 0, 3000), "nominal")
        self.assertEqual(mc.memory_pressure_level(85, 0, 3000), "warn")           # high RAM%
        self.assertEqual(mc.memory_pressure_level(50, 1600, 3000), "warn")        # ~53% swap
        self.assertEqual(mc.memory_pressure_level(95, 0, 3000), "critical")       # very high RAM%
        self.assertEqual(mc.memory_pressure_level(50, 2600, 3000), "critical")    # ~87% swap
        self.assertEqual(mc.memory_pressure_level(70, None, None), "nominal")     # no swap info

    def test_collect_system_extra_shape(self):
        # Real collector (root-free syscalls/CLI); assert the keys + types that
        # exist on macOS. memory_pressure is always present.
        s = mc.collect_system_extra(memory_percent=50)
        self.assertIn("memory_pressure", s)
        self.assertIn(s["memory_pressure"], ("nominal", "warn", "critical"))
        if "load_avg" in s:
            self.assertEqual(len(s["load_avg"]), 3)
        if "disk_total_bytes" in s:
            self.assertGreater(s["disk_total_bytes"], 0)

    def test_snapshot_dict_includes_system(self):
        snap = mc.MachineSnapshot(
            collected_at="t", cpu_percent=1, memory_percent=2,
            memory_used_bytes=1, memory_total_bytes=2,
            battery=mc.BatteryThermal(), top_processes=[], capability={},
            system={"uptime_seconds": 100, "memory_pressure": "nominal"},
        )
        d = mc.machine_snapshot_dict(snap)
        self.assertEqual(d["system"]["uptime_seconds"], 100)
        self.assertEqual(d["system"]["memory_pressure"], "nominal")


class TestHeartbeatMetrics(unittest.TestCase):
    def _patch_battery(self, bt: mc.BatteryThermal):
        mc.collect_battery_thermal = lambda: bt  # type: ignore[assignment]

    def setUp(self):
        self._orig = mc.collect_battery_thermal
        self._orig_mem = mc.collect_memory
        self._orig_sys = mc.collect_system_extra
        self._orig_lpm = mc.collect_lpm

    def tearDown(self):
        mc.collect_battery_thermal = self._orig  # type: ignore[assignment]
        mc.collect_memory = self._orig_mem  # type: ignore[assignment]
        mc.collect_system_extra = self._orig_sys  # type: ignore[assignment]
        mc.collect_lpm = self._orig_lpm  # type: ignore[assignment]

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
        # M1/v1.38.1: the local-only kill/suspend capabilities never reach the cloud.
        self.assertNotIn("kill_process", m["capability"])
        self.assertNotIn("suspend_process", m["capability"])

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

    def test_system_block_synced_and_flattened(self):
        # v1.41: heartbeat_metrics also carries the system block; the load_avg
        # list is flattened into the three scalar keys the v0.66 RPC accepts.
        self._patch_battery(mc.BatteryThermal(has_battery=True, thermal_state=0))
        mc.collect_memory = lambda: (50, 0, 0)  # type: ignore[assignment]
        mc.collect_system_extra = lambda memory_percent=0: {  # type: ignore[assignment]
            "uptime_seconds": 123456,
            "load_avg": [2.5, 1.8, 1.2],
            "memory_pressure": "warn",
            "swap_used_bytes": 1073741824,
            "swap_total_bytes": 4294967296,
            "disk_free_bytes": 250000000000,
            "disk_total_bytes": 500000000000,
        }
        mc.collect_lpm = lambda: True  # type: ignore[assignment]
        m = mc.heartbeat_metrics()
        self.assertEqual(m["load_avg_1m"], 2.5)
        self.assertEqual(m["load_avg_5m"], 1.8)
        self.assertEqual(m["load_avg_15m"], 1.2)
        self.assertNotIn("load_avg", m)   # the raw list is never synced
        self.assertEqual(m["uptime_seconds"], 123456)
        self.assertEqual(m["memory_pressure"], "warn")
        self.assertEqual(m["disk_total_bytes"], 500000000000)
        self.assertEqual(m["lpm_on"], True)

    def test_lpm_none_omitted(self):
        self._patch_battery(mc.BatteryThermal(has_battery=True, thermal_state=0))
        mc.collect_memory = lambda: (10, 0, 0)  # type: ignore[assignment]
        mc.collect_system_extra = lambda memory_percent=0: {"memory_pressure": "nominal"}  # type: ignore[assignment]
        mc.collect_lpm = lambda: None  # type: ignore[assignment]
        m = mc.heartbeat_metrics()
        self.assertNotIn("lpm_on", m)     # None omitted → server preserves last-known
        self.assertEqual(m["memory_pressure"], "nominal")

    def test_system_block_failsoft(self):
        # A crashing system/LPM collector must NEVER break the heartbeat.
        self._patch_battery(mc.BatteryThermal(has_battery=True, thermal_state=0))

        def _boom(*a, **k):
            raise RuntimeError("sensor blew up")

        mc.collect_memory = _boom      # type: ignore[assignment]
        mc.collect_system_extra = _boom  # type: ignore[assignment]
        mc.collect_lpm = _boom         # type: ignore[assignment]
        m = mc.heartbeat_metrics()
        self.assertIsNotNone(m)
        self.assertIn("capability", m)          # base blob still returned
        self.assertNotIn("uptime_seconds", m)
        self.assertNotIn("lpm_on", m)


if __name__ == "__main__":
    unittest.main()
