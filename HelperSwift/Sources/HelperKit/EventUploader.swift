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
/// posted for a session and is NOT reset by `removeSession(_:)` — the
/// lifecycle posts come THROUGH the uploader, so the counter must
/// outlive the queue entry until after the final 'stopped'/'errored'
/// status is sent. (M4.4d's revoke purges the queue on a session that
/// is still alive and then posts a trailing status; resetting here
/// would make that status reuse a consumed seq.)
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

    /// Per-session monotonic seq. Survives `removeSession(_:)` so a trailing
    /// lifecycle status can't reuse a consumed seq.
    private var sessionSeq: [String: Int] = [:]

    /// Per-session bounded queue. Append at end, drop from front
    /// when full.
    private var queues: [String: [PendingEvent]] = [:]

    /// Per-session PURGE generation, bumped only by `removeSession`. `pumpOnce`
    /// captures it before its first `await` and re-checks after each one: a
    /// change means the session was purged mid-pump (the user revoked cloud
    /// sharing), so the pump must abandon it rather than keep posting output
    /// consent was withdrawn for. Not bumped by `ingest` — appending during a
    /// pump is normal and must not abort it.
    private var purgeGen: [String: Int] = [:]
    private var purgeGenCounter = 0

    /// `pumpOnce` re-reads live state across its awaits, which is only sound if
    /// pumps don't overlap — two concurrent pumps would both see the same event
    /// at the front and post it TWICE. (The pre-M4.4d copy-based loop had the
    /// same hazard: both pumps copied the same array and both drained it.)
    /// `flush` and the daemon tick can both reach `pumpOnce`, so serialize them.
    ///
    /// A second caller WAITS rather than no-opping: `flush` loops on `pumpOnce`
    /// and reads a 0 return as "no progress was possible", so a no-op would make
    /// a shutdown flush racing an in-flight pump bail early and DROP the queue —
    /// the exact thing flush exists to prevent.
    private var isPumping = false
    private var pumpWaiters: [CheckedContinuation<Void, Never>] = []

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
    ///
    /// Every mutation here works against the LIVE `queues` entry, re-read after
    /// each `await`. It must NOT hold a local copy across the suspension:
    /// `postEvent` awaits an HTTPS RPC, which releases this actor, and anything
    /// that runs in that gap — `removeSession` from a user revoking cloud
    /// sharing, or an `ingest` from the drain loop — mutates `queues` behind us.
    /// A copy captured before the await would then be written back over their
    /// work, which:
    ///   * RESURRECTS events `removeSession` purged (defeating M4.4d's revoke —
    ///     the user's revoked output uploads anyway), and
    ///   * DISCARDS events `ingest` appended during the pump (silent data loss).
    /// (review: audit workflow — agy and codex both missed this; the earlier
    /// `uploader.removeSession` revoke fix was a no-op whenever a pump was in
    /// flight, i.e. the common case on a chatty session.)
    @discardableResult
    public func pumpOnce() async -> Int {
        // Re-check in a loop: several callers can be parked, and each resumes
        // into a fresh race for the flag.
        while isPumping {
            await withCheckedContinuation { pumpWaiters.append($0) }
        }
        isPumping = true
        defer {
            isPumping = false
            let waiters = pumpWaiters
            pumpWaiters.removeAll()
            for w in waiters { w.resume() }
        }
        var posted = 0
        // Snapshot the keys first so a parallel ingest doesn't
        // shift iteration. (We're an actor; this is sequential.)
        let sids = Array(queues.keys)
        for sid in sids {
            let purgeAtEntry = purgeGen[sid]
            while true {
                // Re-read live: an earlier session's await may have let
                // removeSession purge this one.
                guard let live = queues[sid], let event = live.first else { break }
                let ok = await postEvent(event)
                // The await released the actor. If this session was purged in
                // the gap, the user revoked consent — stop, and touch nothing:
                // `queues[sid]` is either gone or a FRESH queue (e.g. the
                // 'stopped' status the revoke posts), and neither is ours.
                if purgeGen[sid] != purgeAtEntry { break }
                if !ok {
                    // Leave the failing event at the front for retry.
                    break
                }
                // Drop the event we just posted from the LIVE queue — it's
                // still at the front (only this pump removes, and pumps don't
                // overlap: see `isPumping`).
                if var cur = queues[sid], !cur.isEmpty {
                    cur.removeFirst()
                    if cur.isEmpty {
                        queues.removeValue(forKey: sid)
                    } else {
                        queues[sid] = cur
                    }
                }
                posted += 1
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

    /// Drop every queued-but-unsent event for a session.
    ///
    /// M4.4d uses this to REVOKE: when the user turns off cloud sharing for a
    /// wrapped session, output already handed to us must not keep draining.
    /// Bumping `purgeGen` is what makes that stick against an in-flight pump —
    /// without it the pump resumes from its own pre-await copy and posts the
    /// purged events anyway (review: audit workflow).
    ///
    /// `sessionSeq` is deliberately RETAINED (review: audit workflow). Clearing
    /// it restarts the per-session counter at 1, so a status posted right after
    /// a purge — exactly what the revoke path does — would collide with a seq
    /// already consumed by earlier events for the same session. `seq` is
    /// advisory (no UNIQUE constraint; the app pages by the bigserial `id`), so
    /// a collision is cosmetic rather than corrupting — but there's no reason to
    /// emit one, and the counter outliving the queue is what this type's doc
    /// always promised.
    public func removeSession(_ sessionId: String) {
        purgeGenCounter += 1
        purgeGen[sessionId] = purgeGenCounter
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
