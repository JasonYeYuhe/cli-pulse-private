// Unit tests for the v1.23.0 Phase C-16 StepFunCollector (CodexBar parity —
// cookie batch). Locks the design: Oasis-Token/Webid cookie extraction (NO
// password login), flexible int/float rate + string/int timestamp decode, and
// the `.quota` 5-hour + weekly percent windows (clamped 0...1). macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class StepFunCollectorTests: XCTestCase {
    private let collector = StepFunCollector()

    private func parseRate(_ json: String) throws -> StepFunCollector.Rate {
        try StepFunCollector.parseRateLimit(Data(json.utf8))
    }

    // MARK: - parseRateLimit (flexible decoders exercised via fixtures)

    func test_parseRateLimit_success_flexible_types() throws {
        // rate as float + int; timestamp as string + int.
        let r = try parseRate("""
        {"status":1,
         "five_hour_usage_left_rate":0.8,"weekly_usage_left_rate":1,
         "five_hour_usage_reset_time":"1777528800","weekly_usage_reset_time":1777600000}
        """)
        XCTAssertEqual(r.fiveHourLeftRate, 0.8, accuracy: 0.0001)
        XCTAssertEqual(r.weeklyLeftRate, 1.0, accuracy: 0.0001)
        XCTAssertEqual(r.fiveHourReset.timeIntervalSince1970, 1_777_528_800, accuracy: 1)
        XCTAssertEqual(r.weeklyReset.timeIntervalSince1970, 1_777_600_000, accuracy: 1)
    }

    func test_parseRateLimit_status_not_ok_throws() {
        XCTAssertThrowsError(try parseRate(#"{"status":0,"message":"nope"}"#)) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_parseRateLimit_missing_fields_throws() {
        XCTAssertThrowsError(try parseRate(#"{"status":1}"#)) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - parsePlanStatus

    func test_parsePlanStatus() throws {
        XCTAssertEqual(try StepFunCollector.parsePlanStatus(Data(#"{"subscription":{"name":"Pro"}}"#.utf8)), "Pro")
        XCTAssertNil(try StepFunCollector.parsePlanStatus(Data(#"{"status":1}"#.utf8)))
    }

    // MARK: - cookieTokens

    func test_cookieTokens_full_header() {
        let r = StepFunCollector.cookieTokens(
            fromHeader: "INGRESSCOOKIE=q; Oasis-Token=abc; Oasis-Webid=xyz")
        XCTAssertEqual(r.token, "abc")
        XCTAssertEqual(r.webid, "xyz")
    }

    func test_cookieTokens_bare_token_and_case_insensitive() {
        XCTAssertEqual(StepFunCollector.cookieTokens(fromHeader: "rawtok").token, "rawtok")
        XCTAssertEqual(StepFunCollector.cookieTokens(fromHeader: "oasis-token=abc").token, "abc")
    }

    func test_cookieTokens_no_token() {
        let r = StepFunCollector.cookieTokens(fromHeader: "INGRESSCOOKIE=q; other=1")
        XCTAssertNil(r.token)
        XCTAssertNil(r.webid)
    }

    // MARK: - buildResult

    func test_buildResult_quota_windows() throws {
        let rate = StepFunCollector.Rate(
            fiveHourLeftRate: 0.8, weeklyLeftRate: 1.0,
            fiveHourReset: Date(timeIntervalSince1970: 1_777_528_800),
            weeklyReset: Date(timeIntervalSince1970: 1_777_600_000))
        let result = StepFunCollector.buildResult(rate: rate, planName: "Pro")
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 80)          // headline = 5-hour window
        XCTAssertEqual(u.plan_type, "Pro")
        XCTAssertEqual(u.metadata?.supports_quota, true)
        XCTAssertEqual(u.status_text, "5h 80% left · Weekly 100% left")
        let fh = try XCTUnwrap(u.tiers.first { $0.name == "5-hour" })
        XCTAssertEqual(fh.remaining, 80)
        XCTAssertEqual(fh.windowMinutes, 300)
        let wk = try XCTUnwrap(u.tiers.first { $0.name == "Weekly" })
        XCTAssertEqual(wk.remaining, 100)
        XCTAssertEqual(wk.windowMinutes, 10080)
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(try XCTUnwrap(wk.reset_time))).timeIntervalSince1970,
                       1_777_600_000, accuracy: 1)
    }

    func test_buildResult_clamps_rate_out_of_range() {
        let rate = StepFunCollector.Rate(
            fiveHourLeftRate: 1.2, weeklyLeftRate: -0.1,   // API-glitch values
            fiveHourReset: Date(), weeklyReset: Date())
        let u = StepFunCollector.buildResult(rate: rate, planName: nil).usage
        XCTAssertEqual(u.remaining, 100)         // 1.2 clamped to 1.0 → 100%
        XCTAssertEqual(u.plan_type, "StepFun")   // nil plan fallback
        XCTAssertEqual(u.tiers.first { $0.name == "Weekly" }?.remaining, 0)  // -0.1 clamped to 0
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .stepfun)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .stepfun, manualCookieHeader: "Oasis-Token=x")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .stepfun, cookieSource: .automatic)))
    }
}
#endif
