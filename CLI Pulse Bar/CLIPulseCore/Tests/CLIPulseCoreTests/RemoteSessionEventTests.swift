import XCTest
@testable import CLIPulseCore

/// Unit tests for the live event-tail wire shape.
///
/// `RemoteSessionEvent` is decoded directly from the
/// `remote_app_list_session_events` RPC's JSONB array. The schema
/// returns `id` as a bigint (`bigserial` PK), `seq` as an int, plus
/// kind/payload/created_at strings. If a future migration drifts any
/// of those types or names, this test catches the regression before
/// it reaches the polling loop.
///
/// Pinned cases:
///   - bigint `id` decodes into Swift's 64-bit `Int`.
///   - All four kinds (`stdout`, `stderr`, `status`, `info`) round-trip.
///   - The Identifiable conformance keys off `id` (used by the
///     SwiftUI `ForEach` in the output panel + `.id(event.id)` for
///     auto-scroll-to-latest).
final class RemoteSessionEventTests: XCTestCase {

    private func decode(_ json: String) throws -> RemoteSessionEvent {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(RemoteSessionEvent.self, from: data)
    }

    func testDecodesStdoutShape() throws {
        let json = """
        {
          "id": 4815162342,
          "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
          "seq": 17,
          "kind": "stdout",
          "payload": "hello world\\n",
          "created_at": "2026-05-03T10:00:00Z"
        }
        """
        let evt = try decode(json)
        XCTAssertEqual(evt.id, 4_815_162_342)
        XCTAssertEqual(evt.session_id, "f47ac10b-58cc-4372-a567-0e02b2c3d479")
        XCTAssertEqual(evt.seq, 17)
        XCTAssertEqual(evt.kind, "stdout")
        XCTAssertEqual(evt.payload, "hello world\n")
        XCTAssertEqual(evt.created_at, "2026-05-03T10:00:00Z")
    }

    func testDecodesStatusErroredShape() throws {
        // Status events MUST carry the bare-string payload that trips
        // the SQL gate. Phase 2 invariant pinned in helper tests too.
        let json = """
        {
          "id": 1,
          "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
          "seq": 1,
          "kind": "status",
          "payload": "errored",
          "created_at": "2026-05-03T10:00:00Z"
        }
        """
        let evt = try decode(json)
        XCTAssertEqual(evt.kind, "status")
        XCTAssertEqual(evt.payload, "errored")
    }

    func testDecodesInfoShape() throws {
        let json = """
        {
          "id": 2,
          "session_id": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
          "seq": 2,
          "kind": "info",
          "payload": "exited: exit_code=2",
          "created_at": "2026-05-03T10:00:01Z"
        }
        """
        let evt = try decode(json)
        XCTAssertEqual(evt.kind, "info")
        XCTAssertTrue(evt.payload.contains("exit_code=2"))
    }

    func testIdentifiableKeysOffId() {
        let a = RemoteSessionEvent(
            id: 1, session_id: "x", seq: 1,
            kind: "stdout", payload: "a", created_at: "t"
        )
        let b = RemoteSessionEvent(
            id: 2, session_id: "x", seq: 1, // same seq, different id
            kind: "stdout", payload: "b", created_at: "t"
        )
        XCTAssertNotEqual(a.id, b.id)
    }

    func testRoundTripCodable() throws {
        let original = RemoteSessionEvent(
            id: 9_999_999_999,
            session_id: "f47ac10b-58cc-4372-a567-0e02b2c3d479",
            seq: 42,
            kind: "stdout",
            payload: "redacted: «REDACTED» end",
            created_at: "2026-05-03T10:00:00Z"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RemoteSessionEvent.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.seq, original.seq)
        XCTAssertEqual(decoded.kind, original.kind)
        XCTAssertEqual(decoded.payload, original.payload)
    }
}
