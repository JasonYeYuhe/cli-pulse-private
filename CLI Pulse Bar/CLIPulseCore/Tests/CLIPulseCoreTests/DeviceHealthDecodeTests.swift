import XCTest
@testable import CLIPulseCore

/// System Monitor S5: DeviceRecord decodes the v0.63 machine-health columns
/// (Codable cache path) and exposes them honestly via capability.
final class DeviceHealthDecodeTests: XCTestCase {

    private func decode(_ json: String) throws -> DeviceRecord {
        try JSONDecoder().decode(DeviceRecord.self, from: Data(json.utf8))
    }

    func testDecodesHealthFields() throws {
        let d = try decode("""
        {"id":"d1","name":"MBP","type":"macOS","system":"macOS 26","status":"Online",
         "helper_version":"1.24.0","current_session_count":0,"cpu_usage":26,"memory_usage":64,
         "cpu_temp_c":68.4,"gpu_temp_c":56.8,"cpu_power_w":5.36,"system_power_w":8.27,
         "fan_rpm":1645,"fan_max_rpm":4744,"thermal_state":0,
         "battery_charge_pct":100,"battery_state":"charged","battery_cycle_count":59,
         "battery_health_pct":95.0,"adapter_watts":65.0,
         "sensors_capability":{"temps":true,"fans":true,"power":true,"battery":true},
         "sensors_updated_at":"2026-07-04T00:00:00Z"}
        """)
        XCTAssertEqual(d.cpu_temp_c, 68.4)
        XCTAssertEqual(d.fan_rpm, 1645)
        XCTAssertEqual(d.thermal_state, 0)
        XCTAssertEqual(d.battery_health_pct, 95.0)
        XCTAssertEqual(d.battery_cycle_count, 59)
        XCTAssertEqual(d.battery_state, "charged")
        XCTAssertTrue(d.hasDeviceHealth)
        XCTAssertTrue(d.sensorCan("temps"))
        XCTAssertTrue(d.sensorCan("fans"))
        XCTAssertFalse(d.sensorCan("nonexistent"))
    }

    func testLegacyDeviceWithoutHealthStillDecodes() throws {
        // Pre-v0.63 cached JSON lacking every sensor key must decode with nils.
        let d = try decode("""
        {"id":"d2","name":"Old Mac","type":"macOS","system":"macOS 15","status":"Offline",
         "helper_version":"1.20.0","current_session_count":0}
        """)
        XCTAssertNil(d.cpu_temp_c)
        XCTAssertNil(d.fan_rpm)
        XCTAssertTrue(d.sensors_capability.isEmpty)
        XCTAssertFalse(d.hasDeviceHealth)
    }

    func testDecodesV066MobileMachineFields() throws {
        // v0.66: system block + LPM + fan-boost state + remote-control map.
        let d = try decode("""
        {"id":"d4","name":"MBP","type":"macOS","system":"macOS 26","status":"Online",
         "helper_version":"1.28.0","current_session_count":0,
         "uptime_seconds":123456,"load_avg_1m":2.5,"load_avg_5m":1.8,"load_avg_15m":1.2,
         "memory_pressure":"warn","swap_used_bytes":1073741824,"swap_total_bytes":4294967296,
         "disk_free_bytes":250000000000,"disk_total_bytes":500000000000,
         "lpm_on":true,"fan_boost_active":true,"fan_boost_target_rpm":4200,
         "machine_controls":{"remote_fan":true,"remote_lpm":false},
         "sensors_updated_at":"2026-07-09T00:00:00Z"}
        """)
        XCTAssertEqual(d.uptime_seconds, 123456)
        XCTAssertEqual(d.load_avg_1m, 2.5)
        XCTAssertEqual(d.memory_pressure, "warn")
        XCTAssertEqual(d.swap_total_bytes, 4294967296)
        XCTAssertEqual(d.disk_total_bytes, 500000000000)
        XCTAssertEqual(d.lpm_on, true)
        XCTAssertEqual(d.fan_boost_active, true)
        XCTAssertEqual(d.fan_boost_target_rpm, 4200)
        XCTAssertTrue(d.remoteControlCan("remote_fan"))
        XCTAssertFalse(d.remoteControlCan("remote_lpm"))
        XCTAssertTrue(d.hasDeviceHealth)
    }

    func testV066FieldsAbsentDecodeToNil() throws {
        // A device on an old helper (no v0.66 keys) must still decode cleanly.
        let d = try decode("""
        {"id":"d5","name":"Old","type":"macOS","system":"macOS 15","status":"Online",
         "helper_version":"1.26.0","current_session_count":0,"cpu_temp_c":55.0,
         "sensors_updated_at":"2026-07-09T00:00:00Z"}
        """)
        XCTAssertNil(d.uptime_seconds)
        XCTAssertNil(d.lpm_on)
        XCTAssertNil(d.fan_boost_target_rpm)
        XCTAssertTrue(d.machine_controls.isEmpty)
        XCTAssertFalse(d.remoteControlCan("remote_fan"))
    }

    func testReadingStaleThreshold() throws {
        let base = "{\"id\":\"d6\",\"name\":\"M\",\"type\":\"macOS\",\"system\":\"macOS 26\",\"status\":\"Online\",\"helper_version\":\"1.28.0\",\"current_session_count\":0,\"uptime_seconds\":1,"
        let fresh = try decode(base + "\"sensors_updated_at\":\"2026-07-09T12:00:00Z\"}")
        let now = ISO8601DateFormatter().date(from: "2026-07-09T12:02:00Z")!  // 2 min later
        XCTAssertFalse(fresh.isReadingStale(after: 300, now: now))
        let later = ISO8601DateFormatter().date(from: "2026-07-09T12:10:00Z")!  // 10 min later
        XCTAssertTrue(fresh.isReadingStale(after: 300, now: later))
    }

    func testDesktopNoBattery() throws {
        // Mac mini: thermal + no battery.
        let d = try decode("""
        {"id":"d3","name":"mini","type":"macOS","system":"macOS 26","status":"Online",
         "helper_version":"1.24.0","current_session_count":0,"thermal_state":0,
         "sensors_capability":{"process_table":true,"battery":false,"temps":true},
         "sensors_updated_at":"2026-07-04T00:00:00Z"}
        """)
        XCTAssertTrue(d.hasDeviceHealth)
        XCTAssertFalse(d.sensorCan("battery"))
        XCTAssertNil(d.battery_health_pct)
    }
}
