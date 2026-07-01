import XCTest
@testable import CLIPulseCore

/// v0.60: DeviceRecord carries the per-provider managed-session plan map
/// (provider_plan_status) so mobile can warn before an off-plan managed session.
final class DeviceRecordPlanStatusTests: XCTestCase {

    private func decode(_ json: String) throws -> DeviceRecord {
        try JSONDecoder().decode(DeviceRecord.self, from: Data(json.utf8))
    }

    func testDecodesProviderPlanStatusWhenPresent() throws {
        let d = try decode("""
        {"id":"a","name":"Mac","type":"Mac","system":"macOS","status":"Online",
         "helper_version":"1.23.0","current_session_count":0,
         "providerPlanStatus":{"codex":"off_plan","claude":"on_plan"}}
        """)
        XCTAssertEqual(d.providerPlanStatus["codex"], "off_plan")
        XCTAssertTrue(d.isProviderOffPlan("codex"))
        XCTAssertFalse(d.isProviderOffPlan("claude"))   // on_plan => not off-plan
    }

    func testDefaultsToEmptyWhenKeyAbsent() throws {
        // Older/foreign persisted JSON without the key must still decode.
        let d = try decode("""
        {"id":"a","name":"Mac","type":"Mac","system":"macOS","status":"Online",
         "helper_version":"1.20.0","current_session_count":0}
        """)
        XCTAssertTrue(d.providerPlanStatus.isEmpty)
        XCTAssertFalse(d.isProviderOffPlan("codex"))    // absent => no warning
    }

    func testMemberwiseInitDefaultsEmpty() {
        let d = DeviceRecord(
            id: "a", name: "Mac", type: "Mac", system: "macOS", status: "Online",
            last_sync_at: nil, helper_version: "1.23.0",
            current_session_count: 0, cpu_usage: nil, memory_usage: nil
        )
        XCTAssertTrue(d.providerPlanStatus.isEmpty)
    }

    func testRoundTripEncodeDecode() throws {
        let d = DeviceRecord(
            id: "a", name: "Mac", type: "Mac", system: "macOS", status: "Online",
            last_sync_at: nil, helper_version: "1.23.0",
            current_session_count: 0, cpu_usage: 1, memory_usage: 2,
            providerPlanStatus: ["codex": "off_plan"]
        )
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(DeviceRecord.self, from: data)
        XCTAssertEqual(back.providerPlanStatus, ["codex": "off_plan"])
        XCTAssertTrue(back.isProviderOffPlan("codex"))
    }
}
