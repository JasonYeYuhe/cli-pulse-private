// Unit tests for the v1.40.0 ChutesCollector (CodexBar parity — primary shape
// only). Locks: rolling/monthly window discovery (data-wrapped and flat),
// explicit-percent + used/limit + percent-remaining derivation, epoch(sec|ms)/
// ISO8601 reset parse, `.quota` tier mapping, and the `.statusOnly` schema-drift
// fallback. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ChutesCollectorTests: XCTestCase {
    private let collector = ChutesCollector()

    private func parse(_ json: String) throws -> ChutesCollector.Snapshot {
        try ChutesCollector.parse(Data(json.utf8))
    }

    // MARK: - parse

    func test_parse_data_wrapped_explicit_percent_and_derived() throws {
        let s = try parse(#"""
        {"data":{"rolling":{"used_percent":40,"reset_at":1893456000},
                 "monthly":{"used":300,"limit":1000}}}
        """#)
        XCTAssertEqual(s.rolling?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertNotNil(s.rolling?.resetsAt)
        XCTAssertEqual(s.monthly?.usedPercent ?? -1, 30, accuracy: 0.001)   // 300/1000
    }

    func test_parse_flat_remaining_and_limit() throws {
        let s = try parse(#"{"rolling_4h":{"remaining":20,"limit":100}}"#)
        XCTAssertEqual(s.rolling?.usedPercent ?? -1, 80, accuracy: 0.001)    // (100-20)/100
        XCTAssertNil(s.monthly)
    }

    func test_parse_percent_remaining_inverts() throws {
        let s = try parse(#"{"rolling":{"percent_remaining":25}}"#)
        XCTAssertEqual(s.rolling?.usedPercent ?? -1, 75, accuracy: 0.001)
    }

    func test_parse_fractional_percent_scales_like_upstream() throws {
        // Upstream treats a sub-1 percent as a 0–1 fraction: 0.4 ⇒ 40%.
        let s = try parse(#"{"rolling":{"used_percent":0.4}}"#)
        XCTAssertEqual(s.rolling?.usedPercent ?? -1, 40, accuracy: 0.001)
        // percent_remaining fraction inverts after scaling: 0.25 ⇒ 25% ⇒ 75% used.
        let s2 = try parse(#"{"monthly":{"percent_remaining":0.25}}"#)
        XCTAssertEqual(s2.monthly?.usedPercent ?? -1, 75, accuracy: 0.001)
    }

    func test_parse_iso8601_reset() throws {
        let s = try parse(#"{"monthly":{"usage_percent":10,"resets_at":"2027-01-01T00:00:00Z"}}"#)
        XCTAssertNotNil(s.monthly?.resetsAt)
    }

    func test_parse_no_windows_is_empty_snapshot() throws {
        let s = try parse(#"{"account":"x","plan":"Pro"}"#)
        XCTAssertNil(s.rolling)
        XCTAssertNil(s.monthly)
        XCTAssertEqual(s.planName, "Pro")
    }

    func test_parse_invalid_json_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult

    func test_buildResult_quota_windows() {
        let s = ChutesCollector.Snapshot(
            rolling: .init(usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_893_456_000)),
            monthly: .init(usedPercent: 30, resetsAt: nil),
            planName: "Pro")
        let result = ChutesCollector.buildResult(s)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 60)                 // rolling 100-40
        XCTAssertEqual(u.plan_type, "Pro")
        XCTAssertEqual(u.provider, "Chutes")
        XCTAssertEqual(u.tiers.count, 2)
        XCTAssertEqual(u.tiers.first { $0.name == "4-hour" }?.remaining, 60)
        XCTAssertEqual(u.tiers.first { $0.name == "Monthly" }?.remaining, 70)
        XCTAssertNotNil(u.tiers.first?.reset_time)
        XCTAssertTrue(u.status_text.contains("4-hour 60%"), u.status_text)
        XCTAssertTrue(u.status_text.contains("Monthly 70%"), u.status_text)
    }

    func test_buildResult_monthly_only_is_primary() {
        let result = ChutesCollector.buildResult(
            .init(rolling: nil, monthly: .init(usedPercent: 20, resetsAt: nil), planName: nil))
        XCTAssertEqual(result.dataKind, .quota)
        XCTAssertEqual(result.usage.remaining, 80)
        XCTAssertEqual(result.usage.plan_type, "Chutes")
        XCTAssertTrue(result.usage.status_text.contains("Monthly 80%"), result.usage.status_text)
    }

    func test_buildResult_no_windows_is_statusOnly() {
        let result = ChutesCollector.buildResult(.init(rolling: nil, monthly: nil, planName: nil))
        XCTAssertEqual(result.dataKind, .statusOnly)
        XCTAssertEqual(result.usage.status_text, "Connected")
        XCTAssertNil(result.usage.remaining)
    }

    // MARK: - date helper

    func test_date_epoch_seconds_and_millis() {
        let sec = ChutesCollector.date(from: 1_893_456_000)
        let ms = ChutesCollector.date(from: 1_893_456_000_000)
        XCTAssertEqual(sec?.timeIntervalSince1970 ?? -1, 1_893_456_000, accuracy: 1)
        XCTAssertEqual(ms?.timeIntervalSince1970 ?? -1, 1_893_456_000, accuracy: 1)   // ms ÷1000
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .chutes, apiKey: "cpk-test")))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .chutes)))
    }
}
#endif
