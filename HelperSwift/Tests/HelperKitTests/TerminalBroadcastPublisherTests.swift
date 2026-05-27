import XCTest
@testable import HelperKit
import Foundation

/// Tests for the v1.24 Phase 2c slice 2 Broadcast publisher seam.
/// Locks the two invariants the iOS/Mac WebView consumer depends on:
///   1. The sink NEVER sees a raw byte — `Redactor.redact` always
///      runs before handoff.
///   2. A laggy sink can never back-pressure the drain loop — the
///      queue is bounded and drops oldest on overflow.
final class TerminalBroadcastPublisherTests: XCTestCase {

    /// Sink that records everything it sees. Optionally sleeps per
    /// submit to simulate a slow/laggy network and exercise the
    /// publisher's queue behavior.
    final class CapturingSink: TerminalBroadcastSink, @unchecked Sendable {
        let perCallDelayMs: UInt32
        private let queue = DispatchQueue(label: "capturing-sink")
        private var _captured: [(sessionId: String, channel: String, event: String, redactedBytes: Data)] = []

        init(perCallDelayMs: UInt32 = 0) {
            self.perCallDelayMs = perCallDelayMs
        }

        var captured: [(sessionId: String, channel: String, event: String, redactedBytes: Data)] {
            queue.sync { self._captured }
        }

        func publish(
            sessionId: String,
            channel: String,
            event: String,
            redactedBytes: Data) async throws
        {
            if perCallDelayMs > 0 { usleep(perCallDelayMs * 1000) }
            queue.sync {
                self._captured.append((sessionId: sessionId, channel: channel, event: event, redactedBytes: redactedBytes))
            }
        }
    }

    /// Sink that always throws — exercises the publisher's
    /// drop-on-sink-failure path.
    struct ThrowingSink: TerminalBroadcastSink {
        struct Boom: Error {}
        func publish(sessionId _: String, channel _: String, event _: String, redactedBytes _: Data) async throws {
            throw Boom()
        }
    }

    // MARK: - core invariants

    func test_submitRedactsBeforeSink() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        let raw = Data("Authorization: Bearer sk-ant-api03-secret-1234567890abcdef\nready\n".utf8)
        await pub.submit(sessionId: "sess-A", chunk: raw)
        await pub.awaitDrained()

