// Unit tests for the v1.23.0 Phase C-21 WindsurfCollector (CodexBar parity —
// Connect protobuf). Unverifiable without a live Devin session, so these lock
// the PORTED protobuf codec (encode round-trip + nested-message decode), the
// session-bundle parse, and the `.quota` daily/weekly mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class WindsurfCollectorTests: XCTestCase {
    private let collector = WindsurfCollector()

    // MARK: - Protobuf codec

    func test_encodeRequest_roundtrip() throws {
        let bytes = WindsurfCollector.encodeRequest(authToken: "tok123", includeTopUpStatus: true)
        var reader = Proto.Reader(bytes)
        let f1 = try reader.next()
        XCTAssertEqual(f1?.number, 1); XCTAssertEqual(f1?.wire, .lengthDelimited)
        XCTAssertEqual(try reader.readString(), "tok123")
        let f2 = try reader.next()
        XCTAssertEqual(f2?.number, 2); XCTAssertEqual(f2?.wire, .varint)
        XCTAssertEqual(try reader.readVarint(), 1)
        XCTAssertNil(try reader.next())
    }

    /// Builds a GetPlanStatus protobuf response (PlanStatus nested in field 1).
    private func planStatusResponse(daily: Int, weekly: Int, planName: String, dailyReset: Int) -> Data {
        var planInfo = Data()
        Proto.appendKey(2, .lengthDelimited, &planInfo); Proto.appendString(planName, &planInfo)
        var inner = Data()
        Proto.appendKey(1, .lengthDelimited, &inner)        // planInfo (nested)
        Proto.appendVarint(UInt64(planInfo.count), &inner); inner.append(planInfo)
        Proto.appendKey(14, .varint, &inner); Proto.appendVarint(UInt64(daily), &inner)
        Proto.appendKey(15, .varint, &inner); Proto.appendVarint(UInt64(weekly), &inner)
        Proto.appendKey(17, .varint, &inner); Proto.appendVarint(UInt64(dailyReset), &inner)
        var resp = Data()
        Proto.appendKey(1, .lengthDelimited, &resp)         // PlanStatus (nested)
        Proto.appendVarint(UInt64(inner.count), &resp); resp.append(inner)
        return resp
    }

    func test_decodeResponse_nested_messages() throws {
        let data = planStatusResponse(daily: 80, weekly: 95, planName: "Pro", dailyReset: 1_777_600_000)
        let status = try XCTUnwrap(WindsurfCollector.decodeResponse(data))
        XCTAssertEqual(status.dailyRemainingPercent, 80)
        XCTAssertEqual(status.weeklyRemainingPercent, 95)
        XCTAssertEqual(status.planName, "Pro")             // decoded from nested planInfo
        XCTAssertEqual(status.dailyResetUnix, 1_777_600_000)
    }

    func test_decodeResponse_empty_is_nil_status() throws {
        XCTAssertNil(try WindsurfCollector.decodeResponse(Data()))
    }

    // MARK: - Session bundle parse

    func test_parseSessionBundle_snake_and_camel() {
        let snake = WindsurfCollector.parseSessionBundle(#"""
        {"devin_session_token":"s","devin_auth1_token":"a","devin_account_id":"acc","devin_primary_org_id":"org"}
        """#)
        XCTAssertEqual(snake?.sessionToken, "s")
        XCTAssertEqual(snake?.primaryOrgID, "org")
        let camel = WindsurfCollector.parseSessionBundle(#"""
        {"sessionToken":"s2","auth1Token":"a2","accountId":"acc2","primaryOrgId":"org2"}
        """#)
        XCTAssertEqual(camel?.sessionToken, "s2")
        XCTAssertNil(WindsurfCollector.parseSessionBundle(#"{"sessionToken":"s"}"#))   // missing fields
    }

    // MARK: - buildResult

    func test_buildResult_quota_windows() throws {
        let result = WindsurfCollector.buildResult(.init(
            planName: "Pro", dailyRemainingPercent: 80, weeklyRemainingPercent: 95,
            dailyResetUnix: 1_777_600_000, weeklyResetUnix: nil, planEndUnix: nil))
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 80)
        XCTAssertEqual(u.plan_type, "Pro")
        XCTAssertEqual(u.status_text, "Daily 80% left · Weekly 95% left")
        XCTAssertEqual(u.tiers.first { $0.name == "Daily" }?.remaining, 80)
        XCTAssertEqual(u.tiers.first { $0.name == "Weekly" }?.remaining, 95)
    }

    func test_buildResult_status_only_when_empty() {
        let result = WindsurfCollector.buildResult(.init(
            planName: nil, dailyRemainingPercent: nil, weeklyRemainingPercent: nil,
            dailyResetUnix: nil, weeklyResetUnix: nil, planEndUnix: nil))
        XCTAssertEqual(result.dataKind, .statusOnly)
        XCTAssertNil(result.usage.quota)
        XCTAssertEqual(result.usage.plan_type, "Windsurf")
    }

    // MARK: - Availability

    func test_isAvailable_with_bundle() {
        let bundle = #"{"sessionToken":"s","auth1Token":"a","accountId":"acc","primaryOrgId":"org"}"#
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .windsurf, manualCookieHeader: bundle)))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .windsurf)))
    }
}
#endif
