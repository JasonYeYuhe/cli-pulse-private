// Unit tests for the v1.40 QoderCollector (CodexBar parity). Locks: camelCase +
// snake_case decode, additive total+shared merge, remaining/percentage
// derivation, ISO8601 + epoch reset parse, and the `.quota` credits mapping.
// macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class QoderCollectorTests: XCTestCase {
    private let collector = QoderCollector()

    private func parse(_ json: String) throws -> QoderCollector.Snapshot {
        try QoderCollector.parse(Data(json.utf8))
    }

    func test_parse_totalOnly_camelCase() throws {
        let s = try parse(#"""
        {"totalQuota":{"quotaSummary":{"usedValue":30,"limitValue":100,"remainingValue":70,
         "usagePercentage":30,"unit":"credits"}},"nextResetAt":"2027-01-01T00:00:00Z"}
        """#)
        XCTAssertEqual(s.usedCredits, 30, accuracy: 0.001)
        XCTAssertEqual(s.totalCredits, 100, accuracy: 0.001)
        XCTAssertEqual(s.remainingCredits, 70, accuracy: 0.001)
        XCTAssertEqual(s.usagePercentage, 30, accuracy: 0.001)
        XCTAssertEqual(s.unit, "credits")
        XCTAssertNotNil(s.resetsAt)
    }

    func test_parse_snakeCase_derives_remaining_and_percent() throws {
        let s = try parse(#"{"total_quota":{"quota_summary":{"used_value":10,"limit_value":50}}}"#)
        XCTAssertEqual(s.usedCredits, 10, accuracy: 0.001)
        XCTAssertEqual(s.totalCredits, 50, accuracy: 0.001)
        XCTAssertEqual(s.remainingCredits, 40, accuracy: 0.001)   // 50-10
        XCTAssertEqual(s.usagePercentage, 20, accuracy: 0.001)    // 10/50
    }

    func test_parse_total_plus_shared_is_additive() throws {
        let s = try parse(#"""
        {"totalQuota":{"quotaSummary":{"usedValue":30,"limitValue":100,"remainingValue":70}},
         "sharedQuota":{"quotaSummary":{"usedValue":20,"limitValue":50,"remainingValue":30}}}
        """#)
        XCTAssertEqual(s.usedCredits, 50, accuracy: 0.001)
        XCTAssertEqual(s.totalCredits, 150, accuracy: 0.001)
        XCTAssertEqual(s.remainingCredits, 100, accuracy: 0.001)
        XCTAssertEqual(s.usagePercentage, 50.0 / 150.0 * 100, accuracy: 0.01)
    }

    func test_parse_epoch_millis_reset() throws {
        let s = try parse(#"{"totalQuota":{"quotaSummary":{"usedValue":0,"limitValue":10}},"nextResetAt":1893456000000}"#)
        XCTAssertEqual(s.resetsAt?.timeIntervalSince1970 ?? -1, 1_893_456_000, accuracy: 1)
    }

    func test_parse_missing_totalQuota_throws() {
        XCTAssertThrowsError(try parse(#"{"sharedQuota":{"quotaSummary":{"usedValue":1,"limitValue":2}}}"#)) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_parse_invalid_json_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_buildResult_quota_credits() {
        let s = QoderCollector.Snapshot(usedCredits: 30, totalCredits: 100, remainingCredits: 70,
                                        usagePercentage: 30, unit: "credits",
                                        resetsAt: Date(timeIntervalSince1970: 1_893_456_000))
        let result = QoderCollector.buildResult(s)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.provider, "Qoder")
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 70)
        XCTAssertEqual(u.tiers.first?.name, "Credits")
        XCTAssertNotNil(u.tiers.first?.reset_time)
        XCTAssertTrue(u.status_text.contains("70 / 100"), u.status_text)
        XCTAssertTrue(u.status_text.contains("credits"), u.status_text)
    }

    func test_buildResult_saturates_on_huge_credits_no_crash() {
        // An "unlimited" plan sentinel (Int64.max-ish) must saturate, not trap Int().
        let s = QoderCollector.Snapshot(usedCredits: 0, totalCredits: 1e20, remainingCredits: 1e20,
                                        usagePercentage: 0, unit: nil, resetsAt: nil)
        let result = QoderCollector.buildResult(s)
        XCTAssertEqual(result.usage.quota, Int.max)
        XCTAssertEqual(result.usage.remaining, Int.max)
    }

    func test_creditInt_clamps() {
        XCTAssertEqual(QoderCollector.creditInt(-5), 0)
        XCTAssertEqual(QoderCollector.creditInt(1e30), Int.max)
        XCTAssertEqual(QoderCollector.creditInt(42.6), 43)
    }

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .qoder, manualCookieHeader: "sid=abc")))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .qoder)))
    }
}
#endif
