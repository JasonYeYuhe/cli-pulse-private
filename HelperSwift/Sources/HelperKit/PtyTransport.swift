import Foundation
import Darwin

/// Swift port of `helper/transports/posix_pty.py:PosixPtyTransport`.
/// Spawns a child under a master/slave PTY pair via `openpty(3)` +
/// `posix_spawn` so the helper can drive Claude Code's TUI exactly
/// the way a real terminal would.
///
/// Why posix_spawn (and not Foundation's `Process`):
///   * `Process` doesn't accept a PTY slave fd as stdin/stdout —
///     it requires Pipes. The Claude TUI then refuses to render
///     because `isatty` returns false on the child side.
///   * `posix_spawn_file_actions_adddup2` lets us wire the slave
///     fd straight onto fds 0/1/2 in the child.
///   * `posix_spawnattr_setpgroup` mirrors the Python helper's
///     `start_new_session=True`: child runs in a new pgid so a
///     SIGINT the user sends doesn't kill the helper daemon.
public final class PtyTransport: @unchecked Sendable {

    /// Per-session live state. Threaded through `SessionHandle.payload`
    /// in the Python implementation; we hold it on a class so the
    /// transport stays stateless.
    public final class Handle: @unchecked Sendable {
        public let sessionId: String
        public let pid: pid_t
        let masterFD: Int32
        private(set) var closed: Bool = false
        private let closeLock = NSLock()
        /// v1.24 Phase 2a (Codex MEDIUM M4): serializes write/read/close on
        /// `masterFD`. The existing `closeLock` only guards the `closed`
        /// flag, not the fd itself — concurrent `writeStdin` and
        /// `markClosed` from different threads could race the fd lifetime.
        /// Acquire `ioLock` BEFORE any read/write/close on `masterFD`.
        let ioLock = NSLock()

        init(sessionId: String, pid: pid_t, masterFD: Int32) {
            self.sessionId = sessionId
            self.pid = pid
            self.masterFD = masterFD
        }

        func markClosed() {
            closeLock.lock(); defer { closeLock.unlock() }
            if closed { return }
            closed = true
            // Best-effort close; ignore errors (the fd may already
            // be invalidated by SIGPIPE / EBADF). Held under ioLock
            // so a concurrent writer/reader sees a consistent fd
            // lifetime (Codex MEDIUM M4).
            ioLock.lock(); defer { ioLock.unlock() }
            Darwin.close(masterFD)
        }

        public var isClosed: Bool {
            closeLock.lock(); defer { closeLock.unlock() }
            return closed
        }
    }

    public enum TransportError: Error, Equatable {
        case emptyArgv
        case openptyFailed(String)
        case spawnFailed(String)
        case readFailed(String)
        case writeFailed(String)
        case ioctlFailed(String)
    }

    /// Default initial PTY window size (Codex MEDIUM M2). Without setting
    /// this at spawn the slave PTY opens 0×0 and ratatui-based CLIs
    /// (Codex etc.) hard-newline after every CJK glyph. 80×24 is the
    /// classic terminal default — callers override per the in-app
    /// terminal's actual viewport.
    public static let defaultCols: UInt16 = 80
    public static let defaultRows: UInt16 = 24

    public init() {}

    // MARK: - lifecycle

