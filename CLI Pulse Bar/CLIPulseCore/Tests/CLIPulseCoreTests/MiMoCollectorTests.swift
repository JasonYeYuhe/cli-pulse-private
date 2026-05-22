// Unit tests for the v1.23.0 Phase C-18 MiMoCollector (CodexBar parity — last
// niche provider). Locks the design: required-cookie validation, code==0
// envelopes, lenient balance parse, and the hybrid `.quota` (token plan) /
// `.statusOnly` (balance) mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class MiMoCollectorTests: XCTestCase {
    private let collector = MiMoCollector()

    // MARK: - parseBalance

    func test_parseBalance_success() throws {
        let (b, c) = try MiMoCollector.parseBalance(Data(#"{"code":0,"data":{"balance":"12.50","currency":"CNY"}}"#.utf8))
        XCTAssertEqual(b ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(c, "CNY")
    }

    func test_parseBalance_non_numeric_is_nil() throws {
        let (b, c) = try MiMoCollector.parseBalance(Data(#"{"code":0,"data":{"balance":"--","currency":"CNY"}}"#.utf8))
        XCTAssertNil(b)            // lenient: don't drop the snapshot
        XCTAssertEqual(c, "CNY")
    }

    func test_parseBalance_auth_and_error_codes() {
        XCTAssertThrowsError(try MiMoCollector.parseBalance(Data(#"{"code":401}"#.utf8))) {
            guard case CollectorError.missingCredentials = $0 else { return XCTFail("expected missingCredentials") }
        }
        XCTAssertThrowsError(try MiMoCollector.parseBalance(Data(#"{"code":5}"#.utf8))) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
        XCTAssertThrowsError(try MiMoCollector.parseBalance(Data(#"{"code":0}"#.utf8))) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed (no data)") }
        }
    }

    // MARK: - parseDetail / parseUsage

    func test_parseDetail() throws {
        let (plan, end, expired) = try MiMoCollector.parseDetail(Data(#"""
        {"code":0,"data":{"planCode":"pro","currentPeriodEnd":"2026-06-01 00:00:00","expired":false}}
        """#.utf8))
        XCTAssertEqual(plan, "pro")
        XCTAssertNotNil(end)
        XCTAssertFalse(expired)
        // non-zero code ⇒ nils
        let nilResult = try MiMoCollector.parseDetail(Data(#"{"code":1}"#.utf8))
        XCTAssertNil(nilResult.planCode)
    }

    func test_parseUsage() throws {
        let (used, limit) = try MiMoCollector.parseUsage(Data(#"""
        {"code":0,"data":{"monthUsage":{"items":[{"used":300,"limit":1000}]}}}
        """#.utf8))
        XCTAssertEqual(used, 300)
        XCTAssertEqual(limit, 1000)
        let empty = try MiMoCollector.parseUsage(Data(#"{"code":0,"data":{"monthUsage":{"items":[]}}}"#.utf8))
        XCTAssertEqual(empty.used, 0)
        XCTAssertEqual(empty.limit, 0)
    }

    // MARK: - normalizedHeader

    func test_normalizedHeader_requires_both_cookies() {
        XCTAssertEqual(
            MiMoCollector.normalizedHeader(from: "userId=u123; api-platform_serviceToken=tok; junk=x"),
            "api-platform_serviceToken=tok; userId=u123")   // filtered + sorted
        XCTAssertNil(MiMoCollector.normalizedHeader(from: "userId=u123; junk=x"))  // missing serviceToken
    }

    // MARK: - buildResult

    func test_buildResult_token_plan_quota() {
        let result = MiMoCollector.buildResult(
            balance: 12.5, currency: "CNY", planCode: "pro",
            periodEnd: Date(timeIntervalSince1970: 1_780_272_000), expired: false, used: 300, limit: 1000)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 1000)
        XCTAssertEqual(u.remaining, 700)
        XCTAssertEqual(u.today_usage, 300)
        XCTAssertEqual(u.plan_type, "pro")
        XCTAssertNotNil(u.reset_time)
        XCTAssertEqual(u.status_text, "300/1,000 tokens · CNY 12.50")
        XCTAssertEqual(u.tiers.first?.name, "Token Plan")
    }

    func test_buildResult_expired_plan_status_only() {
        let result = MiMoCollector.buildResult(
            balance: 12.5, currency: "CNY", planCode: "pro",
            periodEnd: nil, expired: true, used: 300, limit: 1000)
        XCTAssertEqual(result.dataKind, .statusOnly)   // expired ⇒ no quota gauge
        XCTAssertNil(result.usage.quota)
        XCTAssertEqual(result.usage.status_text, "CNY 12.50 · plan expired")
    }

    func test_buildResult_no_plan_status_only_balance() {
        let u = MiMoCollector.buildResult(
            balance: 5, currency: "USD", planCode: nil,
            periodEnd: nil, expired: false, used: 0, limit: 0).usage
        XCTAssertEqual(u.plan_type, "MiMo")
        XCTAssertEqual(u.status_text, "USD 5.00 balance")
    }

    func test_buildResult_nil_balance() {
        let u = MiMoCollector.buildResult(
            balance: nil, currency: "CNY", planCode: nil,
            periodEnd: nil, expired: false, used: 0, limit: 0).usage
        XCTAssertEqual(u.status_text, "balance unavailable balance")
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .mimo)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .mimo, manualCookieHeader: "api-platform_serviceToken=t; userId=u")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .mimo, cookieSource: .automatic)))
    }
}
#endif
