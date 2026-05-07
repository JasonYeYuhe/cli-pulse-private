import XCTest
@testable import HelperKit
import Foundation

/// Tests for `DeviceSnapshotCollector` (Phase 4E Slice 2a). Pin the
/// arithmetic + clamp invariants and the `vm_stat` parser against
/// canned input so behaviour matches `helper/system_collector.py`'s
/// `_collect_cpu_usage` / `_collect_memory_usage` semantics 1:1.
final class DeviceSnapshotCollectorTests: XCTestCase {

    // MARK: - CPU

    func testCpuUsageZeroWhenLoadAverageUnavailable() {
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { nil },
            cpuCount: { 4 },
            vmStatOutput: { "" }
        ))
        XCTAssertEqual(collector.collectCPU(), 0)
    }

    func testCpuUsageNormalProportion() {
        // load=2.0 on 4 logical cores → 50%.
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 2.0 },
            cpuCount: { 4 },
            vmStatOutput: { "" }
        ))
        XCTAssertEqual(collector.collectCPU(), 50)
    }

    func testCpuUsageClampedAtOneHundred() {
        // load=16.0 on 4 cores → would compute to 400%, clamps to 100.
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 16.0 },
            cpuCount: { 4 },
            vmStatOutput: { "" }
        ))
        XCTAssertEqual(collector.collectCPU(), 100)
    }

    func testCpuUsageHandlesZeroCpuCount() {
        // Defensive: cpuCount=0 must not divide-by-zero — we clamp to 1.
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 1.0 },
            cpuCount: { 0 },
            vmStatOutput: { "" }
        ))
        XCTAssertEqual(collector.collectCPU(), 100)
    }

    // MARK: - Memory

    func testMemoryUsageZeroOnEmptyVmStat() async {
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 1.0 },
            cpuCount: { 4 },
            vmStatOutput: { "" }
        ))
        let result = await collector.collectMemory()
        XCTAssertEqual(result, 0)
    }

    func testMemoryUsageZeroOnUnparseableVmStat() async {
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 1.0 },
            cpuCount: { 4 },
            vmStatOutput: { "garbage that has no colons or numbers" }
        ))
        let result = await collector.collectMemory()
        XCTAssertEqual(result, 0)
    }

    func testMemoryUsageParsesTypicalVmStatOutput() async {
        // A trimmed real-world `vm_stat` output. Active+wired+compressor
        // = 100+200+50 = 350; total = (free+spec)+(active+wired+comp)+inactive
        // = (50+10) + 350 + 100 = 510. used_ratio = 350/510 ≈ 0.686.
        // Truncated to int = 68.
        let canned = """
        Mach Virtual Memory Statistics: (page size of 16384 bytes)
        Pages free:                                  50.
        Pages active:                               100.
        Pages inactive:                             100.
        Pages speculative:                           10.
        Pages wired down:                           200.
        Pages occupied by compressor:                50.
        Pages purgeable:                              0.
        """
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 1.0 },
            cpuCount: { 4 },
            vmStatOutput: { canned }
        ))
        let result = await collector.collectMemory()
        XCTAssertEqual(result, 68)
    }

    // MARK: - End-to-end collect()

    func testCollectReturnsBothFields() async {
        let canned = """
        Pages free:                                  10.
        Pages active:                                90.
        Pages inactive:                              50.
        Pages speculative:                            0.
        Pages wired down:                             0.
        Pages occupied by compressor:                 0.
        """
        let collector = DeviceSnapshotCollector(hooks: .init(
            loadAverage1m: { 1.0 },
            cpuCount: { 2 },
            vmStatOutput: { canned }
        ))
        let snapshot = await collector.collect()
        XCTAssertEqual(snapshot.cpuUsage, 50)
        // active=90, inactive=50, free=10, total=150, ratio=90/150=0.6 → 60
        XCTAssertEqual(snapshot.memoryUsage, 60)
    }

    // MARK: - Wire-shape parity

    func testDeviceSnapshotEncodesSnakeCase() throws {
        let snapshot = DeviceSnapshot(cpuUsage: 42, memoryUsage: 73)
        let data = try JSONEncoder().encode(snapshot)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"cpu_usage\":42"),
                      "DeviceSnapshot must wire-format as snake_case `cpu_usage`; got \(json)")
        XCTAssertTrue(json.contains("\"memory_usage\":73"),
                      "DeviceSnapshot must wire-format as snake_case `memory_usage`; got \(json)")
    }
}
