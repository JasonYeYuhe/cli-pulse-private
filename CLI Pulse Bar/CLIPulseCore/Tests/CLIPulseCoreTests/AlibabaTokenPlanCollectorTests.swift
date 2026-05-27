// Unit tests for the v1.23.0 Phase C-20 AlibabaTokenPlanCollector (CodexBar
// parity). Console-internal API (unverifiable without a live token) — these
// lock the PORTED logic: sec_token HTML scrape, CSRF extraction, expandedJSON,
// the depth-limited defensive find over the verbatim key-sets, and the .quota
// mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class AlibabaTokenPlanCollectorTests: XCTestCase {
    private let collector = AlibabaTokenPlanCollector()

    private func parse(_ json: String) throws -> AlibabaTokenPlanCollector.Snapshot {
        try AlibabaTokenPlanCollector.parseUsage(Data(json.utf8))
    }

    // MARK: - sec_token + CSRF

    func test_extractSECToken_patterns() {
        XCTAssertEqual(AlibabaTokenPlanCollector.extractSECToken(from: #"x={"secToken":"TOK123"};"#), "TOK123")
        XCTAssertEqual(AlibabaTokenPlanCollector.extractSECToken(from: "var t=sec_token='ZZZ';"), "ZZZ")
        XCTAssertNil(AlibabaTokenPlanCollector.extractSECToken(from: "<html>no token here</html>"))
    }

    func test_csrf_extraction() {
        XCTAssertEqual(AlibabaTokenPlanCollector.csrf(from: "a=1; login_aliyunid_csrf=CSRF1; b=2"), "CSRF1")
        XCTAssertEqual(AlibabaTokenPlanCollector.csrf(from: "csrf=PLAIN"), "PLAIN")
        XCTAssertNil(AlibabaTokenPlanCollector.csrf(from: "a=1; b=2"))
    }

    // MARK: - expandedJSON (stringified sub-JSON)

    func test_parse_expands_stringified_subjson() throws {
        // "data" is a JSON *string* — expandedJSON must expand it so the find works.
        let s = try parse(##"{"data":"{\"tokenPlanInstanceInfo\":{\"totalQuota\":500,\"usedQuota\":100,\"planName\":\"Pro\"}}"}"##)
        XCTAssertEqual(s.total ?? -1, 500, accuracy: 0.001)
        XCTAssertEqual(s.used ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(s.planName, "Pro")
    }

    // MARK: - parseUsage (defensive find over key-sets)

    func test_parseUsage_nested_instance() throws {
        let s = try parse(#"""
        {"data":{"tokenPlanInstanceInfo":{"planName":"Teams","totalQuota":1000000,"usedQuota":250000,"nextRefreshTime":1777600000000}}}
        """#)
        XCTAssertEqual(s.planName, "Teams")
        XCTAssertEqual(s.total ?? -1, 1_000_000, accuracy: 0.001)
        XCTAssertEqual(s.used ?? -1, 250_000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(s.resetsAt).timeIntervalSince1970, 1_777_600_000, accuracy: 1)
    }

    func test_parseUsage_string_numbers_with_commas() throws {
        let s = try parse(#"{"d":{"quota":"1,000","balance":"250.5"}}"#)
        XCTAssertEqual(s.total ?? -1, 1000, accuracy: 0.001)
        XCTAssertEqual(s.remaining ?? -1, 250.5, accuracy: 0.001)
    }

    func test_parseUsage_error_payloads() {
        XCTAssertThrowsError(try parse(#"{"statusCode":403}"#)) {
            guard case CollectorError.missingCredentials = $0 else { return XCTFail("expected missingCredentials") }
        }
        XCTAssertThrowsError(try parse(#"{"code":"NeedLogin","message":"please log in"}"#)) {
            guard case CollectorError.missingCredentials = $0 else { return XCTFail("expected missingCredentials") }
        }
        XCTAssertThrowsError(try parse(#"{"data":{"foo":1}}"#)) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult

    func test_buildResult_quota() {
        let result = AlibabaTokenPlanCollector.buildResult(.init(
            planName: "Teams", used: 250_000, total: 1_000_000, remaining: nil, resetsAt: nil))
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 1_000_000)
        XCTAssertEqual(u.remaining, 750_000)   // total − used
        XCTAssertEqual(u.plan_type, "Teams")
        XCTAssertTrue(u.status_text.contains("250,000/1,000,000 credits used"), u.status_text)
    }

    func test_buildResult_status_only_when_no_total() {
        let result = AlibabaTokenPlanCollector.buildResult(.init(
            planName: nil, used: nil, total: nil, remaining: 500, resetsAt: nil))
        XCTAssertEqual(result.dataKind, .statusOnly)
        XCTAssertNil(result.usage.quota)
        XCTAssertEqual(result.usage.plan_type, "Token Plan")
        XCTAssertTrue(result.usage.status_text.contains("500 credits left"), result.usage.status_text)
    }

    // MARK: - v1.26 A3 — GetSubscriptionSummary endpoint shape

    /// New subscription-summary payload (CodexBar 3be413f). The `Data`
    /// envelope carries `TotalValue` / `TotalSurplusValue` / `TotalCount` /
    /// `NearestExpireDate`. `used` is derived from total - remaining.
    func test_parseUsage_subscriptionSummary_topLevelData() throws {
        let s = try parse(#"""
        {"Success":true,"Code":"200","Data":{"TotalCount":1,"TotalValue":1000,"TotalSurplusValue":875,"NearestExpireDate":1701000000000}}
        """#)
        XCTAssertEqual(s.planName, "TOKEN PLAN")
        XCTAssertEqual(s.total ?? -1, 1000, accuracy: 0.001)
        XCTAssertEqual(s.remaining ?? -1, 875, accuracy: 0.001)
        XCTAssertEqual(s.used ?? -1, 125, accuracy: 0.001) // derived total-remaining
        XCTAssertEqual(try XCTUnwrap(s.resetsAt).timeIntervalSince1970, 1_701_000_000, accuracy: 1)
    }

    /// Nested under `successResponse.body` — some cookie variants wrap.
    func test_parseUsage_subscriptionSummary_nestedSuccessResponseBody() throws {
        let body = #"{"success":true,"data":{"totalCount":1,"totalSurplusValue":750,"totalValue":1000}}"#
        let outer = ["successResponse": ["body": body]] as [String: Any]
        let data = try JSONSerialization.data(withJSONObject: outer)
        let s = try AlibabaTokenPlanCollector.parseUsage(data)
        XCTAssertEqual(s.planName, "TOKEN PLAN")
        XCTAssertEqual(s.total ?? -1, 1000, accuracy: 0.001)
        XCTAssertEqual(s.remaining ?? -1, 750, accuracy: 0.001)
        XCTAssertEqual(s.used ?? -1, 250, accuracy: 0.001)
    }

    /// Empty subscription — `TotalCount: 0`, no quota fields. Surfaces
    /// as status-only (no synthetic plan name).
    func test_parseUsage_emptySubscription_stayVisible_noQuotaWindow() throws {
        let s = try parse(#"{"Success":true,"Data":{"TotalCount":0}}"#)
        XCTAssertNil(s.planName)
        XCTAssertNil(s.total)
        XCTAssertNil(s.remaining)
    }

    /// `Success: false` (or `success: false`) — login-related messages map to
    /// `missingCredentials`, others to `parseFailed`.
    func test_throwIfError_unsuccessfulSummary_loginVsApiError() {
        XCTAssertThrowsError(try parse(#"{"Success":false,"Message":"needlogin"}"#)) {
            guard case CollectorError.missingCredentials = $0 else {
                return XCTFail("expected missingCredentials, got \($0)")
            }
        }
        XCTAssertThrowsError(try parse(#"{"success":false,"message":"Subscription lookup failed"}"#)) {
            guard case CollectorError.parseFailed = $0 else {
                return XCTFail("expected parseFailed, got \($0)")
            }
        }
    }

    /// Request body sanity — the new shape MUST carry product/action
    /// query params and a `{"ProductCode": "..."}` `params` value.
    func test_requestBody_carriesSubscriptionSummaryParams() {
        let bodyData = AlibabaTokenPlanCollector.requestBody(secToken: "TOK")
        let body = String(data: bodyData, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("product=BssOpenAPI-V3"), body)
        XCTAssertTrue(body.contains("action=GetSubscriptionSummary"), body)
        XCTAssertTrue(body.contains("ProductCode"), body)
        XCTAssertTrue(body.contains("sfm_tokenplanteams_dp_cn"), body)
        XCTAssertTrue(body.contains("sec_token=TOK"), body)
        // legacy shape NOT present
        XCTAssertFalse(body.contains("cornerstoneParam"), body)
        XCTAssertFalse(body.contains("queryTokenPlanInstanceInfoRequest"), body)
    }

    func test_requestBody_omitsSecTokenQueryWhenAbsent() {
        let body = String(data: AlibabaTokenPlanCollector.requestBody(secToken: nil), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("sec_token="), body)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .alibabaTokenPlan)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .alibabaTokenPlan, manualCookieHeader: "login_aliyunid_csrf=x")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .alibabaTokenPlan, cookieSource: .automatic)))
    }
}
#endif
