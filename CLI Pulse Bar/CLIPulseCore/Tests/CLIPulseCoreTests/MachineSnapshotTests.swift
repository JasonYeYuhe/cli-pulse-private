#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// System Monitor S4: MachineSnapshot decodes the helper's get_machine_snapshot
/// reply (a JSONSerialization `[String: Any]`, so numbers arrive as NSNumber).
final class MachineSnapshotTests: XCTestCase {

    private var laptopDict: [String: Any] {
        [
            "cpu_percent": 26,
            "memory_percent": 64,
            "memory_used_bytes": 11_000_000_000,
            "memory_total_bytes": 17_179_869_184,
            "battery": [
                "has_battery": true, "charge_pct": 100, "state": "charged",
                "cycle_count": 59, "health_pct": 95.0, "design_capacity": 8694,
                "current_capacity": 8262, "battery_temp_c": 31.0,
                "adapter_watts": 65.0, "thermal_state": 0,
            ] as [String: Any],
            "top_processes": [
                ["pid": 429, "name": "WindowServer", "cpu_percent": 21.9, "rss_mb": 67.5, "uid": 0] as [String: Any],
                // uid omitted → -1 fallback (older helper / unreadable).
                ["pid": 3942, "name": "cli_pulse_helper", "cpu_percent": 5.8, "rss_mb": 29.5] as [String: Any],
            ],
            "capability": ["process_table": true, "battery": true, "thermal_state": true,
                           "temps": true, "fans": true, "power": true, "kill_process": true],
            "sensors": [
                "cpu_power_w": 5.36, "gpu_power_w": 1.38, "ane_power_w": 0.0,
                "system_power_w": 8.27, "cpu_temp_c": 68.4, "gpu_temp_c": 56.8,
                "fan_rpm": 1645, "fan_max_rpm": 4744,
            ] as [String: Any],
        ]
    }

    func testLaptopSnapshot() {
        let s = MachineSnapshot(dict: laptopDict)
        XCTAssertEqual(s.cpuPercent, 26)
        XCTAssertEqual(s.memoryPercent, 64)
        XCTAssertEqual(s.memoryTotalBytes, 17_179_869_184)
        XCTAssertTrue(s.battery.hasBattery)
        XCTAssertEqual(s.battery.chargePct, 100)
        XCTAssertEqual(s.battery.state, "charged")
        XCTAssertEqual(s.battery.cycleCount, 59)
        XCTAssertEqual(s.battery.healthPct!, 95.0, accuracy: 0.01)
        XCTAssertEqual(s.battery.adapterWatts!, 65.0, accuracy: 0.01)
        XCTAssertEqual(s.topProcesses.count, 2)
        XCTAssertEqual(s.topProcesses.first?.name, "WindowServer")
        XCTAssertEqual(s.topProcesses.first?.rssMB ?? 0, 67.5, accuracy: 0.01)
        // M1: uid decoded when present (root=0), falls back to -1 when absent.
        XCTAssertEqual(s.topProcesses.first?.uid, 0)
        XCTAssertEqual(s.topProcesses.last?.uid, -1)
        XCTAssertTrue(s.can("kill_process"))
        XCTAssertEqual(s.cpuTempC!, 68.4, accuracy: 0.01)
        XCTAssertEqual(s.gpuTempC!, 56.8, accuracy: 0.01)
        XCTAssertEqual(s.systemPowerW!, 8.27, accuracy: 0.01)
        XCTAssertEqual(s.fanRpm, 1645)
        XCTAssertTrue(s.can("temps"))
        XCTAssertTrue(s.can("fans"))
        XCTAssertTrue(s.can("power"))
    }

    func testDesktopNoBatteryNoSensors() {
        // Mac mini: no battery node, S2-only helper (no native sensors).
        let s = MachineSnapshot(dict: [
            "cpu_percent": 12, "memory_percent": 40,
            "battery": ["has_battery": false] as [String: Any],
            "top_processes": [],
            "capability": ["process_table": true, "battery": false, "thermal_state": true,
                           "temps": false, "fans": false, "power": false],
            "sensors": NSNull(),
        ])
        XCTAssertFalse(s.battery.hasBattery)
        XCTAssertNil(s.cpuTempC)
        XCTAssertNil(s.fanRpm)
        XCTAssertFalse(s.can("temps"))
        XCTAssertFalse(s.can("battery"))
        XCTAssertTrue(s.can("process_table"))
    }

    func testEmptyDictDoesNotCrash() {
        let s = MachineSnapshot(dict: [:])
        XCTAssertEqual(s.cpuPercent, 0)
        XCTAssertFalse(s.battery.hasBattery)
        XCTAssertTrue(s.topProcesses.isEmpty)
        XCTAssertTrue(s.capability.isEmpty)
        XCTAssertNil(s.systemPowerW)
    }

    func testMalformedFieldsIgnored() {
        // Wrong types must not crash; they just yield nil/defaults.
        let s = MachineSnapshot(dict: [
            "cpu_percent": "not a number",
            "battery": "not a dict",
            "top_processes": [["pid": "x", "name": 5]],   // bad row dropped
            "capability": ["temps": "yes"],               // non-bool dropped
            "sensors": ["cpu_temp_c": "hot"],
        ])
        XCTAssertEqual(s.cpuPercent, 0)
        XCTAssertFalse(s.battery.hasBattery)
        XCTAssertTrue(s.topProcesses.isEmpty)
        XCTAssertFalse(s.can("temps"))
        XCTAssertNil(s.cpuTempC)
    }
}
#endif
