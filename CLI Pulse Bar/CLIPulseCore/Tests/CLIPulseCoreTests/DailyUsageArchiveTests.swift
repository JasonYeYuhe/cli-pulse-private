// Unit tests for the v1.40 PR-4 DailyUsageArchive spine. Locks: scan grouping +
// __claude_msg__ exclusion from the per-model breakdown (but inclusion in
// messages), replace-by-day idempotency, prune→month-fold with a preserved
// lifetime total and no double count, cloud fill-only non-destructiveness, and
// IO round-trip / version invalidation. Cross-platform (pure core).

import XCTest
@testable import CLIPulseCore

final class DailyUsageArchiveTests: XCTestCase {

    private func se(_ date: String, _ provider: String, _ model: String,
                    input: Int = 0, cached: Int = 0, output: Int = 0,
                    cost: Double = 0, msgs: Int = 0) -> ScanEntry {
        ScanEntry(date: date, provider: provider, model: model,
                  inputTokens: input, cachedTokens: cached, outputTokens: output,
                  cost: cost, messages: msgs)
    }

    // MARK: - mergeScanEntries grouping

    func test_mergeScan_groups_and_excludes_msgBucket_from_models() {
        var a = DailyUsageArchive()
        a.mergeScanEntries([
            se("2026-07-01", "Claude", "claude-sonnet-4-5", input: 100, output: 50, cost: 0.30, msgs: 0),
            se("2026-07-01", "Claude", ScanEntry.messageBucketModel, cost: 0, msgs: 5),   // synthetic
            se("2026-07-01", "Codex", "gpt-5", input: 200, output: 20, cost: 0.10, msgs: 0),
        ])
        let day = a.days["2026-07-01"]!
        XCTAssertEqual(day.tokens, 100 + 50 + 200 + 20)   // msg bucket adds 0 tokens
        XCTAssertEqual(day.cost, 0.40, accuracy: 0.0001)
        XCTAssertEqual(day.messages, 5)                    // from the synthetic bucket
        XCTAssertEqual(day.perProvider["Claude"]?.messages, 5)
        XCTAssertEqual(day.perProvider["Codex"]?.tokens, 220)
        // Per-model excludes the synthetic bucket.
        XCTAssertNil(day.perModel[ScanEntry.messageBucketModel])
        XCTAssertEqual(day.perModel["claude-sonnet-4-5"]?.tokens, 150)
        XCTAssertEqual(day.perModel["gpt-5"]?.tokens, 220)
    }

    func test_mergeScan_is_idempotent_replace_not_additive() {
        let entries = [se("2026-07-01", "Codex", "gpt-5", input: 100, cost: 1)]
        var once = DailyUsageArchive(); once.mergeScanEntries(entries)
        var twice = DailyUsageArchive(); twice.mergeScanEntries(entries); twice.mergeScanEntries(entries)
        XCTAssertEqual(once.days, twice.days, "re-merging the same window must not double-count")
        XCTAssertEqual(twice.days["2026-07-01"]?.tokens, 100)
    }

    // MARK: - prune + month fold

    func test_mergeScan_prune_folds_into_months_preserving_lifetime() {
        var a = DailyUsageArchive()
        let days = ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04", "2026-01-05"]
        a.mergeScanEntries(days.map { se($0, "Codex", "gpt-5", input: 10, cost: 1, msgs: 2) }, retainDays: 3)

        XCTAssertEqual(a.days.count, 3)
        XCTAssertNotNil(a.days["2026-01-05"])
        XCTAssertNil(a.days["2026-01-01"])
        XCTAssertEqual(a.foldedThroughDay, "2026-01-02")
        let month = a.months["2026-01"]!
        XCTAssertEqual(month.tokens, 20)      // 2 evicted days × 10
        XCTAssertEqual(month.cost, 2, accuracy: 0.0001)
        XCTAssertEqual(month.messages, 4)
        // Lifetime = days + months, no overlap.
        XCTAssertEqual(DailyUsageStats.totalTokens(a), 50)
        XCTAssertEqual(DailyUsageStats.totalCost(a), 5, accuracy: 0.0001)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), 10)
    }

    func test_mergeScan_evicted_day_not_reintroduced() {
        var a = DailyUsageArchive()
        let days = ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04", "2026-01-05"]
        a.mergeScanEntries(days.map { se($0, "Codex", "gpt-5", input: 10, cost: 1) }, retainDays: 3)
        let monthsBefore = a.months
        // A later scan re-reports an already-folded old day (e.g. backfill overlap).
        a.mergeScanEntries([se("2026-01-01", "Codex", "gpt-5", input: 999, cost: 99)], retainDays: 3)
        XCTAssertNil(a.days["2026-01-01"], "folded day must not re-enter the daily tier")
        XCTAssertEqual(a.months, monthsBefore, "months must not be double-counted")
    }

    // MARK: - cloud fill-only

    func test_mergeCloud_is_fill_only() {
        var a = DailyUsageArchive()
        a.mergeScanEntries([se("2026-07-01", "Claude", "claude-sonnet-4-5", input: 100, cost: 1, msgs: 5)])
        // Cloud reports a different (higher) number for the SAME day → must NOT clobber local.
        a.mergeCloudDays([CloudEntry(date: "2026-07-01", provider: "Claude", model: "claude-sonnet-4-5",
                                     inputTokens: 999, cachedTokens: 0, outputTokens: 0, cost: 9)])
        XCTAssertEqual(a.days["2026-07-01"]?.tokens, 100, "local day preserved")
        XCTAssertEqual(a.days["2026-07-01"]?.messages, 5, "local messages preserved")
        // Cloud fills a day local doesn't have (other device / pre-history).
        a.mergeCloudDays([CloudEntry(date: "2026-06-01", provider: "Codex", model: "gpt-5",
                                     inputTokens: 50, cachedTokens: 0, outputTokens: 0, cost: 0.5)])
        XCTAssertEqual(a.days["2026-06-01"]?.tokens, 50)
    }

    // MARK: - IO

    private func makeTempRoot() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("archive-test-\(UUID().uuidString)", isDirectory: true)
        return dir
    }

    func test_IO_roundtrip() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var a = DailyUsageArchive()
        a.mergeScanEntries([se("2026-07-01", "Codex", "gpt-5", input: 100, cost: 1, msgs: 3)])
        a.lastUpdatedUnixMs = 123456
        XCTAssertTrue(DailyUsageArchiveIO.save(a, root: root))
        let loaded = DailyUsageArchiveIO.load(root: root)
        XCTAssertEqual(loaded, a)
    }

    func test_IO_missing_file_returns_empty() {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = DailyUsageArchiveIO.load(root: root)
        XCTAssertTrue(loaded.days.isEmpty)
        XCTAssertEqual(loaded.version, DailyUsageArchive.currentVersion)
    }

    func test_IO_version_mismatch_returns_empty() throws {
        let root = makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = DailyUsageArchiveIO.fileURL(root: root)
        try Data(#"{"version":999,"days":{},"months":{},"lastUpdatedUnixMs":0}"#.utf8).write(to: url)
        let loaded = DailyUsageArchiveIO.load(root: root)
        XCTAssertTrue(loaded.days.isEmpty)
        XCTAssertEqual(loaded.version, DailyUsageArchive.currentVersion)
    }
}
