// Unit tests for the v1.23.0 Phase C-17 T3ChatCollector (CodexBar parity —
// cookie batch). Locks the design: JSONL recursive customerData find/decode,
// ms-epoch resets, plan-name title-casing, and the `.quota` 4-hour + month
// percent windows (remaining = 100 − used). macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class T3ChatCollectorTests: XCTestCase {
    private let collector = T3ChatCollector()

    private func parse(_ text: String) throws -> T3ChatCollector.CustomerData {
        try T3ChatCollector.parseJSONLines(text: text)
    }

    // MARK: - parseJSONLines (recursive customerData finder)

    func test_parse_finds_nested_customerData() throws {
        // tRPC-batch-style nesting: customerData buried under result/data.
        // JSONL ⇒ each object must be on ONE line.
        let c = try parse(#"{"0":{"result":{"data":{"usageFourHourPercentage":20,"usageMonthPercentage":50,"usageBand":"normal","usageFourHourNextResetAt":1777528800000,"subscription":{"productName":"pro-plan","currentPeriodEnd":1777600000000}}}}}"#)
        XCTAssertEqual(c.usageFourHourPercentage ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(c.usageMonthPercentage ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(c.usageBand, "normal")
        XCTAssertEqual(c.planName, "Pro Plan")    // "pro-plan" title-cased
    }

    func test_parse_multiline_skips_non_customer_lines() throws {
        let c = try parse("""
        {"meta":{"unrelated":true}}
        {"data":{"usageFourHourPercentage":10,"usageFourHourNextResetAt":1777528800000}}
        """)
        XCTAssertEqual(c.usageFourHourPercentage ?? -1, 10, accuracy: 0.001)
    }

    func test_parse_missing_customerData_throws() {
        XCTAssertThrowsError(try parse(#"{"foo":1}"#)) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_planName_fallback_to_subTier() throws {
        let c = try parse(#"{"d":{"usageMonthPercentage":5,"subTier":"big-pro","usageBand":"x","subscription":null}}"#)
        XCTAssertEqual(c.planName, "Big Pro")
    }

    // MARK: - date(fromMilliseconds:)

    func test_date_from_milliseconds() {
        let d = T3ChatCollector.date(fromMilliseconds: 1_777_528_800_000)   // JS ms
        XCTAssertEqual(try XCTUnwrap(d).timeIntervalSince1970, 1_777_528_800, accuracy: 1)
        XCTAssertNil(T3ChatCollector.date(fromMilliseconds: 0))
        XCTAssertNil(T3ChatCollector.date(fromMilliseconds: nil))
    }

    // MARK: - buildResult (.quota windows; remaining = 100 − used)

    func test_buildResult_windows() throws {
        let c = try parse(#"{"d":{"usageFourHourPercentage":20,"usageMonthPercentage":50,"usageBand":"normal","usageFourHourNextResetAt":1777528800000,"subscription":{"productName":"pro-plan","currentPeriodEnd":1777600000000}}}"#)
        let result = T3ChatCollector.buildResult(c)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 80)        // 100 − 20 used (4-hour headline)
        XCTAssertEqual(u.plan_type, "Pro Plan")
        XCTAssertEqual(u.metadata?.supports_quota, true)
        XCTAssertEqual(u.status_text, "4h 80% left · Month 50% left · normal")
        let fh = try XCTUnwrap(u.tiers.first { $0.name == "4-hour" })
        XCTAssertEqual(fh.remaining, 80)
        XCTAssertEqual(fh.windowMinutes, 240)
        XCTAssertEqual(u.tiers.first { $0.name == "Monthly" }?.remaining, 50)
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(try XCTUnwrap(fh.reset_time))).timeIntervalSince1970,
                       1_777_528_800, accuracy: 1)
    }

    func test_buildResult_clamps_over_100() throws {
        let c = try parse(#"{"d":{"usageFourHourPercentage":150,"usageMonthPercentage":-10,"usageBand":"x","subscription":null}}"#)
        let u = T3ChatCollector.buildResult(c).usage
        XCTAssertEqual(u.remaining, 0)         // 150 used clamped → 0 left
        XCTAssertEqual(u.tiers.first { $0.name == "Monthly" }?.remaining, 100)  // -10 clamped → 100 left
        XCTAssertEqual(u.plan_type, "T3 Chat") // no plan name
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .t3chat)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .t3chat, manualCookieHeader: "session=x")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .t3chat, cookieSource: .automatic)))
    }
}
#endif