        XCTAssertEqual(sink.captured.count, 1, "expected exactly one published chunk")
        let payload = sink.captured[0].redactedBytes
        let body = String(data: payload, encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(Redactor.redactionMarker),
                      "expected redaction marker in body, got: \(body)")
        XCTAssertFalse(body.contains("sk-ant-api03-secret-1234567890abcdef"),
                       "raw token leaked to sink")
        XCTAssertTrue(body.contains("ready"), "non-secret content should pass through")
    }

    func test_channelNamingIsTermSessionId() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "abc-123", chunk: Data("x".utf8))
        await pub.awaitDrained()
        XCTAssertEqual(sink.captured.first?.channel, "term:abc-123")
    }

    func test_eventDefaultsToStdout() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s1", chunk: Data("hi".utf8))
        await pub.awaitDrained()
        XCTAssertEqual(sink.captured.first?.event, "stdout")
    }

    func test_explicitEventOverridesDefault() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s1", channel: "stderr", chunk: Data("oops".utf8))
        await pub.awaitDrained()
        XCTAssertEqual(sink.captured.first?.event, "stderr")
    }

    /// v1.26 B2: tail-snapshot results flow via the SAME publisher
    /// + SAME `term:<sid>` channel as live stdout. Only the `event`
    /// field changes ("tail_snapshot_result"). Pin the routing so a
    /// future refactor doesn't accidentally split into a separate
    /// channel that iOS isn't subscribed to.
    func test_tailSnapshotEventRoutesOnTermChannel() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(
            sessionId: "sess-T",
            channel: "tail_snapshot_result",
            chunk: Data("scrollback...".utf8))
        await pub.awaitDrained()
        let cap = sink.captured.first
        XCTAssertEqual(cap?.channel, "term:sess-T")
        XCTAssertEqual(cap?.event, "tail_snapshot_result")
        XCTAssertEqual(String(data: cap?.redactedBytes ?? Data(), encoding: .utf8), "scrollback...")
    }

    /// v1.26 B2: even the snapshot path runs through the redactor —
    /// the publisher contract is "sinks never see raw bytes." The
    /// helper-side `getTailSnapshot` already redacts; the publisher
    /// re-runs redaction (idempotent, no double-marker drift).
    func test_tailSnapshotResultRedactsBeforeSink() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        let raw = Data("Authorization: Bearer sk-ant-api03-secret-1234567890abcdef\nready\n".utf8)
        await pub.submit(sessionId: "s", channel: "tail_snapshot_result", chunk: raw)
        await pub.awaitDrained()
        let body = String(data: sink.captured.first?.redactedBytes ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains(Redactor.redactionMarker))
        XCTAssertFalse(body.contains("sk-ant-api03-secret-1234567890abcdef"))
    }

    func test_emptyChunkIsNoOp() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s1", chunk: Data())
        await pub.awaitDrained()
        XCTAssertEqual(sink.captured.count, 0)
    }

    // MARK: - bounded queue / drop-oldest

    func test_queueOverflowDropsOldest() async {
        // Slow sink so the queue actually backs up. Capacity 4 means
        // submissions 5+ should evict 1, 2, … from the front; the
        // newest survive.
        let sink = CapturingSink(perCallDelayMs: 20)
        let pub = TerminalBroadcastPublisher(sink: sink, queueCapacity: 4)
        for i in 1...10 {
            await pub.submit(sessionId: "s1", chunk: Data("chunk-\(i)\n".utf8))
        }
        await pub.awaitDrained()

        // The actor's drain serializes against submits — at least
        // the LAST few chunks should be present. With a capacity-4
        // queue and 10 submissions before drain catches up, at
        // most a small subset survives. The contract we assert is:
        //   - dropped count > 0
        //   - last-seen content includes "chunk-10\n" (newest)
        let dropped = await pub.droppedSinceStart
        XCTAssertGreaterThan(dropped, 0, "expected at least one drop")
        let bodies = sink.captured.compactMap { String(data: $0.redactedBytes, encoding: .utf8) }
        let lastSeen = bodies.last ?? ""
        XCTAssertTrue(lastSeen.contains("chunk-10"),
                      "expected newest chunk to be delivered; bodies=\(bodies)")
    }

    func test_droppedCountIncreasesMonotonically() async {
        let sink = CapturingSink(perCallDelayMs: 10)
        let pub = TerminalBroadcastPublisher(sink: sink, queueCapacity: 2)
        for i in 1...5 {
            await pub.submit(sessionId: "s1", chunk: Data("c\(i)".utf8))
        }
        await pub.awaitDrained()
        let dropped = await pub.droppedSinceStart
        XCTAssertGreaterThanOrEqual(dropped, 1)
    }

    // MARK: - sink failure path

    func test_throwingSink_countsAsDrop_publisherStaysHealthy() async {
        let pub = TerminalBroadcastPublisher(sink: ThrowingSink())
        for _ in 0..<3 {
            await pub.submit(sessionId: "s1", chunk: Data("payload".utf8))
        }
        await pub.awaitDrained()
        let dropped = await pub.droppedSinceStart
        let published = await pub.publishedSinceStart
        XCTAssertEqual(dropped, 3)
        XCTAssertEqual(published, 0)
        // Subsequent submits must still work (publisher didn't lock up).
        await pub.submit(sessionId: "s1", chunk: Data("after".utf8))
        await pub.awaitDrained()
    }

    // MARK: - counters

    func test_publishedCountIncrementsOnSuccess() async {
        let sink = CapturingSink()
        let pub = TerminalBroadcastPublisher(sink: sink)
        for i in 1...3 {
            await pub.submit(sessionId: "s1", chunk: Data("c\(i)".utf8))
        }
        await pub.awaitDrained()
        let published = await pub.publishedSinceStart
        XCTAssertEqual(published, 3)
    }
}
