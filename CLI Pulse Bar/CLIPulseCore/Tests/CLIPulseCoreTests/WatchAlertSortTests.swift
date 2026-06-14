import XCTest
@testable import CLIPulseCore

final class WatchAlertSortTests: XCTestCase {

    func test_severityRank_ordering() {
        XCTAssertEqual(WatchAlertSort.severityRank("Critical"), 0)
        XCTAssertEqual(WatchAlertSort.severityRank("Warning"), 1)
        XCTAssertEqual(WatchAlertSort.severityRank("Info"), 2)
        XCTAssertEqual(WatchAlertSort.severityRank("Bogus"), 3)
    }

    func test_bySeverity_ordersMostSevereFirst() {
        let alerts = [
            make(id: "a", severity: "Info"),
            make(id: "b", severity: "Critical"),
            make(id: "c", severity: "Warning"),
        ]
        XCTAssertEqual(WatchAlertSort.bySeverity(alerts).map(\.id), ["b", "c", "a"])
    }

    func test_bySeverity_isStableWithinSameSeverity() {
        let alerts = [
            make(id: "1", severity: "Warning"),
            make(id: "2", severity: "Critical"),
            make(id: "3", severity: "Warning"),
            make(id: "4", severity: "Critical"),
        ]
        // Both Criticals first (in original order 2,4), then both Warnings (1,3).
        XCTAssertEqual(WatchAlertSort.bySeverity(alerts).map(\.id), ["2", "4", "1", "3"])
    }

    func test_bySeverity_unknownSeverityGoesLast() {
        let alerts = [
            make(id: "x", severity: "Mystery"),
            make(id: "y", severity: "Info"),
        ]
        XCTAssertEqual(WatchAlertSort.bySeverity(alerts).map(\.id), ["y", "x"])
    }

    func test_bySeverity_emptyInput() {
        XCTAssertTrue(WatchAlertSort.bySeverity([]).isEmpty)
    }

    // MARK: - Helper

    private func make(id: String, severity: String) -> AlertRecord {
        AlertRecord(
            id: id, type: "QuotaLow", severity: severity, title: "t", message: "m",
            created_at: "2026-06-14T00:00:00Z", is_read: false, is_resolved: false,
            acknowledged_at: nil, snoozed_until: nil,
            related_project_id: nil, related_project_name: nil,
            related_session_id: nil, related_session_name: nil,
            related_provider: nil, related_device_name: nil
        )
    }
}
