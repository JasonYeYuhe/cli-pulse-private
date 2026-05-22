// Unit tests for the v1.23.0 Phase C-8 ManusCollector (CodexBar parity —
// first of the cookie batch). Locks the Gemini C-8 R1 adoptions:
// inferred Pro/Free plan_type (Q1), monthly-pool reset_time nil (Q2), the
// tightened session_id token extractor (MEDIUM — base64-padded bare token
// accepted, stray non-session pair rejected), and the proMonthly/periodic
// → .quota mapping with a refresh secondary tier. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ManusCollectorTests: XCTestCase {
    private let collector = ManusCollector()

    private func parse(_ json: String) throws -> ManusCollector.ManusCreditsResponse {
        try ManusCollector.parseResponse(Data(json.utf8))
    }

    // MARK: - Parsing

    func test_parse_lossy_double_number_string_int() throws {
        // proMonthly as number, periodic as string, maxRefresh as int.
        let r = try parse("""
        { "proMonthlyCredits": 1000.0, "periodicCredits": "600",
          "maxRefreshCredits": 100, "refreshCredits": 40,
          "totalCredits": 640, "freeCredits": 140 }
        """)
        XCTAssertEqual(r.proMonthlyCredits, 1000, accuracy: 0.001)
        XCTAssertEqual(r.periodicCredits, 600, accuracy: 0.001)
        XCTAssertEqual(r.maxRefreshCredits, 100, accuracy: 0.001)
        XCTAssertEqual(r.refreshCredits, 40, accuracy: 0.001)
        XCTAssertEqual(r.totalCredits, 640, accuracy: 0.001)
    }

    func test_parse_envelope_unwrap() throws {
        let r = try parse("""
        { "data": { "proMonthlyCredits": 500, "periodicCredits": 200,
                    "totalCredits": 200 } }
        """)
        XCTAssertEqual(r.proMonthlyCredits, 500, accuracy: 0.001)
        XCTAssertEqual(r.periodicCredits, 200, accuracy: 0.001)
    }

    func test_parse_rejects_error_and_empty_payloads() {
        XCTAssertThrowsError(try parse("not json"))
        XCTAssertThrowsError(try parse("{}"))                       // no credits keys
        XCTAssertThrowsError(try parse(#"{"error":"unauthorized"}"#)) // unrelated payload
    }

    func test_parse_nextRefreshTime_iso_string() throws {
        let r = try parse("""
        { "totalCredits": 10, "freeCredits": 10,
          "nextRefreshTime": "2025-06-15T13:46:40Z", "refreshInterval": "daily" }
        """)
        let date = try XCTUnwrap(r.nextRefreshTime)
        // Round-trip through the same formatter type to assert the instant
        // without hand-computing an epoch.
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2025-06-15T13:46:40Z")
        XCTAssertEqual(r.refreshInterval, "daily")
    }

    // MARK: - buildResult: monthly pro pool is the primary gauge

    func test_buildResult_monthly_primary() throws {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        let r = ManusCollector.ManusCreditsResponse(
            totalCredits: 640, freeCredits: 140, periodicCredits: 600,
            refreshCredits: 40, maxRefreshCredits: 100, proMonthlyCredits: 1000,
            nextRefreshTime: reset, refreshInterval: nil)
        let result = ManusCollector.buildResult(r)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 1000)
        XCTAssertEqual(u.remaining, 600)
        XCTAssertEqual(u.today_usage, 400)       // proMonthly − periodic (pragmatic UI mapping)
        XCTAssertEqual(u.week_usage, 400)
        XCTAssertEqual(u.plan_type, "Pro")        // proMonthly > 0
        XCTAssertNil(u.reset_time)                // monthly pool has no reset in payload
        XCTAssertEqual(u.metadata?.supports_quota, true)
        // tiers: Monthly (no reset) + Refresh (reset = nextRefreshTime)
        let monthly = try XCTUnwrap(u.tiers.first { $0.name == "Monthly" })
        XCTAssertEqual(monthly.quota, 1000)
        XCTAssertEqual(monthly.remaining, 600)
        XCTAssertNil(monthly.reset_time)
        let refresh = try XCTUnwrap(u.tiers.first { $0.name == "Refresh" })
        XCTAssertEqual(refresh.quota, 100)
        XCTAssertEqual(refresh.remaining, 40)
        let resetISO = try XCTUnwrap(refresh.reset_time)
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(resetISO)).timeIntervalSince1970,
                       1_750_000_000, accuracy: 1)
        XCTAssertTrue(u.status_text.contains("Balance: 640 credits"), u.status_text)
        XCTAssertTrue(u.status_text.contains("Refresh: 40/100"), u.status_text)
    }

    func test_buildResult_clamps_remaining_to_quota() {
        // periodic > proMonthly (defensive) ⇒ remaining capped, used 0.
        let r = ManusCollector.ManusCreditsResponse(
            totalCredits: 0, periodicCredits: 1500, proMonthlyCredits: 1000)
        let u = ManusCollector.buildResult(r).usage
        XCTAssertEqual(u.quota, 1000)
        XCTAssertEqual(u.remaining, 1000)
        XCTAssertEqual(u.today_usage, 0)
    }

    func test_buildResult_uses_refresh_interval_label() {
        let r = ManusCollector.ManusCreditsResponse(
            totalCredits: 50, refreshCredits: 30, maxRefreshCredits: 100,
            proMonthlyCredits: 200, refreshInterval: "hourly")
        let u = ManusCollector.buildResult(r).usage
        XCTAssertTrue(u.status_text.contains("Hourly: 30/100"), u.status_text)
    }

    // MARK: - buildResult: refresh-only and status-only fallbacks

    func test_buildResult_refresh_only_quota() throws {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        let r = ManusCollector.ManusCreditsResponse(
            totalCredits: 40, refreshCredits: 40, maxRefreshCredits: 100,
            proMonthlyCredits: 0, nextRefreshTime: reset)
        let result = ManusCollector.buildResult(r)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 40)
        XCTAssertEqual(u.plan_type, "Free")       // no monthly pool
        XCTAssertEqual(u.tiers.count, 1)
        XCTAssertEqual(u.tiers.first?.name, "Refresh")
        let resetISO = try XCTUnwrap(u.reset_time) // refresh reset IS the headline here
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(resetISO)).timeIntervalSince1970,
                       1_750_000_000, accuracy: 1)
    }

    func test_buildResult_status_only_when_no_pool() {
        let r = ManusCollector.ManusCreditsResponse(
            totalCredits: 500, maxRefreshCredits: 0, proMonthlyCredits: 0)
        let result = ManusCollector.buildResult(r)
        XCTAssertEqual(result.dataKind, .statusOnly)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertNil(u.remaining)
        XCTAssertEqual(u.plan_type, "Free")
        XCTAssertEqual(u.metadata?.supports_quota, false)
        XCTAssertTrue(u.status_text.contains("Balance: 500 credits"), u.status_text)
    }

    // MARK: - session_id token extraction

    func test_token_bare() {
        XCTAssertEqual(ManusCollector.sessionToken(fromCookieHeader: "abc123def"), "abc123def")
        XCTAssertEqual(ManusCollector.sessionToken(fromCookieHeader: "  abc123def  "), "abc123def")
    }

    func test_token_from_single_pair_and_case_insensitive() {
        XCTAssertEqual(ManusCollector.sessionToken(fromCookieHeader: "session_id=xyz"), "xyz")
        XCTAssertEqual(ManusCollector.sessionToken(fromCookieHeader: "SESSION_ID=xyz"), "xyz")
    }

    func test_token_from_full_cookie_header() {
        XCTAssertEqual(
            ManusCollector.sessionToken(fromCookieHeader: "_ga=GA1.2; session_id=xyz; cf_bm=zzz"),
            "xyz")
    }

    func test_token_value_containing_equals_survives() {
        // base64 value with internal '=' ⇒ split on first '=' only.
        XCTAssertEqual(ManusCollector.sessionToken(fromCookieHeader: "session_id=ab=cd"), "ab=cd")
    }

    func test_token_base64_padded_bare_token_accepted() {
        // Only trailing '=' padding, no ';' ⇒ recovered as a bare token.
        XCTAssertEqual(ManusCollector.sessionToken(fromCookieHeader: "QUJDREVGRw=="), "QUJDREVGRw==")
    }

    func test_token_rejects_stray_non_session_pair() {
        // Gemini C-8 R1 MEDIUM: a wrong single cookie must NOT be ingested.
        XCTAssertNil(ManusCollector.sessionToken(fromCookieHeader: "analytics_id=123"))
    }

    func test_token_rejects_header_without_session_id() {
        XCTAssertNil(ManusCollector.sessionToken(fromCookieHeader: "_ga=GA1.2; cf_bm=zzz"))
        XCTAssertNil(ManusCollector.sessionToken(fromCookieHeader: "   "))
        XCTAssertNil(ManusCollector.sessionToken(fromCookieHeader: ""))
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .manus)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .manus, manualCookieHeader: "session_id=abc")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .manus, cookieSource: .automatic)))
    }
}
#endif