    /// Spawn `argv` under a fresh PTY and return a `Handle`. Throws
    /// `TransportError` on any spawn failure; the master fd is
    /// always cleaned up on the failure path.
    ///
    /// `env` is overlaid on the helper's own environment so PATH /
    /// TERM / locale survive. `TERM` defaults to `xterm-256color`
    /// if the caller didn't set it (matches the Python helper —
    /// without TERM, Claude Code's TUI degrades to teletype mode
    /// when the helper itself was launched without a tty, e.g.
    /// from launchd).
    public func start(
        sessionId: String,
        argv: [String],
        env: [String: String] = [:],
        cwd: String? = nil,
        cols: UInt16 = PtyTransport.defaultCols,
        rows: UInt16 = PtyTransport.defaultRows
    ) throws -> Handle {
        guard !argv.isEmpty else { throw TransportError.emptyArgv }

        // openpty allocates a master+slave PTY pair. The Foundation
        // surface doesn't expose openpty so we go to libutil.
        //
        // v1.24 Phase 2a (Codex MEDIUM M2): pass an initial `winsize` so
        // the slave PTY opens at the caller's intended cols/rows. Without
        // this the PTY defaults to 0×0 and ratatui-based CLIs (Codex)
        // hard-newline after every double-width CJK glyph. The slave fd
        // inherits this size when the child does its first read, so
        // setting it on `openpty` is enough — no separate ioctl needed
        // for the initial spawn.
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var initialWinsize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        let openResult = openpty(&masterFD, &slaveFD, nil, nil, &initialWinsize)
        if openResult != 0 {
            throw TransportError.openptyFailed(String(cString: strerror(errno)))
        }

        // Build the child's argv as C strings.
        let argvCStrings: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        defer {
            for p in argvCStrings { if let p { free(p) } }
        }

        // Build the merged environment as C strings.
        var mergedEnv = ProcessInfo.processInfo.environment
        for (k, v) in env { mergedEnv[k] = v }
        if mergedEnv["TERM"] == nil { mergedEnv["TERM"] = "xterm-256color" }
        // v1.24 Phase 2a: COLUMNS/LINES env hints for ncurses fallbacks
        // (e.g. when a child shell doesn't ioctl(TIOCGWINSZ) at startup
        // and relies on env-var probes instead). Caller-supplied env wins
        // if explicitly set, so this is a default not an override.
        if mergedEnv["COLUMNS"] == nil { mergedEnv["COLUMNS"] = String(cols) }
        if mergedEnv["LINES"] == nil { mergedEnv["LINES"] = String(rows) }
        let envStrings: [String] = mergedEnv.map { "\($0.key)=\($0.value)" }
        let envCStrings: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]
        defer {
            for p in envCStrings { if let p { free(p) } }
        }

