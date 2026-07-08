import XCTest
@testable import CLIPulseCore

/// v1.41 PR-7: the trimmed watch device model + the trim/cap helper that feeds
/// both the phone→watch WC payload and the watch's own live fetch.
final class WatchDeviceSummaryTests: XCTestCase {

    private func device(_ id: String, health: Bool) -> DeviceRecord {
        DeviceRecord(
            id: id, name: "Mac \(id)", type: "macOS", system: "macOS 26",
            status: "Online", last_sync_at: nil, helper_version: "1.28.0",
            current_session_count: 0, cpu_usage: 20, memory_usage: 40,
            cpu_temp_c: health ? 55.0 : nil,
            sensors_updated_at: health ? "2026-07-09T00:00:00Z" : nil,
            uptime_seconds: health ? 1000 : nil
        )
    }

    func testFiltersDevicesWithoutHealth() {
        let out = WatchDeviceTrim.summaries(from: [
            device("a", health: true), device("b", health: false), device("c", health: true),
        ])
        XCTAssertEqual(out.map(\.id), ["a", "c"])
    }

    func testCapsToLimit() {
        let devices = (0..<10).map { device("d\($0)", health: true) }
        let out = WatchDeviceTrim.summaries(from: devices)   // default limit 4
        XCTAssertEqual(out.count, 4)
        XCTAssertEqual(out.map(\.id), ["d0", "d1", "d2", "d3"])   // order preserved
    }

    func testZeroLimitIsSafe() {
        let out = WatchDeviceTrim.summaries(from: [device("a", health: true)], limit: 0)
        XCTAssertTrue(out.isEmpty)
    }

    func testMapsV066Fields() {
        let d = DeviceRecord(
            id: "x", name: "MBP", type: "macOS", system: "macOS 26", status: "Online",
            last_sync_at: nil, helper_version: "1.28.0", current_session_count: 0,
            cpu_usage: 30, memory_usage: 55, cpu_temp_c: 61.0, fan_rpm: 2100, thermal_state: 1,
            battery_charge_pct: 88, battery_state: "charging", battery_health_pct: 96.0,
            sensors_updated_at: "2026-07-09T00:00:00Z",
            uptime_seconds: 123456, load_avg_1m: 2.5, memory_pressure: "warn",
            disk_free_bytes: 250_000_000_000, disk_total_bytes: 500_000_000_000,
            lpm_on: true, fan_boost_active: true, fan_boost_target_rpm: 4200)
        let s = WatchDeviceSummary(from: d)
        XCTAssertEqual(s.uptimeSeconds, 123456)
        XCTAssertEqual(s.loadAvg1m, 2.5)
        XCTAssertEqual(s.memoryPressure, "warn")
        XCTAssertEqual(s.diskTotalBytes, 500_000_000_000)
        XCTAssertEqual(s.lpmOn, true)
        XCTAssertEqual(s.fanBoostActive, true)
        XCTAssertEqual(s.fanBoostTargetRpm, 4200)
        XCTAssertEqual(s.fanRpm, 2100)
        XCTAssertEqual(s.batteryState, "charging")
        XCTAssertEqual(s.deviceStatus, .online)
        // Fields that are mapped + rendered but were previously unasserted.
        XCTAssertEqual(s.cpuTempC, 61.0)
        XCTAssertEqual(s.thermalState, 1)
        XCTAssertEqual(s.batteryChargePct, 88)
        XCTAssertEqual(s.batteryHealthPct, 96.0)
        XCTAssertEqual(s.diskFreeBytes, 250_000_000_000)
    }

    func testCodableRoundtripSymmetric() throws {
        // The phone encodes and the watch decodes THIS type — must roundtrip.
        let s = WatchDeviceSummary(id: "x", name: "MBP", status: "Online",
                                   cpuTempC: 55.0, uptimeSeconds: 999,
                                   sensorsUpdatedAt: "2026-07-09T00:00:00Z")
        let data = try JSONEncoder().encode([s])
        let back = try JSONDecoder().decode([WatchDeviceSummary].self, from: data)
        XCTAssertEqual(back, [s])
    }

    func testReadingStale() {
        let s = WatchDeviceSummary(id: "x", name: "M", status: "Online",
                                   sensorsUpdatedAt: "2026-07-09T12:00:00Z")
        let soon = ISO8601DateFormatter().date(from: "2026-07-09T12:02:00Z")!
        let late = ISO8601DateFormatter().date(from: "2026-07-09T12:10:00Z")!
        XCTAssertFalse(s.isReadingStale(after: 300, now: soon))
        XCTAssertTrue(s.isReadingStale(after: 300, now: late))
    }
}
