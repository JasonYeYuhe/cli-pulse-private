import Foundation
import Darwin

/// Transport-abstraction seam for `ManagedSessionManager` — the Swift analogue
/// of the Python helper's `transports/base.py:SessionTransport` ABC.
///
/// The shipped manager spawns Claude/Codex under a `PtyTransport` (PTY +
/// posix_spawn). The tmux-wrap milestone (M4.4a) needs the SAME manager to
/// also ATTACH to an already-running session inside a CLI-Pulse-owned tmux —
/// a fundamentally different transport (control-mode I/O, not a PTY child).
///
/// So the handle-scoped I/O operations are abstracted behind this protocol,
/// and each `ManagedSessionRecord` carries an optional per-session transport
/// override (`nil` ⇒ the manager's shared `PtyTransport`). Only the I/O
/// surface is abstracted: `start` (spawn) and `attachExisting` are
/// transport-SPECIFIC and stay on the concrete types — the manager calls them
/// when CREATING a session, then routes every subsequent I/O call through the
/// protocol. Mirrors Python `_sess_transport(sess) = sess.transport or
/// self.transport`.
///
/// The `handle` passed to each method is an opaque `SessionHandle`; the
/// conforming transport downcasts it to its own concrete handle type and
/// throws `foreignHandle` on a mismatch (the Swift analogue of Python's
/// `_p(handle)` foreign-handle guard) — a transport must never operate on
/// another transport's handle.
public protocol SessionHandle: AnyObject, Sendable {
    /// The manager's session id (preserved verbatim even when the underlying
    /// transport sanitizes it for its own addressing, e.g. tmux target names).
    var sessionId: String { get }
    /// Child pid for a spawned PTY session; `0` for an attached session with no
    /// owned child process (e.g. a tmux-wrapped session the helper didn't
    /// fork). Surfaced in `listSessions`.
    var pid: pid_t { get }
    /// True once `close` has run (idempotency guard).
    var isClosed: Bool { get }
}

/// Handle-scoped I/O + lifecycle a `ManagedSessionRecord` needs, independent of
/// whether the session is a spawned PTY child or an attached tmux session.
public protocol SessionTransport: AnyObject, Sendable {
    /// Inject bytes to the session's stdin. Returns the count actually written
    /// (may be < data.count on a partial/failed write — the manager treats a
    /// short write as a soft failure, matching the PTY path).
    func writeStdin(_ handle: SessionHandle, _ data: Data) throws -> Int
    /// Non-blocking read of up to `maxBytes` of pending output. Returns empty
    /// Data when nothing is buffered.
    func readStdout(_ handle: SessionHandle, maxBytes: Int) throws -> Data
    /// Resize the session's window (best-effort).
    func setWinsize(_ handle: SessionHandle, cols: UInt16, rows: UInt16) throws
    /// Send an interrupt (Ctrl-C) to the session.
    func interrupt(_ handle: SessionHandle)
    /// Request graceful termination. For an ATTACHED (non-owning) transport
    /// this must be a NO-OP on the real session — detaching must never kill a
    /// session the helper doesn't own.
    func terminate(_ handle: SessionHandle)
    /// True while the session is still alive.
    func isAlive(_ handle: SessionHandle) -> Bool
    /// Reap / wait for exit up to `timeoutSec` (nil = don't block beyond a
    /// poll). Returns the exit status when known, else nil.
    func waitChild(_ handle: SessionHandle, timeoutSec: TimeInterval?) -> Int32?
    /// Release transport resources for this handle (idempotent). For an
    /// attached transport this detaches WITHOUT killing the real session.
    func close(_ handle: SessionHandle)
}

/// Errors shared by transport-protocol witnesses.
public enum SessionTransportError: Error, Equatable {
    /// A transport was handed a handle it doesn't own (the `_p(handle)` guard).
    case foreignHandle
}

// MARK: - PtyTransport conformance (additive — the concrete API is untouched)

extension PtyTransport.Handle: SessionHandle {}

extension PtyTransport: SessionTransport {
    /// Downcast the opaque handle to `PtyTransport.Handle` or throw
    /// `foreignHandle`, then delegate to the concrete overload. The concrete
    /// methods (which take `Handle` directly) are unchanged, so every existing
    /// caller and test keeps compiling and behaving identically — Swift's
    /// overload resolution prefers the exact-typed `Handle` overload for
    /// concrete calls and this `SessionHandle` witness for protocol calls.
    private func downcast(_ handle: SessionHandle) throws -> Handle {
        guard let h = handle as? Handle else { throw SessionTransportError.foreignHandle }
        return h
    }
    /// Non-throwing witnesses degrade to a safe default on a foreign handle (a
    /// daemon must never crash on mis-routed I/O), but a foreign handle here is
    /// ALWAYS a wiring bug — `assertionFailure` (stripped in release) surfaces
    /// it immediately in dev/test rather than silently tearing the session down
    /// (review: agy). Returns nil on the safe path.
    private func downcastOrAssert(_ handle: SessionHandle) -> Handle? {
        guard let h = handle as? Handle else {
            assertionFailure("foreign handle routed to PtyTransport — check transportOverride wiring")
            return nil
        }
        return h
    }

    public func writeStdin(_ handle: SessionHandle, _ data: Data) throws -> Int {
        try writeStdin(downcast(handle), data)
    }
    public func readStdout(_ handle: SessionHandle, maxBytes: Int) throws -> Data {
        try readStdout(downcast(handle), maxBytes: maxBytes)
    }
    public func setWinsize(_ handle: SessionHandle, cols: UInt16, rows: UInt16) throws {
        try setWinsize(downcast(handle), cols: cols, rows: rows)
    }
    public func interrupt(_ handle: SessionHandle) {
        guard let h = downcastOrAssert(handle) else { return }
        interrupt(h)
    }
    public func terminate(_ handle: SessionHandle) {
        guard let h = downcastOrAssert(handle) else { return }
        terminate(h)
    }
    public func isAlive(_ handle: SessionHandle) -> Bool {
        guard let h = downcastOrAssert(handle) else { return false }
        return isAlive(h)
    }
    public func waitChild(_ handle: SessionHandle, timeoutSec: TimeInterval?) -> Int32? {
        guard let h = downcastOrAssert(handle) else { return nil }
        return waitChild(h, timeoutSec: timeoutSec)
    }
    public func close(_ handle: SessionHandle) {
        guard let h = downcastOrAssert(handle) else { return }
        close(h)
    }
}
