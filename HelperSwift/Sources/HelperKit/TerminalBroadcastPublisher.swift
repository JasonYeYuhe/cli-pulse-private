import Foundation

/// Sink for the v1.24 Phase 2c terminal Broadcast path. Receives
/// REDACTED bytes (the publisher does the redaction; sinks must
/// never see raw stdout). Concrete implementations:
///   * `NoopBroadcastSink` — default for v1.24.0; drops messages,
///     logs to OSLog when verbose. Lets us exercise the publisher's
///     redaction / queue / drop-oldest logic without depending on
///     external infrastructure.
///   * `SupabaseRealtimeBroadcastSink` — follow-up; POSTs to the
///     Supabase Realtime `/broadcast` endpoint with the helper's
///     short-lived JWT. Lands when the iOS client's subscribe path
///     is built (Phase 2c slice 3).
public protocol TerminalBroadcastSink: Sendable {
    /// Hand off ONE already-redacted chunk to wherever the chunk
    /// goes (Supabase channel POST / WebSocket frame / log line).
    /// Implementations are expected to be cheap — the publisher
    /// already coalesces and bounds throughput upstream of this
    /// call. May throw to signal "channel is currently unreachable"
    /// so the publisher's metrics can surface it; throwing must not
    /// retry the same chunk (publisher fire-and-forgets).
    func publish(
        sessionId: String,
        channel: String,
        event: String,
        redactedBytes: Data) async throws
}

/// No-op sink: discards every chunk after redaction. Default for
/// v1.24.0 — exercises the publisher's redaction / queue / drop
/// behavior in tests and on installs where the user hasn't enabled
/// remote terminal mirroring.
public struct NoopBroadcastSink: TerminalBroadcastSink {
    public init() {}
    public func publish(
        sessionId _: String,
        channel _: String,
        event _: String,
        redactedBytes _: Data) async throws
    {
        // discard
    }
}

/// Helper-side publisher for the terminal Broadcast path (v1.24
/// Phase 2c, Gemini CRITICAL). Sits between `ManagedSessionManager`'s
/// drain loop and a `TerminalBroadcastSink` (typically a Supabase
/// Realtime channel POST). Two invariants:
///
///   1. **Redaction before publish (Codex HIGH H4).** Every byte
///      that reaches the sink has already been through
///      `Redactor.redact`. The sink protocol exposes `redactedBytes`
///      verbatim so a wrong-sink implementation can't accidentally
///      leak the raw chunk.
///   2. **Bounded queue, drop-oldest on overflow.** A laggy sink
///      (network blip / Supabase quota brake) cannot back-pressure
///      the drain loop's reads from the PTY master fd. Excess
///      chunks are dropped from the head of the queue and an
///      observable `droppedSinceStart` counter ticks up. A real
///      consumer's reconnect path uses `get_tail_snapshot` to
///      recover, so per-chunk loss tolerance is acceptable.
///
/// Channel naming follows the plan §2c convention:
///   `term:<session_id>` for stdout/stderr chunks
///
/// The publisher runs on its own actor so submissions from the
/// helper's drain thread don't block on the sink's network I/O.
public actor TerminalBroadcastPublisher {
    private let sink: TerminalBroadcastSink
    private let queueCapacity: Int
    private var queue: [(sessionId: String, channel: String, event: String, redactedBytes: Data)] = []
    private var draining: Bool = false
    private(set) var droppedSinceStart: Int = 0
    private(set) var publishedSinceStart: Int = 0

    public init(sink: TerminalBroadcastSink = NoopBroadcastSink(), queueCapacity: Int = 256) {
        self.sink = sink
        self.queueCapacity = max(1, queueCapacity)
    }

    /// Submit a raw stdout chunk for the given session. The
    /// publisher will redact, enqueue, and asynchronously hand off
    /// to the sink. Returns immediately; callers must not await
    /// confirmation of delivery.
    public func submit(sessionId: String, channel: String = "stdout", chunk: Data) {
        if chunk.isEmpty { return }
        // Decode → redact → re-encode. Same lossy contract as
        // `getTailSnapshot`: corrupted boundary codepoints render
        // as ▯ in xterm.js. The xterm path is BEST-EFFORT
        // mirroring; reconnect-snapshot is the authoritative
        // recovery path.
        let text = String(data: chunk, encoding: .utf8) ?? String(decoding: chunk, as: UTF8.self)
        let redacted = Redactor.redact(text)
        let payload = Data(redacted.utf8)
        let channelName = "term:\(sessionId)"
        let envelope = (sessionId: sessionId, channel: channelName, event: channel, redactedBytes: payload)

        if queue.count >= queueCapacity {
            queue.removeFirst()
            droppedSinceStart += 1
        }
        queue.append(envelope)
        // Kick the drain loop if idle.
        if !draining {
            draining = true
            Task { await self.drain() }
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            do {
                try await sink.publish(
                    sessionId: next.sessionId,
                    channel: next.channel,
                    event: next.event,
                    redactedBytes: next.redactedBytes)
                publishedSinceStart += 1
            } catch {
                // Sink-reported failure: count as a drop and
                // continue. The next reconnect will tail-snapshot
                // to catch up. Do NOT retry the same chunk —
                // back-pressure on the helper risks the drain
                // loop falling behind the PTY's read buffer.
                droppedSinceStart += 1
            }
        }
        draining = false
    }

    // MARK: - test hooks

    /// Synchronization point for tests: returns once the in-flight
    /// drain task has flushed the current queue. Production code
    /// MUST NOT await this — the publisher is fire-and-forget.
    public func awaitDrained() async {
        // Spin until draining is false AND queue is empty. The
        // actor guarantees mutual exclusion so this read is racy
        // only with itself — we yield between checks to let the
        // drain task progress.
        while draining || !queue.isEmpty {
            await Task.yield()
        }
    }

    /// Reset counters (test helper).
    public func resetCounters() {
        droppedSinceStart = 0
        publishedSinceStart = 0
    }
}
