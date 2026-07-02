import XCTest
@testable import HelperKit

/// R0 (S2) — the fail-closed public-broadcast gate. The Swift helper POSTs
/// redacted terminal output to the PUBLIC `term:<sid>` Realtime topic, so it may
/// mirror there ONLY for a session POSITIVELY known public. This pins the
/// invariant that a private session — or one whose privacy is UNKNOWN (a
/// local/UDS session, or a pre-v0.61 payload without the flag) — is muted, so
/// output never leaks on the public channel and "public" is never *inferred*
/// from a missing flag.
final class ManagedBroadcastGateTests: XCTestCase {

    func test_positively_public_session_may_broadcast() {
        XCTAssertTrue(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: false))
    }

    func test_private_session_is_muted() {
        XCTAssertFalse(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: true))
    }

    func test_unknown_privacy_is_fail_closed_muted() {
        // nil = no authoritative privacy source (local session / old backend).
        // Fail-closed: never broadcast, never infer "public".
        XCTAssertFalse(ManagedSessionManager.allowsPublicBroadcast(realtimePrivate: nil))
    }
}
