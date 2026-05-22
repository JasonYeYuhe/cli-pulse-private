// Unit tests for the v1.23.0 Phase C-9 AbacusCollector (CodexBar parity —
// cookie batch #2). Locks the Gemini C-9 R1 adoptions: tightened auth-error
// keyword detection (no false-positive on "model prediction session
// failed"), "Account" plan fallback, and the compute-points → .quota
// mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class AbacusCollectorTests: XCTestCase {
    private let collector = AbacusCollector()

    // MARK: - unwrapResult (envelope + auth detection)

    func test_unwrap_success_returns_result() throws {
        let data = Data(#"{"success":true,"result":{"totalComputePoints":50000,"computePointsLeft":12500}}"#.utf8)
        let result = try AbacusCollector.unwrapResult(data: data, status: 200)
        let cp = try AbacusCollector.parseComputePoints(result)
        XCTAssertEqual(cp.total, 50000, accuracy: 0.001)
        XCTAssertEqual(cp.left, 12500, accuracy: 0.001)
    }

    func test_unwrap_401_is_missingCredentials() {
        XCTAssertThrowsError(try AbacusCollector.unwrapResult(data: Data("{}".utf8), status: 401)) {
            guard case CollectorError.missingCredentials = $0 else {
                return XCTFail("expected missingCredentials, got \($0)")
            }
        }
    }

    func test_unwrap_500_is_httpError() {
        XCTAssertThrowsError(try AbacusCollector.unwrapResult(data: Data("{}".utf8), status: 500)) {
            guard case CollectorError.httpError = $0 else {
                return XCTFail("expected httpError, got \($0)")
            }
        }
    }

    func test_unwrap_auth_flavored_failure_is_missingCredentials() {
        let data = Data(#"{"success":false,"error":"Session expired, please log in again"}"#.utf8)
        XCTAssertThrowsError(try AbacusCollector.unwrapResult(data: data, status: 200)) {
            guard case CollectorError.missingCredentials = $0 else {
                return XCTFail("expected missingCredentials, got \($0)")
            }
        }
    }

    func test_unwrap_non_auth_failure_is_parseFailed() {
        let data = Data(#"{"success":false,"error":"internal compute error"}"#.utf8)
        XCTAssertThrowsError(try AbacusCollector.unwrapResult(data: data, status: 200)) {
            guard case CollectorError.parseFailed = $0 else {
                return XCTFail("expected parseFailed, got \($0)")
            }
        }
        XCTAssertThrowsError(try AbacusCollector.unwrapResult(data: Data("not json".utf8), status: 200)) {
            guard case CollectorError.parseFailed = $0 else {
                return XCTFail("expected parseFailed, got \($0)")
            }
        }
    }

    // MARK: - isAuthErrorMessage (tightened — Gemini R1 LOW)

    func test_isAuthErrorMessage_true_cases() {
        for m in ["Unauthorized", "user is unauthenticated", "403 Forbidden",
                  "Please log in", "session expired", "invalid session token"] {
            XCTAssertTrue(AbacusCollector.isAuthErrorMessage(m), m)
        }
    }

    func test_isAuthErrorMessage_false_cases() {
        // The false-positive Gemini flagged: a non-auth error containing "session".
        for m in ["model prediction session failed", "internal compute error",
                  "rate limited", "boom"] {
            XCTAssertFalse(AbacusCollector.isAuthErrorMessage(m), m)
        }
    }

    // MARK: - parseComputePoints

    func test_parseComputePoints_number_int_string() throws {
        let a = try AbacusCollector.parseComputePoints(["totalComputePoints": 100.0, "computePointsLeft": 40])
        XCTAssertEqual(a.total, 100, accuracy: 0.001)
        XCTAssertEqual(a.left, 40, accuracy: 0.001)
        let b = try AbacusCollector.parseComputePoints(["totalComputePoints": "250", "computePointsLeft": "0"])
        XCTAssertEqual(b.total, 250, accuracy: 0.001)
        XCTAssertEqual(b.left, 0, accuracy: 0.001)
    }

    func test_parseComputePoints_missing_field_throws() {
        XCTAssertThrowsError(try AbacusCollector.parseComputePoints(["totalComputePoints": 100])) {
            guard case CollectorError.parseFailed = $0 else {
                return XCTFail("expected parseFailed, got \($0)")
            }
        }
    }

    // MARK: - parseBilling

    func test_parseBilling_date_and_tier() throws {
        let b = AbacusCollector.parseBilling([
            "nextBillingDate": "2025-06-15T13:46:40Z", "currentTier": "enterprise"])
        let date = try XCTUnwrap(b.nextBillingDate)
        XCTAssertEqual(ISO8601DateFormatter().string(from: date), "2025-06-15T13:46:40Z")
        XCTAssertEqual(b.currentTier, "enterprise")
    }

    func test_parseBilling_absent_is_nil() {
        let b = AbacusCollector.parseBilling([:])
        XCTAssertNil(b.nextBillingDate)
        XCTAssertNil(b.currentTier)
    }

    // MARK: - buildResult

    func test_buildResult_quota_path() throws {
        let reset = Date(timeIntervalSince1970: 1_750_000_000)
        let result = AbacusCollector.buildResult(
            compute: .init(total: 50000, left: 12500),
            billing: .init(nextBillingDate: reset, currentTier: "enterprise"))
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 50000)
        XCTAssertEqual(u.remaining, 12500)
        XCTAssertEqual(u.today_usage, 37500)        // used = total − left
        XCTAssertEqual(u.plan_type, "Enterprise")   // capitalized
        XCTAssertEqual(u.metadata?.supports_quota, true)
        let tier = try XCTUnwrap(u.tiers.first { $0.name == "Compute Points" })
        XCTAssertEqual(tier.quota, 50000)
        XCTAssertEqual(tier.remaining, 12500)
        let resetISO = try XCTUnwrap(u.reset_time)
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(resetISO)).timeIntervalSince1970,
                       1_750_000_000, accuracy: 1)
        XCTAssertTrue(u.status_text.contains("12,500/50,000 compute points"), u.status_text)
    }

    func test_buildResult_plan_fallback_account_when_billing_nil() {
        let u = AbacusCollector.buildResult(
            compute: .init(total: 1000, left: 250), billing: nil).usage
        XCTAssertEqual(u.plan_type, "Account")
        XCTAssertNil(u.reset_time)
        XCTAssertEqual(u.remaining, 250)
    }

    func test_buildResult_clamps_left_to_total() {
        let u = AbacusCollector.buildResult(
            compute: .init(total: 1000, left: 5000), billing: nil).usage
        XCTAssertEqual(u.quota, 1000)
        XCTAssertEqual(u.remaining, 1000)   // clamped
        XCTAssertEqual(u.today_usage, 0)
    }

    func test_buildResult_status_only_when_no_cap() {
        let result = AbacusCollector.buildResult(
            compute: .init(total: 0, left: 0), billing: nil)
        XCTAssertEqual(result.dataKind, .statusOnly)
        XCTAssertNil(result.usage.quota)
        XCTAssertEqual(result.usage.metadata?.supports_quota, false)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .abacus)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .abacus, manualCookieHeader: "sessionid=abc")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .abacus, cookieSource: .automatic)))
    }
}
#endif