        // file_actions: dup the slave fd onto stdin/stdout/stderr,
        // then close the master fd in the child.
        var fileActions = posix_spawn_file_actions_t(bitPattern: 0)
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slaveFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, masterFD)
        posix_spawn_file_actions_addclose(&fileActions, slaveFD)
        // chdir if the caller asked for a specific cwd (POSIX 2008
        // adds posix_spawn_file_actions_addchdir_np on macOS 10.15+).
        if let cwd, let cwdC = cwd.cString(using: .utf8) {
            cwdC.withUnsafeBufferPointer { ptr in
                _ = posix_spawn_file_actions_addchdir_np(&fileActions, ptr.baseAddress!)
            }
        }

        // attrs: setpgroup → fresh process group; setsigmask /
        // setsigdefault → reset masked / handled signals so the
        // child sees a clean signal disposition.
        var spawnAttr = posix_spawnattr_t(bitPattern: 0)
        posix_spawnattr_init(&spawnAttr)
        defer { posix_spawnattr_destroy(&spawnAttr) }
        var allSigs = sigset_t()
        sigfillset(&allSigs)
        posix_spawnattr_setsigdefault(&spawnAttr, &allSigs)
        var emptySigs = sigset_t()
        sigemptyset(&emptySigs)
        posix_spawnattr_setsigmask(&spawnAttr, &emptySigs)
        posix_spawnattr_setpgroup(&spawnAttr, 0)
        let flags: Int32 = Int32(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP)
        posix_spawnattr_setflags(&spawnAttr, Int16(flags))

        var pid: pid_t = 0
        let spawnResult = argvCStrings.withUnsafeBufferPointer { argvPtr in
            envCStrings.withUnsafeBufferPointer { envPtr in
                Darwin.posix_spawnp(
                    &pid,
                    argvCStrings[0],
                    &fileActions,
                    &spawnAttr,
                    UnsafeMutablePointer(mutating: argvPtr.baseAddress),
                    UnsafeMutablePointer(mutating: envPtr.baseAddress)
                )
            }
        }
        if spawnResult != 0 {
            Darwin.close(masterFD)
            Darwin.close(slaveFD)
            throw TransportError.spawnFailed(String(cString: strerror(spawnResult)))
        }

        // Slave fd is now owned by the child; close our copy.
        Darwin.close(slaveFD)

        // Set master fd non-blocking for read_stdout.
        let oldFlags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, oldFlags | O_NONBLOCK)

        return Handle(sessionId: sessionId, pid: pid, masterFD: masterFD)
    }

    /// Close the PTY + send SIGTERM to the child's pgid (best-effort).
    public func close(_ handle: Handle) {
        if handle.isClosed { return }
        // Best-effort terminate; the daemon's reap loop will
        // escalate to SIGKILL if the child is wedged.
        if isAlive(handle) {
            killpg(handle.pid, SIGTERM)
        }
        handle.markClosed()
    }

    // MARK: - liveness

    public func isAlive(_ handle: Handle) -> Bool {
        if handle.isClosed { return false }
        var status: Int32 = 0
        let r = waitpid(handle.pid, &status, WNOHANG)
        // 0 = still running (no state change), >0 = terminated and
        // we just reaped, <0 = error (typically ECHILD when already
        // reaped).
        return r == 0
    }

    /// Block until the child exits. `timeoutSec == 0` is a poll;
    /// nil waits forever. Returns the exit status (POSIX wstatus
    /// raw) or nil on timeout.
    @discardableResult
    public func waitChild(_ handle: Handle, timeoutSec: TimeInterval? = nil) -> Int32? {
        if handle.isClosed { return nil }
        if let timeoutSec, timeoutSec == 0 {
            var status: Int32 = 0
            let r = waitpid(handle.pid, &status, WNOHANG)
            return r > 0 ? status : nil
        }
        // Polling loop with sleep — sufficient for the helper's
        // shutdown path, where child exit is observed via the
        // drain loop's read returning EOF.
        let deadline = timeoutSec.map { Date().addingTimeInterval($0) }
        while true {
            var status: Int32 = 0
            let r = waitpid(handle.pid, &status, WNOHANG)
            if r > 0 { return status }
            if r < 0 && errno == ECHILD { return nil }
            if let deadline, Date() >= deadline { return nil }
            usleep(50_000)
        }
    }

    // MARK: - I/O

    /// Write to the PTY master. Returns bytes written, 0 on
    /// EPIPE / EBADF / EIO (peer closed), throws on unexpected
    /// errno.
    ///
    /// Held under `handle.ioLock` so a concurrent reader or closer
    /// can't pull the fd out from under us mid-write (Codex MEDIUM M4).
    @discardableResult
    public func writeStdin(_ handle: Handle, _ data: Data) throws -> Int {
        if data.isEmpty { return 0 }
        handle.ioLock.lock(); defer { handle.ioLock.unlock() }
        if handle.isClosed { return 0 }
        let n: Int = data.withUnsafeBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.write(handle.masterFD, base, data.count)
        }
        if n < 0 {
            switch errno {
            case EPIPE, EBADF, EIO: return 0
            default:
                throw TransportError.writeFailed(String(cString: strerror(errno)))
            }
        }
        return n
    }

    /// Non-blocking read from the PTY master. Returns up to
    /// `maxBytes` bytes; empty Data when nothing is available
    /// (EWOULDBLOCK) OR when the peer has closed (EIO on Darwin).
    ///
    /// Held under `handle.ioLock` (Codex MEDIUM M4) — see `writeStdin`.
    public func readStdout(_ handle: Handle, maxBytes: Int = 4096) throws -> Data {
        handle.ioLock.lock(); defer { handle.ioLock.unlock() }
        if handle.isClosed { return Data() }
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return Darwin.read(handle.masterFD, base, maxBytes)
        }
        if n > 0 { return Data(buf.prefix(n)) }
        if n == 0 { return Data() }                       // EOF
        switch errno {
        case EAGAIN, EWOULDBLOCK: return Data()
        case EIO, EBADF: return Data()                     // child exited, slave closed
        default:
            throw TransportError.readFailed(String(cString: strerror(errno)))
        }
    }

    // MARK: - winsize (v1.24 Phase 2a)

    /// Update the PTY's window size in flight (e.g. when the WKWebView
    /// container resizes). Sends SIGWINCH to the child via the kernel's
    /// TIOCSWINSZ side effect, so ratatui / ncurses CLIs immediately
    /// re-flow their viewport.
    ///
    /// `ioctl(TIOCSWINSZ)` on the MASTER fd propagates to the slave —
    /// no need to touch the slave fd (which we no longer hold anyway).
    /// Held under `handle.ioLock` so it can't race a concurrent close.
    public func setWinsize(_ handle: Handle, cols: UInt16, rows: UInt16) throws {
        handle.ioLock.lock(); defer { handle.ioLock.unlock() }
        if handle.isClosed { return }
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        if ioctl(handle.masterFD, TIOCSWINSZ, &ws) != 0 {
            throw TransportError.ioctlFailed(String(cString: strerror(errno)))
        }
    }

    // MARK: - signals

    public func interrupt(_ handle: Handle) {
        signalPgid(handle, SIGINT)
    }

    public func terminate(_ handle: Handle) {
        signalPgid(handle, SIGTERM)
    }

    private func signalPgid(_ handle: Handle, _ sig: Int32) {
        if handle.isClosed { return }
        if !isAlive(handle) { return }
        // killpg with the leader's pid sends to its process group.
        _ = killpg(handle.pid, sig)
    }
}
