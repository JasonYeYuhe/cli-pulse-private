import XCTest
@testable import CLIPulseCore

/// v1.22 P0 — wire shape + attention model for Swarm View.
///
/// `RemoteSwarmDevice` decodes directly from the
/// `remote_app_list_swarms` RPC jsonb array. The project's
/// `JSONDecoder()` has NO keyDecodingStrategy, so the struct's
/// verbatim snake_case property names must match the SQL/helper keys
/// exactly — that's the contract these tests pin.
final class RemoteSwarmTests: XCTestCase {

    private func decode(_ json: String) throws -> RemoteSwarmDevice {
        try JSONDecoder().decode(RemoteSwarmDevice.self, from: Data(json.utf8))
    }

    func testDecodesDeviceAndSwarmShape() throws {
        let json = """
        {
          "device_id": "d1d1d1d1-0000-0000-0000-000000000000",
          "updated_at": "2026-05-17T10:00:00Z",
          "age_s": 12.5,
          "stale": false,
          "swarms": [
            {
              "swarm_key": "aabbccddeeff",
              "handle": "swarm-aabbcc",
              "is_linked_worktree": true,
              "providers": ["claude", "aider"],
              "agents": 3,
              "blocked": 1,
              "oldest_blocked_age_s": 42.0,
              "last_seen_s_ago": 5.3
            }
          ]
        }
        """
        let d = try decode(json)
        XCTAssertEqual(d.device_id, "d1d1d1d1-0000-0000-0000-000000000000")
        XCTAssertFalse(d.stale)
        XCTAssertEqual(d.id, d.device_id)               // Identifiable
        XCTAssertEqual(d.swarms.count, 1)
        let s = d.swarms[0]
        XCTAssertEqual(s.swarm_key, "aabbccddeeff")
        XCTAssertEqual(s.handle, "swarm-aabbcc")
        XCTAssertTrue(s.is_linked_worktree)
        XCTAssertEqual(s.providers, ["claude", "aider"])
        XCTAssertEqual(s.agents, 3)
        XCTAssertEqual(s.blocked, 1)
        XCTAssertEqual(s.oldest_blocked_age_s, 42.0, accuracy: 0.001)
        XCTAssertEqual(s.id, s.swarm_key)               // Identifiable
    }

    func testDecodesEmptyDeviceArrayShape() throws {
        // `remote_app_list_swarms` returns `[]` when RC is off / no swarms.
        let arr = try JSONDecoder().decode(
            [RemoteSwarmDevice].self, from: Data("[]".utf8)
        )
        XCTAssertTrue(arr.isEmpty)
    }

    func testStaleDeviceDecodes() throws {
        let json = """
        { "device_id": "x", "updated_at": "t", "age_s": 305.0,
          "stale": true, "swarms": [] }
        """
        let d = try decode(json)
        XCTAssertTrue(d.stale)
        XCTAssertTrue(d.swarms.isEmpty)
    }

    /// Pin the compact age formatter the grids + Live Activity use.
    func testHumanizeAge() {
        XCTAssertEqual(SwarmFormat.humanizeAge(0), "0s")
        XCTAssertEqual(SwarmFormat.humanizeAge(42), "42s")
        XCTAssertEqual(SwarmFormat.humanizeAge(60), "1m")
        XCTAssertEqual(SwarmFormat.humanizeAge(599), "9m")
        XCTAssertEqual(SwarmFormat.humanizeAge(3600), "1h")
        XCTAssertEqual(SwarmFormat.humanizeAge(3660), "1h 1m")
        XCTAssertEqual(SwarmFormat.humanizeAge(-5), "0s")   // never negative
    }
}
