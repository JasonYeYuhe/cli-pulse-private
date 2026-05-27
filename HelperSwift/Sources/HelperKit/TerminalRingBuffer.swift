import Foundation

/// Fixed-capacity circular byte buffer for retaining the most recent
/// `capacity` bytes of a managed session's stdout. Used as the source
/// of `remote_helper_get_tail_snapshot` (Gemini HIGH from the v1.24
/// in-app-terminal plan §Phase 2c) — when the iOS WKWebView returns
/// from background and re-subscribes, it fetches a tail-snapshot to
/// render "where the session landed while I was away," skipping the
/// expensive full-event-replay.
///
/// Threading: fully thread-safe. All mutating and reading operations
/// (`append`, `tail`, `clear`, `size`) take an internal `NSLock` so
/// callers can hit the buffer from any thread without external
/// synchronization. This was promoted from "single-writer/single-reader,
/// external sync required" (v1.24) to fully self-locking after Codex
/// flagged a real race in v1.25 — `ManagedSessionManager.getTailSnapshot`
/// drops `lock` before reading the buffer while the drain loop appends
/// without holding it (Phase A0 hotfix, v1.26).
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
    private var _size: Int = 0

    /// Serializes all mutations and reads. `NSLock` (not `os_unfair_lock`)
    /// because the critical sections do memcpy-sized work; the queue
    /// fairness + Swift-bridge ergonomics outweigh the unlocked path's
    /// nanosecond edge for this workload.
    private let lock = NSLock()

    /// Thread-safe snapshot of the buffered byte count.
    public var size: Int {
        lock.lock()
        defer { lock.unlock() }
        return _size
    }

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

        lock.lock()
        defer { lock.unlock() }

        // If the incoming span alone exceeds capacity, only the last
        // `capacity` bytes can possibly survive. Truncate up front so
        // we never copy bytes we'd immediately discard.
        if data.count >= capacity {
            let effective = data.suffix(capacity)
            // The new bytes will completely replace existing content.
            head = 0
            _size = capacity
            effective.withUnsafeBytes { src in
                storage.withUnsafeMutableBytes { dst in
                    guard let s = src.baseAddress, let d = dst.baseAddress else { return }
                    d.copyMemory(from: s, byteCount: capacity)
                }
            }
            return
        }

        let n = data.count
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
        _size = min(capacity, _size + n)
    }

    /// Return up to `maxBytes` of the most-recently-appended bytes,
    /// in stream (not storage) order. Empty if the buffer is empty.
    public func tail(maxBytes: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let n = min(max(0, maxBytes), _size)
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
        lock.lock()
        defer { lock.unlock() }
        head = 0
        _size = 0
    }
}
