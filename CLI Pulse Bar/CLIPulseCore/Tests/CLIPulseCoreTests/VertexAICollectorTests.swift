// Unit tests for the v1.23.0 Phase B-2 VertexAICollector (CodexBar
// stub → real gcloud-ADC .quota collector). Covers the vendored
// credential parse, service-account detection (deferred), project-id
// INI, id_token email, token-refresh parse, Cloud-Monitoring
// aggregate/maxPercent, needsRefresh, and the .quota mapping.
// macOS-gated like the other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class VertexAICollectorTests: XCTestCase {
    private let collector = VertexAICollector()

    // MARK: - Credential parse

    func test_parseUserCredentials_valid() throws {
        let json = try JSONSerialization.jsonObject(with: Data("""
        {"client_id":"cid","client_secret":"sec","refresh_token":"rt",
         "access_token":"at","token_expiry":"2030-01-01T00:00:00Z"}
        """.utf8)) as! [String: Any]
        let c = try VertexAICollector.parseUserCredentials(json: json, env: [:])
        XCTAssertEqual(c.clientId, "cid")
        XCTAssertEqual(c.clientSecret, "sec")
        XCTAssertEqual(c.refreshToken, "rt")
        XCTAssertEqual(c.accessToken, "at")
        XCTAssertNotNil(c.expiryDate)
    }

    func test_parseUserCredentials_missing_fields_throw() throws {
        let noClient = try JSONSerialization.jsonObject(with: Data(
            "{\"refresh_token\":\"rt\"}".utf8)) as! [String: Any]
        XCTAssertThrowsError(try VertexAICollector.parseUserCredentials(json: noClient, env: [:]))
        let noRefresh = try JSONSerialization.jsonObject(with: Data(
            "{\"client_id\":\"c\",\"client_secret\":\"s\"}".utf8)) as! [String: Any]
        XCTAssertThrowsError(try VertexAICollector.parseUserCredentials(json: noRefresh, env: [:]))
    }

    func test_isServiceAccount() throws {
        let sa = try JSONSerialization.jsonObject(with: Data("""
        {"client_email":"svc@proj.iam.gserviceaccount.com","private_key":"-----BEGIN-----"}
        """.utf8)) as! [String: Any]
        XCTAssertTrue(VertexAICollector.isServiceAccount(sa))
        let user = try JSONSerialization.jsonObject(with: Data(
            "{\"client_id\":\"c\",\"refresh_token\":\"r\"}".utf8)) as! [String: Any]
        XCTAssertFalse(VertexAICollector.isServiceAccount(user))
    }

    // MARK: - Project id INI

    func test_parseProjectIdINI() {
        XCTAssertEqual(
            VertexAICollector.parseProjectIdINI("[core]\naccount = me@x.com\nproject = my-proj-123\n"),
            "my-proj-123")
        XCTAssertNil(VertexAICollector.parseProjectIdINI("[core]\naccount = me@x.com\n"))
    }

    // MARK: - id_token email (base64url)

    func test_extractEmailFromIdToken() {
        let payload = Data(#"{"email":"a@b.com","sub":"1"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(
            VertexAICollector.extractEmailFromIdToken("header.\(payload).sig"), "a@b.com")
        XCTAssertNil(VertexAICollector.extractEmailFromIdToken(nil))
        XCTAssertNil(VertexAICollector.extractEmailFromIdToken("garbage"))
    }

    // MARK: - Refresh-response parse

    func test_parseRefreshResponse() throws {
        let base = VertexAICollector.Creds(
            accessToken: "old", refreshToken: "rt", clientId: "c", clientSecret: "s",
            projectId: "p", email: "old@x.com", expiryDate: nil)
        let data = Data(#"{"access_token":"new","expires_in":3600}"#.utf8)
        let c = try VertexAICollector.parseRefreshResponse(data, fallback: base)
        XCTAssertEqual(c.accessToken, "new")
        XCTAssertEqual(c.refreshToken, "rt")          // preserved
        XCTAssertEqual(c.email, "old@x.com")          // preserved (no id_token)
        let expiry = try XCTUnwrap(c.expiryDate)
        XCTAssertEqual(expiry.timeIntervalSinceNow, 3600, accuracy: 5)

        // Missing access_token ⇒ falls back to the old token.
        let c2 = try VertexAICollector.parseRefreshResponse(Data("{}".utf8), fallback: base)
        XCTAssertEqual(c2.accessToken, "old")
    }

    // MARK: - needsRefresh

    func test_needsRefresh() {
        func creds(_ d: Date?) -> VertexAICollector.Creds {
            .init(accessToken: "a", refreshToken: "r", clientId: "c",
                  clientSecret: "s", projectId: "p", email: nil, expiryDate: d)
        }
        XCTAssertTrue(creds(nil).needsRefresh)
        XCTAssertTrue(creds(Date().addingTimeInterval(120)).needsRefresh)   // <5min
        XCTAssertFalse(creds(Date().addingTimeInterval(3600)).needsRefresh) // >5min
    }

    // MARK: - Monitoring aggregate + maxPercent

    func test_aggregate_and_maxPercent() throws {
        // Two quota keys; usage 30/100 and 80/100 ⇒ max 80%.
        func series(_ qm: String, _ val: Double) -> String {
            """
            {"metric":{"labels":{"quota_metric":"\(qm)","limit_name":"L"}},
             "resource":{"labels":{"location":"global"}},
             "points":[{"value":{"doubleValue":\(val)}}]}
            """
        }
        let usageJSON = "{\"timeSeries\":[\(series("m.a", 30)),\(series("m.b", 80))]}"
        let limitJSON = "{\"timeSeries\":[\(series("m.a", 100)),\(series("m.b", 100))]}"
        let usage = VertexAICollector.aggregate(
            try VertexAICollector.parseTimeSeries(Data(usageJSON.utf8)))
        let limit = VertexAICollector.aggregate(
            try VertexAICollector.parseTimeSeries(Data(limitJSON.utf8)))
        XCTAssertEqual(usage.count, 2)
        let pct = try XCTUnwrap(VertexAICollector.maxPercent(usage: usage, limit: limit))
        XCTAssertEqual(pct, 80, accuracy: 0.001)
    }

    func test_maxPercent_nil_when_no_match() {
        XCTAssertNil(VertexAICollector.maxPercent(
            usage: [.init(metric: "x", limit: "", location: "g"): 5],
            limit: [.init(metric: "y", limit: "", location: "g"): 10]))
    }

    // MARK: - buildResult

    func test_buildResult_quota_mapping() {
        let r = collector.buildResult(usedPercent: 42.7, email: "u@v.com")
        XCTAssertEqual(r.dataKind, .quota)
        XCTAssertEqual(r.usage.quota, 100)
        XCTAssertEqual(r.usage.remaining, 57)   // 100 - round(42.7)=43
        XCTAssertEqual(r.usage.plan_type, "u@v.com")
        XCTAssertNil(r.usage.reset_time)
        XCTAssertEqual(r.usage.tiers.first?.name, "Requests")
    }
}
#endif
