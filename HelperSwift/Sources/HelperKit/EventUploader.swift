import Foundation

/// Per-session monotonic event seq + bounded queue + retry/upload
/// pump. Phase 4E Slice 3 design:
///
///   * `ingest(sessionId:kind:payload:)` enqueues (does NOT block).
///   * Each session gets a 256-event circular queue. On overflow we
///     drop the OLDEST event for that session and emit a Sentry
///     breadcrumb. The 256 ≈ 1 MB upper bound (4 KB × 256) guards
///     against a Supabase 429 / 500 storm starving the helper of
///     memory while the daemon's 1 s tick stays bounded by the
///     RPC timeout instead of the queue's drain latency.
///   * `flush(timeout:)` synchronously drains as much as the budget
///     allows; events past the budget are dropped with a final
///     breadcrumb. Used on SIGTERM / shutdown.
///
/// Gemini v2 Q5 / P1 — bounded queue with overflow drop-oldest.
/// Gemini v2 P1 — flush 5 s budget on SIGTERM.
///
/// Per-session monotonic seq counter starts at 1 on the first event
/// posted for a session. Resets when the session is removed via
/// `removeSession(_:)` (the lifecycle event posts come THROUGH the
/// uploader, so the counter must outlive the in-memory session
/// entry until after the final 'stopped'/'errored' status is sent).
public actor EventUploader {

    public enum EventKind: String, Sendable {
        case stdout
        case info
        case status
    }

    /// One row queued for upload via `remote_helper_post_event`.
    /// `seq` is assigned by the uploader at enqueue time so an
    /// in-flight retry doesn't shuffle the SQL ordering.
    public struct PendingEvent: Sendable, Equatable {
        public let sessionId: String
        public let seq: Int
        public let kind: EventKind
        public let payload: String

        public init(sessionId: String, seq: Int, kind: EventKind, payload: String) {
            self.sessionId = sessionId
            self.seq = seq
            self.kind = kind
            self.payload = payload
        }
    }

    /// Per-event drop reason emitted to the optional `onDrop`
    /// callback. Used to wire the "queue overflow" / "flush
    /// budget exceeded" breadcrumbs the dev plan calls for.
    public enum DropReason: String, Sendable {
        case queueOverflow
        case flushBudgetExceeded
    }

    /// Maximum number of bytes per event payload sent to Supabase.
    /// Server-side row CHECK is `length(payload) <= 4096`. Helper
    /// caps a hair under to leave headroom for the SQL
    /// `left(p_payload, 4096)` truncation.
    public static let eventPayloadCapChars = 4000

    /// Lifecycle detail (`kind='info'`) is bounded harder than
    /// stdout — info rows are inherently short, anything longer
    /// has likely sucked in a stack trace we'd rather elide.
    public static let infoPayloadCapChars = 1024

    /// Bounded queue depth per session.
    public static let perSessionQueueCap = 256

    /// Overall flush budget on SIGTERM.
    public static let defaultFlushBudget: TimeInterval = 5.0

    private let helperConfig: @Sendable () -> HelperConfigStore.CloudConfig
    private let rpcCaller: any RPCCallable
    private let onDrop: (@Sendable (String, EventKind, DropReason) -> Void)?
    private let nowProvider: @Sendable () -> TimeInterval

    /// Per-session monotonic seq. Survives session removal via
    /// `removeSession(_:)` callers — caller must explicitly call
    /// after the final lifecycle event has been posted.
    private var sessionSeq: [String: Int] = [:]

    /// Per-session bounded queue. Append at end, drop from front
    /// when full.
    private var queues: [String: [PendingEvent]] = [:]

    public init(
        helperConfig: @escaping @Sendable () -> HelperConfigStore.CloudConfig,
        rpcCaller: any RPCCallable,
        onDrop: (@Sendable (String, EventKind, DropReason) -> Void)? = nil,
        nowProvider: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.helperConfig = helperConfig
        self.rpcCaller = rpcCaller
        self.onDrop = onDrop
        self.nowProvider = nowProvider
    }

    /// Drain the per-session queue once and post each pending
    /// event via the RPC caller. Stops at the first failure for a
    /// given session (the rest stay queued for the next pump).
    /// Returns count of events successfully posted.
    @discardableResult
    public func pumpOnce() async -> Int {
        var posted = 0
        // Snapshot the keys first so a parallel ingest doesn't
        // shift iteration. (We're an actor; this is sequential.)
        let sids = Array(queues.keys)
        for sid in sids {
            guard var queue = queues[sid], !queue.isEmpty else { continue }
            while !queue.isEmpty {
                let event = queue[0]
                let ok = await postEvent(event)
                if !ok {
                    // Leave the failing event at the front for retry.
                    break
                }
                queue.removeFirst()
                posted += 1
            }
            if queue.isEmpty {
                queues.removeValue(forKey: sid)
            } else {
                queues[sid] = queue
            }
        }
        return posted
    }

    /// Synchronous-style flush with overall wall-clock budget.
    /// Returns (postedCount, droppedCount).
    @discardableResult
    public func flush(timeout: TimeInterval = EventUploader.defaultFlushBudget) async -> (Int, Int) {
        let deadline = nowProvider() + timeout
        var posted = 0
        // Drain in pump waves until empty or deadline.
        while nowProvider() < deadline {
            let before = totalQueued()
            if before == 0 { break }
            posted += await pumpOnce()
            let after = totalQueued()
            if after == before {
                // Pump didn't make progress this iteration —
                // every front-of-queue event failed. Yield a tick
                // so we don't spin; bail if this is consistent.
                // (Gemini 2.5 Pro Slice 3 P2): if remaining budget
                // is shorter than our backoff, give up directly so
                // we don't burn the whole budget in one sleep.
                if (deadline - nowProvider()) < 0.05 {
                    break
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                if totalQueued() == before {
                    break
                }
            }
        }
        // Anything left after the budget is dropped with a
        // breadcrumb.
        var dropped = 0
        for (sid, queue) in queues {
            for event in queue {
                onDrop?(sid, event.kind, .flushBudgetExceeded)
                dropped += 1
            }
        }
        queues.removeAll()
        return (posted, dropped)
    }

    /// Allocate a seq for `sessionId`, redact + cap `payload`,
    /// enqueue the event. Drops oldest when the per-session queue
    /// is at cap.
    public func ingest(sessionId: String, kind: EventKind, payload: String) {
        let seq = nextSeq(sessionId: sessionId)
        let capped: String
        switch kind {
        case .stdout:
            capped = String(payload.prefix(Self.eventPayloadCapChars))
        case .info:
            capped = String(payload.prefix(Self.infoPayloadCapChars))
        case .status:
            // status payload is exactly 'stopped' or 'errored' —
            // cap is a defence in depth, never trips in practice.
            capped = String(payload.prefix(Self.eventPayloadCapChars))
        }
        let event = PendingEvent(
            sessionId: sessionId, seq: seq, kind: kind, payload: capped
        )
        var queue = queues[sessionId] ?? []
        queue.append(event)
        while queue.count > Self.perSessionQueueCap {
            let dropped = queue.removeFirst()
            onDrop?(sessionId, dropped.kind, .queueOverflow)
        }
        queues[sessionId] = queue
    }

    /// Counts of currently queued events. Tests use this to
    /// assert overflow + flush behavior without poking actor
    /// internals.
    public func queuedCount(sessionId: String) -> Int {
        return (queues[sessionId] ?? []).count
    }

    public func totalQueued() -> Int {
        return queues.values.reduce(0) { $0 + $1.count }
    }

    public func currentSeq(sessionId: String) -> Int {
        return sessionSeq[sessionId] ?? 0
    }

    public func removeSession(_ sessionId: String) {
        sessionSeq.removeValue(forKey: sessionId)
        queues.removeValue(forKey: sessionId)
    }

    /// Per-session monotonic seq. Starts at 1 on the first event
    /// posted for a given session. Mirrors Python's
    /// `_next_seq`: caller `_post_event` increments + reads in
    /// one shot.
    private func nextSeq(sessionId: String) -> Int {
        let next = (sessionSeq[sessionId] ?? 0) + 1
        sessionSeq[sessionId] = next
        return next
    }

    private func postEvent(_ event: PendingEvent) async -> Bool {
        let cfg = helperConfig()
        if !cfg.isPaired {
            // Helper unpaired (or migrating). Drop the event so we
            // don't burn CPU on retries that will never succeed.
            return true
        }
        let params: [String: Any] = [
            "p_device_id": cfg.deviceId,
            "p_helper_secret": cfg.helperSecret,
            "p_session_id": event.sessionId,
            "p_seq": event.seq,
            "p_kind": event.kind.rawValue,
            "p_payload": event.payload,
        ]
        do {
            _ = try await rpcCaller.call("remote_helper_post_event", params: params)
            return true
        } catch {
            return false
        }
    }
}
