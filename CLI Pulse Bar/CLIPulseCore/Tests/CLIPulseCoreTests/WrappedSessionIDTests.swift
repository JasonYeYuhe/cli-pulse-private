import XCTest
@testable import CLIPulseCore

/// M4.4d: the wrapped-session id must be BOTH deterministic (idempotent attach,
/// singleton terminal window, stable cloud row across re-attaches) and a real
/// UUID (`remote_helper_register_session(p_session_id uuid)` rejects anything
/// else, and without that row the phone can neither see nor command the
/// session).
final class WrappedSessionIDTests: XCTestCase {

    func testMatchesTheRFC4122NameBasedVector() {
        // Pin the v5 algorithm itself against the RFC's own published vector, so
        // a refactor of the hashing/bit-stamping can't silently re-key every
        // existing wrapped session.
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        XCTAssertEqual(
            WrappedSessionID.uuidV5(namespace: dns, name: "www.example.org").uuidString.lowercased(),
            "74738ff5-5367-5958-9aee-98fffdcd1876"
        )
    }

    func testIsDeterministicPerTmuxName() {
        // The property M4.4c chose this design for (review: codex): a double-tap
        // must not mint two ids for the SAME external session, which would
        // register two tmux control clients and open two windows for it.
        let a = WrappedSessionID.sessionId(forTmuxName: "clipulse-claude-4321")
        let b = WrappedSessionID.sessionId(forTmuxName: "clipulse-claude-4321")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, WrappedSessionID.sessionId(forTmuxName: "clipulse-claude-4322"))
        XCTAssertNotEqual(a, WrappedSessionID.sessionId(forTmuxName: "clipulse-codex-4321"))
    }

    func testIsAValidLowercasedUUID() {
        let sid = WrappedSessionID.sessionId(forTmuxName: "clipulse-codex-99")
        XCTAssertNotNil(UUID(uuidString: sid), "register_session takes a uuid — a non-UUID id can never be shared")
        XCTAssertEqual(sid, sid.lowercased())
        // v5 + RFC 4122 variant, as the version/variant nibbles encode them.
        let parts = sid.split(separator: "-")
        XCTAssertEqual(parts[2].first, "5", "must be a version-5 (name-based) UUID")
        XCTAssertTrue("89ab".contains(parts[3].first!), "must carry the RFC 4122 variant bits")
    }

    func testNamespaceIsPinned() {
        // The namespace is load-bearing history: changing it silently re-keys
        // every existing wrapped session (new cloud rows, orphaned old ones,
        // duplicate terminal windows). If this fails, that's what happened —
        // don't "fix" the test.
        XCTAssertEqual(
            WrappedSessionID.sessionId(forTmuxName: "clipulse-claude-1"),
            WrappedSessionID.uuidV5(
                namespace: UUID(uuidString: "6f1c8b4e-3a2d-4f57-9c81-0d5e7a1b2c3f")!,
                name: "clipulse-claude-1"
            ).uuidString.lowercased()
        )
    }
}
