// Unit tests for the v1.23.0 Phase C-1 CrofCollector (new api-key
// provider; first Phase-C stub-absent provider). Covers the vendored
// response decode, the .quota mapping, the injectable
// next-Chicago-midnight reset (Gemini C-1 R1 MEDIUM), and the new
// ProviderKind.crof case. macOS-gated like the other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CrofCollectorTests: XCTestCase {
    private let collector = CrofCollector()

    private func decode(_ json: String) throws -> CrofCollector.CrofUsageResponse {
        try CrofCollector.parseResponse(Data(json.utf8))
    }

    // MARK: - Parse

    func test_parseResponse_snake_case() throws {
        let r = try decode(#"{"credits": 12.5, "requests_plan": 100, "usable_requests": 37}"#)
        XCTAssertEqual(r.credits, 12.5, accuracy: 0.001)
        XCTAssertEqual(r.requestsPlan, 100, accuracy: 0.001)
        XCTAssertEqual(r.usableRequests, 37, accuracy: 0.001)
    }

    func test_parseResponse_invalid_throws() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{}"))  // missing required keys
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .crof)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .crof, apiKey: "sk-crof-test")))
        XCTAssertFalse(collector.isAvailable(
            config: ProviderConfig(kind: .crof, apiKey: "   ")))  // blank trimmed
    }

    // MARK: - buildResult (.quota)

    func test_buildResult_quota_mapping() throws {
        let r = try decode(#"{"credits": 12.5, "requests_plan": 100, "usable_requests": 37}"#)
        let res = collector.buildResult(r, now: Date(timeIntervalSince1970: 1_750_000_000))
        XCTAssertEqual(res.dataKind, .quota)
        let u = res.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 37)
        XCTAssertEqual(u.today_usage, 63)
        XCTAssertEqual(u.plan_type, "API key")
        XCTAssertEqual(u.tiers.first?.name, "Requests")
        XCTAssertEqual(u.tiers.first?.quota, 100)
        XCTAssertEqual(u.tiers.first?.remaining, 37)
        XCTAssertTrue(u.status_text.contains("$12.50 credits"))
        XCTAssertTrue(u.status_text.contains("37 requests left"))
    }

    func test_buildResult_clamps_usable_over_plan() throws {
        let r = try decode(#"{"credits": 0, "requests_plan": 100, "usable_requests": 150}"#)
        let u = collector.buildResult(r).usage
        XCTAssertEqual(u.remaining, 100)   // clamped to plan
        XCTAssertEqual(u.today_usage, 0)
    }

    func test_buildResult_zero_plan() throws {
        let r = try decode(#"{"credits": 5, "requests_plan": 0, "usable_requests": 0}"#)
        let u = collector.buildResult(r).usage
        XCTAssertNil(u.quota)
        XCTAssertTrue(u.tiers.isEmpty)
        XCTAssertEqual(u.remaining, 0)
    }

    // MARK: - next reset (injectable now — Gemini C-1 R1 MEDIUM)

    func test_nextRequestReset_is_next_chicago_midnight() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let reset = CrofCollector.nextRequestReset(after: now)
        XCTAssertGreaterThan(reset, now)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Chicago")!
        let c = cal.dateComponents([.hour, .minute, .second], from: reset)
        XCTAssertEqual(c.hour, 0)
        XCTAssertEqual(c.minute, 0)
        XCTAssertEqual(c.second, 0)
        // First Chicago-midnight strictly after `now` ⇒ within ~25h (DST slack).
        XCTAssertLessThanOrEqual(reset.timeIntervalSince(now), 25 * 3600)
    }

    // MARK: - New ProviderKind case

    func test_providerKind_crof_case() {
        XCTAssertEqual(ProviderKind(rawValue: "Crof"), .crof)
        XCTAssertEqual(ProviderKind.crof.rawValue, "Crof")
        XCTAssertEqual(ProviderKind.crof.iconName, "c.circle")
        XCTAssertTrue(ProviderKind.allCases.contains(.crof))
        XCTAssertEqual(collector.kind, .crof)
    }
}
#endif
