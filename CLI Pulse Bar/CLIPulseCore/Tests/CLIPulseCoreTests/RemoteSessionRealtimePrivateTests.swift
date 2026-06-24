import XCTest
@testable import CLIPulseCore

/// R0 (B3): `RemoteSession.realtime_private` decode + the `isRealtimePrivate`
/// resolution. The field is optional + nil-defaults-false so the model still
/// decodes pre-R0 `remote_app_list_sessions` responses during rollout (the key
/// is absent until migrate_v0.56 is applied). The client picks the
/// `pterm:`-private vs `term:`-public join from this — a mismatch is a silent
/// blackhole, so default-false MUST hold.
final class RemoteSessionRealtimePrivateTests: XCTestCase {

    private func decode(_ json: String) throws -> RemoteSession {
        try JSONDecoder().decode(RemoteSession.self, from: Data(json.utf8))
    }

    func test_absentField_defaultsToPublic() throws {
        // An old server (pre-migrate_v0.56) omits the key entirely.
        let s = try decode("""
        {"id":"a","device_id":"d","provider":"claude","cwd_basename":"x",
         "status":"running","created_at":"2026-06-24T00:00:00Z"}
        """)
        XCTAssertNil(s.realtime_private)
        XCTAssertFalse(s.isRealtimePrivate, "absent → public fallback")
    }

    func test_explicitTrue_isPrivate() throws {
        let s = try decode("""
        {"id":"a","device_id":"d","provider":"claude","cwd_basename":"x",
         "status":"running","created_at":"2026-06-24T00:00:00Z",
         "realtime_private":true}
        """)
        XCTAssertEqual(s.realtime_private, true)
        XCTAssertTrue(s.isRealtimePrivate)
    }

    func test_explicitFalse_isPublic() throws {
        let s = try decode("""
        {"id":"a","device_id":"d","provider":"claude","cwd_basename":"x",
         "status":"running","created_at":"2026-06-24T00:00:00Z",
         "realtime_private":false}
        """)
        XCTAssertEqual(s.realtime_private, false)
        XCTAssertFalse(s.isRealtimePrivate)
    }

    func test_initDefault_isPublic() {
        // Programmatic construction (e.g. demo data) defaults to public.
        let s = RemoteSession(
            id: "a", device_id: "d", provider: "claude",
            cwd_basename: "x", status: "running",
            created_at: "2026-06-24T00:00:00Z")
        XCTAssertFalse(s.isRealtimePrivate)
    }
}
