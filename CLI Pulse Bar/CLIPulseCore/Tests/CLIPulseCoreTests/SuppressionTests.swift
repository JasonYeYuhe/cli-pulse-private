import XCTest
@testable import CLIPulseCore

final class SuppressionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)  // arbitrary fixed "now"
    private let day: TimeInterval = 24 * 3600

    // MARK: - SuppressionEntry.isPermanent

    func testIsPermanentTrueForDistantFuture() {
        let entry = AppState.SuppressionEntry(
            until: .distantFuture,
            dismissedAt: now
        )
        XCTAssertTrue(entry.isPermanent)
    }

    func testIsPermanentFalseForOneHourSnooze() {
        let entry = AppState.SuppressionEntry(
            until: now.addingTimeInterval(3600),
            dismissedAt: now
        )
        XCTAssertFalse(entry.isPermanent)
    }

    func testIsPermanentFalseForOneYearSnooze() {
        let entry = AppState.SuppressionEntry(
            until: now.addingTimeInterval(365 * day),
            dismissedAt: now
        )
        // A one-year snooze is unusual but not sentinel-distantFuture; must be
        // treated as time-boxed.
        XCTAssertFalse(entry.isPermanent)
    }

    // MARK: - prunedSuppressions: time-boxed entries

    func testTimeBoxedEntryStillActiveBeforeExpiry() {
        let entries: [String: AppState.SuppressionEntry] = [
            "a": .init(until: now.addingTimeInterval(60), dismissedAt: now)
        ]
        let result = AppState.prunedSuppressions(entries, now: now)
        XCTAssertEqual(result.active, ["a"])
        XCTAssertEqual(result.kept.count, 1)
    }

    func testTimeBoxedEntryPrunedAfterExpiry() {
        let entries: [String: AppState.SuppressionEntry] = [
            "a": .init(until: now.addingTimeInterval(-60), dismissedAt: now.addingTimeInterval(-3600))
        ]
        let result = AppState.prunedSuppressions(entries, now: now)
        XCTAssertTrue(result.active.isEmpty)
        XCTAssertTrue(result.kept.isEmpty)
    }

    // MARK: - prunedSuppressions: permanent entries

    func testPermanentEntryStillActiveWithinRetention() {
        let entries: [String: AppState.SuppressionEntry] = [
            "perm": .init(until: .distantFuture, dismissedAt: now.addingTimeInterval(-10 * day))
        ]
        let result = AppState.prunedSuppressions(entries, now: now, retentionDays: 180)
        XCTAssertEqual(result.active, ["perm"])
    }

    func testPermanentEntryPrunedAfterRetention() {
        let entries: [String: AppState.SuppressionEntry] = [
            "perm": .init(until: .distantFuture, dismissedAt: now.addingTimeInterval(-200 * day))
        ]
        let result = AppState.prunedSuppressions(entries, now: now, retentionDays: 180)
        XCTAssertTrue(result.active.isEmpty, "Permanent entry should be recycled after 180 days")
        XCTAssertTrue(result.kept.isEmpty)
    }

    func testPermanentEntryAtExactRetentionBoundary() {
        // dismissedAt == now - 180d → cutoff is exactly at dismissedAt.
        // `entry.dismissedAt > permanentCutoff` is false at equality → prune.
        let entries: [String: AppState.SuppressionEntry] = [
            "perm": .init(until: .distantFuture, dismissedAt: now.addingTimeInterval(-180 * day))
        ]
        let result = AppState.prunedSuppressions(entries, now: now, retentionDays: 180)
        XCTAssertTrue(result.active.isEmpty)
    }

    // MARK: - prunedSuppressions: mixed batch

    func testMixedBatchKeepsActiveDropsExpired() {
        let entries: [String: AppState.SuppressionEntry] = [
            "active_permanent":  .init(until: .distantFuture, dismissedAt: now.addingTimeInterval(-10 * day)),
            "expired_permanent": .init(until: .distantFuture, dismissedAt: now.addingTimeInterval(-365 * day)),
            "active_snooze":     .init(until: now.addingTimeInterval(3600), dismissedAt: now),
            "expired_snooze":    .init(until: now.addingTimeInterval(-60), dismissedAt: now.addingTimeInterval(-3600)),
        ]
        let result = AppState.prunedSuppressions(entries, now: now)
        XCTAssertEqual(result.active, ["active_permanent", "active_snooze"])
        XCTAssertEqual(Set(result.kept.keys), ["active_permanent", "active_snooze"])
    }

    func testEmptyInput() {
        let result = AppState.prunedSuppressions([:], now: now)
        XCTAssertTrue(result.active.isEmpty)
        XCTAssertTrue(result.kept.isEmpty)
    }
}
