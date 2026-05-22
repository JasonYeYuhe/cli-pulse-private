// Unit tests for the v1.23.0 Phase C-11 CommandCodeCollector (CodexBar parity
// — last of the cookie batch). Locks the Gemini C-11 R1 design: best-effort
// subscription / degrade-not-throw on unknown plan, $1=100_000-unit `.credits`,
// monthly-grant cap from the plan catalog + 3 balance pools as tiers, all pools
// clamped >= 0, clean better-auth Cookie header. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CommandCodeCollectorTests: XCTestCase {
    private let collector = CommandCodeCollector()

    // MARK: - cookieHeaderValue

    func test_cookie_bare_token_assumes_secure_name() {
        XCTAssertEqual(
            CommandCodeCollector.cookieHeaderValue(from: "rawtoken123"),
            "__Secure-better-auth.session_token=rawtoken123")
    }

    func test_cookie_extracts_from_full_header_prefers_secure() {
        // both __Secure- and bare present ⇒ __Secure- wins (catalog order).
        let h = "_ga=1; better-auth.session_token=bare; __Secure-better-auth.session_token=sec; x=2"
        XCTAssertEqual(
            CommandCodeCollector.cookieHeaderValue(from: h),
            "__Secure-better-auth.session_token=sec")
    }

    func test_cookie_bare_named_cookie_and_case_insensitive() {
        XCTAssertEqual(
            CommandCodeCollector.cookieHeaderValue(from: "better-auth.session_token=v1"),
            "better-auth.session_token=v1")
        // case-insensitive name match, original casing preserved in output.
        XCTAssertEqual(
            CommandCodeCollector.cookieHeaderValue(from: "Better-Auth.Session_Token=v2"),
            "Better-Auth.Session_Token=v2")
    }

    func test_cookie_no_session_cookie_is_nil() {
        XCTAssertNil(CommandCodeCollector.cookieHeaderValue(from: "_ga=1; other=2"))
        XCTAssertNil(CommandCodeCollector.cookieHeaderValue(from: "   "))
    }

    // MARK: - parseCredits

    func test_parseCredits_nested_and_clamps_negatives() throws {
        let c = try CommandCodeCollector.parseCredits(Data(#"""
        {"credits":{"monthlyCredits":12.5,"purchasedCredits":5,"premiumMonthlyCredits":-3,"opensourceMonthlyCredits":"2"}}
        """#.utf8))
        XCTAssertEqual(c.monthly, 12.5, accuracy: 0.001)
        XCTAssertEqual(c.purchased, 5, accuracy: 0.001)
        XCTAssertEqual(c.premium, 0, accuracy: 0.001)     // negative clamped
        XCTAssertEqual(c.opensource, 2, accuracy: 0.001)  // string tolerated
    }

    func test_parseCredits_missing_object_or_field_throws() {
        XCTAssertThrowsError(try CommandCodeCollector.parseCredits(Data("{}".utf8)))
        XCTAssertThrowsError(try CommandCodeCollector.parseCredits(Data(#"{"credits":{}}"#.utf8)))
    }

    // MARK: - parseSubscription

    func test_parseSubscription_active() throws {
        let s = try CommandCodeCollector.parseSubscription(Data(#"""
        {"success":true,"data":{"planId":"individual-pro","status":"active","currentPeriodEnd":"2025-06-15T13:46:40Z"}}
        """#.utf8))
        let sub = try XCTUnwrap(s)
        XCTAssertEqual(sub.planID, "individual-pro")
        XCTAssertEqual(sub.status, "active")
        XCTAssertEqual(ISO8601DateFormatter().string(from: try XCTUnwrap(sub.currentPeriodEnd)),
                       "2025-06-15T13:46:40Z")
    }

    func test_parseSubscription_free_tier_is_nil() throws {
        XCTAssertNil(try CommandCodeCollector.parseSubscription(Data(#"{"success":false}"#.utf8)))
        XCTAssertNil(try CommandCodeCollector.parseSubscription(Data(#"{"success":true}"#.utf8)))
        XCTAssertNil(try CommandCodeCollector.parseSubscription(
            Data(#"{"success":true,"data":{"status":"active"}}"#.utf8)))   // no planId
    }

    // MARK: - planForID

    func test_planForID_lookup() {
        XCTAssertEqual(CommandCodeCollector.planForID("individual-pro")?.displayName, "Pro")
        XCTAssertEqual(CommandCodeCollector.planForID("INDIVIDUAL-MAX")?.monthlyCreditsUSD, 150)
        XCTAssertEqual(CommandCodeCollector.planForID("  individual-ultra  ")?.displayName, "Ultra")
        XCTAssertNil(CommandCodeCollector.planForID("enterprise-unknown"))
    }

    // MARK: - buildResult

    func test_buildResult_plan_known_quota_and_pools() throws {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        let result = CommandCodeCollector.buildResult(
            credits: .init(monthly: 12, purchased: 5, premium: 0, opensource: 0),
            plan: .init(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
            periodEnd: reset)
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        XCTAssertEqual(u.quota, 3_000_000)          // $30 × 100_000
        XCTAssertEqual(u.remaining, 1_200_000)      // $12
        XCTAssertEqual(u.estimated_cost_week, 18, accuracy: 0.001)  // used $18
        XCTAssertEqual(u.cost_status_week, "Exact")
        XCTAssertEqual(u.plan_type, "Pro")
        XCTAssertEqual(u.metadata?.supports_exact_cost, true)
        XCTAssertTrue(u.status_text.contains("Pro · $18.00 of $30.00"), u.status_text)
        XCTAssertEqual(u.tiers.first { $0.name == "Monthly" }?.remaining, 1_200_000)
        let purchased = try XCTUnwrap(u.tiers.first { $0.name == "Purchased" })
        XCTAssertEqual(purchased.quota, 500_000)    // $5
        XCTAssertEqual(purchased.remaining, 500_000)
        let resetISO = try XCTUnwrap(u.reset_time)
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(resetISO)).timeIntervalSince1970,
                       1_750_000_000, accuracy: 1)
    }

    func test_buildResult_clamps_remaining_to_cap() {
        let u = CommandCodeCollector.buildResult(
            credits: .init(monthly: 50, purchased: 0, premium: 0, opensource: 0),
            plan: .init(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
            periodEnd: nil).usage
        XCTAssertEqual(u.remaining, 3_000_000)       // clamped to cap $30
        XCTAssertEqual(u.estimated_cost_week, 0, accuracy: 0.001)
    }

    func test_buildResult_free_tier_uncapped_balance() {
        let result = CommandCodeCollector.buildResult(
            credits: .init(monthly: 3, purchased: 7, premium: 0, opensource: 1),
            plan: nil, periodEnd: nil)
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        XCTAssertNil(u.quota)                         // uncapped
        XCTAssertEqual(u.remaining, 1_100_000)        // ($3+$7+$1) × 100_000
        XCTAssertEqual(u.plan_type, "Free")
        XCTAssertTrue(u.status_text.contains("$11.00 remaining"), u.status_text)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .commandCode)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .commandCode, manualCookieHeader: "better-auth.session_token=x")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .commandCode, cookieSource: .automatic)))
    }
}
#endif
