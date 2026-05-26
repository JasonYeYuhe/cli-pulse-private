import Foundation

/// Fixed-capacity circular byte buffer for retaining the most recent
/// `capacity` bytes of a managed session's stdout. Used as the source
/// of `remote_helper_get_tail_snapshot` (Gemini HIGH from the v1.24
/// in-app-terminal plan §Phase 2c) — when the iOS WKWebView returns
/// from background and re-subscribes, it fetches a tail-snapshot to
/// render "where the session landed while I was away," skipping the
/// expensive full-event-replay.
///
/// Threading: callers must synchronize externally. The helper's drain
/// loop is the only writer per session; the RPC handler is the only
/// reader and the manager already holds `lock` while resolving the
/// session record.
///
/// Bytes stored verbatim (no redaction). Redaction happens at the
/// read side (`getTailSnapshot` decodes → `Redactor.redact` →
/// re-encodes) so the byte-level ring stays correct for arbitrary
/// stream content; secrets only escape via paths that explicitly
/// redact. Realtime BROADCAST publisher (slice 2) adds a separate
/// redact-at-write step on its own outbound path.
public final class TerminalRingBuffer {
    public let capacity: Int

    /// Backing storage of length `capacity`. Indices wrap modulo capacity.
    private var storage: Data

    /// Next write position (0..<capacity).
    private var head: Int = 0

    /// Number of valid bytes currently buffered (0...capacity).
    private(set) var size: Int = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "TerminalRingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = Data(count: capacity)
    }

    /// Append bytes. When `data.count + size > capacity` the oldest
    /// bytes are dropped. Constant memory; O(min(data.count, capacity))
    /// time (a span past `capacity` is truncated to the trailing
    /// `capacity` bytes — older bytes would be immediately
    /// over-written so we skip them).
    public func append(_ data: Data) {
        if data.isEmpty { return }

        // If the incoming span alone exceeds capacity, only the last
        // `capacity` bytes can possibly survive. Truncate up front so
        // we never copy bytes we'd immediately discard.
        let effective: Data
        if data.count >= capacity {
            effective = data.suffix(capacity)
            // The new bytes will completely replace existing content.
            head = 0
            size = capacity
            effective.withUnsafeBytes { src in
                storage.withUnsafeMutableBytes { dst in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                    d.copyMemory(from: s, byteCount: capacity)
                }
            }
            return
        }

        let n = effective_count(data)
        // Two-segment copy if the write wraps past `capacity`.
        let firstSpan = min(n, capacity - head)
        let secondSpan = n - firstSpan

        data.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            storage.withUnsafeMutableBytes { dst in
                guard let dstBase = dst.baseAddress else { return }
                if firstSpan > 0 {
                    (dstBase + head).copyMemory(from: srcBase, byteCount: firstSpan)
                }
                if secondSpan > 0 {
                    (dstBase).copyMemory(from: srcBase + firstSpan, byteCount: secondSpan)
                }
            }
        }

        head = (head + n) % capacity
        size = min(capacity, size + n)
    }

    private func effective_count(_ data: Data) -> Int {
        // Helper for tests' clarity; in production all callers ensure
        // data.count < capacity here.
        data.count
    }

    /// Return up to `maxBytes` of the most-recently-appended bytes,
    /// in stream (not storage) order. Empty if the buffer is empty.
    public func tail(maxBytes: Int) -> Data {
        let n = min(max(0, maxBytes), size)
        if n == 0 { return Data() }

        // Start offset in storage: walk `n` bytes backwards from
        // `head`, modulo `capacity`.
        let start = ((head - n) % capacity + capacity) % capacity
        if start + n <= capacity {
            return storage.subdata(in: start..<(start + n))
        }
        // Wrap-around: copy [start..<capacity] then [0..<remainder]
        let firstSpan = capacity - start
        let secondSpan = n - firstSpan
        var out = Data(capacity: n)
        out.append(storage.subdata(in: start..<capacity))
        out.append(storage.subdata(in: 0..<secondSpan))
        return out
    }

    /// Drop all buffered bytes; ready to reuse for a new session.
    public func clear() {
        head = 0
        size = 0
    }
}
