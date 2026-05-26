import Foundation

/// Coalesces high-frequency byte chunks into ≤ 1-per-frame batches
/// before handing off to a (typically expensive) sink — addresses
/// Codex HIGH H1 from the v1.24 in-app-terminal plan §Phase 3b.
///
/// Even with the JS-side `requestAnimationFrame` batcher inside
/// xterm.js, the Swift → WKWebView bridge can still see 50–500
/// `evaluateJavaScript` calls per second when the child process
/// produces dense output (think `npm install`, `cargo build`, or a
/// `find /` dump). Each bridge crossing is a JSON marshal + thread
/// hop + JavaScriptCore enter — cheap individually, painful at
/// 500/sec.
///
/// This coalescer adds a 16 ms wall-clock window on the producer
/// side: each `append(_:)` enqueues bytes into a buffer; the first
/// append schedules a flush on the configured queue 16 ms later
/// (one display frame at 60 Hz); subsequent appends within that
/// window merge in without rescheduling. When the timer fires, the
/// buffered concatenation is handed to `onFlush` in a single call.
///
/// At idle frequency (occasional output) the coalescer adds ≤ 16 ms
/// latency to the first byte. At high frequency it caps bridge
/// crossings to ~60/sec regardless of input rate. Combined with the
/// JS-side rAF batcher, the WebView renders one `term.write()` per
/// frame at worst.
///
/// Thread-safety: callers may `append` from any queue; `onFlush`
/// fires on the queue passed at construction (default: a serial
/// dedicated queue). Use `.main` if the consumer must touch the
/// WKWebView directly.
public final class TerminalOutputCoalescer: @unchecked Sendable {

    public typealias FlushHandler = @Sendable (Data) -> Void

    /// Flush window. 16 ms ≈ one frame at 60 Hz; xterm.js renders on
    /// rAF anyway so this matches the JS side's natural cadence.
    public let windowSeconds: TimeInterval

    private let flushQueue: DispatchQueue
    private let onFlush: FlushHandler

    private let lock = NSLock()
    private var pending = Data()
    private var scheduled = false
    /// Test hook: when set, the coalescer asks this closure for
    /// "now" instead of using DispatchTime. Production code uses the
    /// nil branch (real clock); tests inject a virtual clock to
    /// avoid sleeping.
    private let clockProvider: (@Sendable () -> DispatchTime)?

    public init(
        windowSeconds: TimeInterval = 0.016,
        flushQueue: DispatchQueue = DispatchQueue(label: "TerminalOutputCoalescer", qos: .userInitiated),
        onFlush: @escaping FlushHandler,
        clockProvider: (@Sendable () -> DispatchTime)? = nil
    ) {
        precondition(windowSeconds > 0, "windowSeconds must be positive")
        self.windowSeconds = windowSeconds
        self.flushQueue = flushQueue
        self.onFlush = onFlush
        self.clockProvider = clockProvider
    }

    /// Append a chunk. If no flush is scheduled, schedule one
    /// `windowSeconds` from now; otherwise just merge into pending.
    public func append(_ chunk: Data) {
        if chunk.isEmpty { return }
        var shouldSchedule = false
        lock.lock()
        pending.append(chunk)
        if !scheduled {
            scheduled = true
            shouldSchedule = true
        }
        lock.unlock()
        if shouldSchedule {
            let deadline: DispatchTime
            if let clockProvider {
                deadline = clockProvider() + windowSeconds
            } else {
                deadline = .now() + windowSeconds
            }
            flushQueue.asyncAfter(deadline: deadline) { [weak self] in
                self?.flush()
            }
        }
    }

    /// Force-flush whatever's pending right now (synchronous on
    /// the caller's thread, with `onFlush` invoked inline). Useful
    /// when the consuming view unmounts and we want to drop the
    /// timer ASAP without waiting for the deadline.
    public func flushNow() {
        let toSend: Data?
        lock.lock()
        if pending.isEmpty {
            toSend = nil
        } else {
            toSend = pending
            pending = Data()
        }
        scheduled = false
        lock.unlock()
        if let toSend { onFlush(toSend) }
    }

    private func flush() {
        let toSend: Data?
        lock.lock()
        if pending.isEmpty {
            toSend = nil
        } else {
            toSend = pending
            pending = Data()
        }
        scheduled = false
        lock.unlock()
        if let toSend { onFlush(toSend) }
    }

    // MARK: - introspection (test/diagnostic only)

    /// Bytes currently buffered (pre-flush). For tests/diagnostics —
    /// do not use to gate production logic.
    public var pendingByteCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pending.count
    }

    /// True if a flush is currently scheduled.
    public var hasScheduledFlush: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduled
    }
}
