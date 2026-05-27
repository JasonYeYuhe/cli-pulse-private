import XCTest
@testable import HelperKit
import Foundation

/// v1.26 Phase B2: focused tests for `ManagedSessionManager.publishTailSnapshot`.
/// The bridge between the iOS-requested snapshot RPC and the
/// helper-side broadcast path. Pins:
///   * Returns false when no publisher is configured (Mac-only
///     installs without remote_realtime_enabled fall through to
///     here and we want the dispatch to mark "delivered" without
///     surfacing an error to the iOS client).
///   * Returns false for an unmanaged session (the dispatch layer
///     also guards on ownsSession, but the manager-level check is
///     the authoritative source).
///   * Returns false (and DOES NOT publish) on an empty buffer —
///     iOS times out and proceeds.
final class PublishTailSnapshotTests: XCTestCase {

    final class CapturingSink: TerminalBroadcastSink, @unchecked Sendable {
        private let queue = DispatchQueue(label: "publish-tail-snapshot-tests")
        private var _captured: [(sessionId: String, event: String, body: String)] = []
        var captured: [(sessionId: String, event: String, body: String)] {
            queue.sync { _captured }
        }
        func publish(sessionId: String, channel _: String, event: String, redactedBytes: Data) async throws {
            let body = String(data: redactedBytes, encoding: .utf8) ?? ""
            queue.sync { _captured.append((sessionId: sessionId, event: event, body: body)) }
        }
    }

    func test_publishTailSnapshot_returnsFalse_whenNoPublisherConfigured() async {
        // Default init has no broadcastPublisher; the manager won't
        // attempt a publish, returns false. The dispatch layer
        // treats this as "delivered" so the queue marks success.
        let mgr = ManagedSessionManager(transport: PtyTransport())
        let result = await mgr.publishTailSnapshot(sessionId: "unowned", maxBytes: 8192)
        XCTAssertFalse(result)
    }

    func test_publishTailSnapshot_returnsFalse_forUnownedSession() async {
        let sink = CapturingSink()
        let publisher = TerminalBroadcastPublisher(sink: sink)
        let mgr = ManagedSessionManager(
            transport: PtyTransport(),
            broadcastPublisher: publisher)
        let result = await mgr.publishTailSnapshot(sessionId: "no-such-session", maxBytes: 8192)
        XCTAssertFalse(result)
        await publisher.awaitDrained()
        XCTAssertEqual(sink.captured.count, 0,
                       "must not publish for an unowned session")
    }
}
