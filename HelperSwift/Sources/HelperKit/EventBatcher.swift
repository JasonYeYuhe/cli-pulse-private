import Foundation

/// Coalesce small terminal-output chunks into ≤ 4 KB rows.
///
/// Mirrors `helper/remote_agent.py:EventBatcher`. Provider event
/// rows are capped server-side (see migrate_v0.26 `length(payload)
/// <= 4096` row CHECK), so the helper coalesces small reads from
/// the PTY before posting one `kind='stdout'` event. Per-session
/// instance owned by `RemoteAgentCloud`.
///
/// Threading: NOT thread-safe — callers serialise via the owning
/// actor. The batcher itself stays a struct-style class so we can
/// hold mutable state without `final class @unchecked Sendable`
/// gymnastics.
public final class EventBatcher {

    public let flushBytes: Int
    public let maxIdle: TimeInterval

    private var buf: [String] = []
    private var sizeBytes: Int = 0
    private var firstAt: TimeInterval?

    /// `now` injected for tests so we don't have to sleep through
    /// the idle budget.
    private var nowProvider: @Sendable () -> TimeInterval

    public init(
        flushBytes: Int = 3500,
        maxIdle: TimeInterval = 0.5,
        nowProvider: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        }
    ) {
        self.flushBytes = flushBytes
        self.maxIdle = maxIdle
        self.nowProvider = nowProvider
    }

    /// Append a chunk. Returns the joined payload (trimmed to
    /// 4096 chars) when the size cutoff trips, else nil.
    @discardableResult
    public func add(_ chunk: String) -> String? {
        if chunk.isEmpty { return nil }
        buf.append(chunk)
        sizeBytes += chunk.utf8.count
        if firstAt == nil {
            firstAt = nowProvider()
        }
        if sizeBytes >= flushBytes {
            return drain()
        }
        return nil
    }

    /// True when an unflushed batch has been pending longer than
    /// `maxIdle`. The drainer calls `drain()` when this fires so
    /// interactive output (a few words at a time) doesn't sit
    /// behind the user's expectations.
    public func due() -> Bool {
        guard let first = firstAt else { return false }
        return (nowProvider() - first) >= maxIdle
    }

    /// Drain the buffer, returning the joined payload (≤4096
    /// chars). Returns nil when empty so callers can skip the
    /// post-event call.
    @discardableResult
    public func drain() -> String? {
        if buf.isEmpty {
            return nil
        }
        let joined = buf.joined()
        buf.removeAll(keepingCapacity: true)
        sizeBytes = 0
        firstAt = nil
        if joined.count <= 4096 {
            return joined
        }
        return String(joined.prefix(4096))
    }

    /// Reset internal state — useful for tests after observing
    /// the post-flush counters.
    public func reset() {
        buf.removeAll(keepingCapacity: true)
        sizeBytes = 0
        firstAt = nil
    }
}
