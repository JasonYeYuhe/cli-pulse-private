// Unit tests for the v1.40 PR-4 DailyUsageArchiveManager glue: correct mapping
// of CostUsageScanResult → archive (incl. __claude_msg__ handling) with an
// injected temp root + isolated UserDefaults, persistence, and the cloud
// __claude_msg__ filter. macOS-gated (manager is macOS-only).

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class DailyUsageArchiveManagerTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dua-mgr-\(UUID().uuidString)", isDirectory: true)
    }

    func test_record_maps_scanResult_and_persists() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "dua-\(UUID().uuidString)")!
        let mgr = DailyUsageArchiveManager(root: root, defaults: defaults)

        let scan = CostUsageScanResult(entries: [
            .init(date: "2026-07-01", provider: "Claude", model: "claude-sonnet-4-5",
                  inputTokens: 100, cachedTokens: 0, outputTokens: 50, costUSD: 0.30, messageCount: 0),
            .init(date: "2026-07-01", provider: "Claude", model: "__claude_msg__",
                  inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 0, messageCount: 7),
            .init(date: "2026-07-01", provider: "Codex", model: "gpt-5",
                  inputTokens: 200, cachedTokens: 0, outputTokens: 20, costUSD: 0.10, messageCount: 0),
        ])
        await mgr.record(scan)

        let a = await mgr.snapshot()
        XCTAssertEqual(a.days["2026-07-01"]?.tokens, 370)
        XCTAssertEqual(a.days["2026-07-01"]?.messages, 7)
        XCTAssertNil(a.days["2026-07-01"]?.perModel["__claude_msg__"])
        XCTAssertGreaterThan(a.lastUpdatedUnixMs, 0)

        // Persisted to the injected root.
        let reloaded = DailyUsageArchiveIO.load(root: root)
        XCTAssertEqual(reloaded.days["2026-07-01"]?.tokens, 370)
    }

    func test_record_empty_scan_is_noop() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = DailyUsageArchiveManager(root: root, defaults: UserDefaults(suiteName: "dua-\(UUID().uuidString)")!)
        await mgr.record(CostUsageScanResult(entries: []))
        let a = await mgr.snapshot()
        XCTAssertTrue(a.days.isEmpty)
    }

    func test_mergeCloud_filters_msgBucket() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = DailyUsageArchiveManager(root: root, defaults: UserDefaults(suiteName: "dua-\(UUID().uuidString)")!)
        await mgr.mergeCloud([
            DailyUsage(date: "2026-06-01", provider: "Claude", model: "__claude_msg__",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0),
            DailyUsage(date: "2026-06-01", provider: "Codex", model: "gpt-5",
                       inputTokens: 50, cachedTokens: 0, outputTokens: 0, cost: 0.5),
        ])
        let a = await mgr.snapshot()
        XCTAssertNil(a.days["2026-06-01"]?.perModel["__claude_msg__"])
        XCTAssertEqual(a.days["2026-06-01"]?.perModel["gpt-5"]?.tokens, 50)
    }
}
#endif
