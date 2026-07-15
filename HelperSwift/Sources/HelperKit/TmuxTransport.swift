import Foundation
import Darwin

/// tmux control-mode `SessionTransport` — Swift port of
/// `helper/transports/tmux.py:TmuxTransport`. Drives a session running inside a
/// CLI-Pulse-owned tmux server on a dedicated socket, so the helper can control
/// an EXTERNALLY-launched claude/codex that was wrapped into tmux (the M4 "full
/// I/O" direction), OR attach to an already-running same-user tmux session.
///
///   * OUTPUT is read out-of-band from a persistent `tmux -C attach` control
///     client: tmux emits `%output %<pane> <data>` lines; we un-escape and
///     buffer the bytes so `readStdout` stays byte-exact and non-blocking.
///   * INPUT is injected with `send-keys -H <hex>` (raw bytes, exact).
///   * resize / interrupt / terminate map to resize-window / send-keys C-c /
///     kill-session.
///
/// Preserves the 6 review-caught M4.2 bugs (PR #345, agy+codex): (1) reader
/// decodes the `%output` payload BEFORE taking the buffer lock; (2) writeStdin
/// returns bytes ACTUALLY written, breaking on the first failed 512-byte chunk;
/// (3) the control client is reaped (stdin EOF → terminate → wait → kill →
/// wait); (4) `.`/`:` in a session id are sanitized to `_` for tmux targeting
/// while the handle keeps the ORIGINAL id as its label; (5) resize clamps dims
/// to [1, 32767]; (6) subprocess failures are wrapped as `TmuxTransportError`.
///
/// tmux control-mode escaping (empirically pinned, tmux 3.6): only some bytes
/// are octal-escaped `\ooo`; a literal backslash is doubled `\\`; CR/LF,
/// printable ASCII and UTF-8 pass raw — so a `\` in the stream is ALWAYS `\\`
/// or `\ooo`, unambiguous.
///
/// CALLER CONTRACT (Python parity — the per-`_TmuxPayload` lock has the same
/// scope): serialization is per-HANDLE, not per-tmux-target. Create at most ONE
/// handle per (socket, tmux target) — the manager enforces this via
/// attach-idempotency on session_id. Two handles for the same target could
/// interleave their I/O or race each other's lifecycle.
public final class TmuxTransport: SessionTransport, @unchecked Sendable {

    public enum TmuxTransportError: Error, Equatable {
        case emptyArgv
        case sessionNotFound(String)
        case commandFailed(String)
        case spawnFailed(String)
    }

    /// Per-session live state — the Swift analogue of Python `_TmuxPayload`.
    public final class Handle: SessionHandle, @unchecked Sendable {
        /// The ORIGINAL manager session id (label) — kept verbatim even though
        /// `tmuxSession` sanitizes `.`/`:` for tmux targeting (review bug #4).
        public let sessionId: String
        /// tmux never gives us a child pid; an attached session has no owned
        /// process on our side → 0 (surfaced in listSessions).
        public let pid: pid_t = 0
        /// The sanitized tmux target name used for every tmux command.
        let tmuxSession: String
        let control: Process
        let controlStdin: FileHandle
        /// The control client's stdout — held so `close()` can force EOF on the
        /// reader thread (Thread.cancel can't interrupt a blocked availableData).
        let controlStdout: FileHandle
        /// True when WE created the session (`start`) → close/terminate may
        /// kill it. False when we ATTACHED to a pre-existing one → close must
        /// NEVER kill the user's real session.
        let ownsSession: Bool

        private let bufLock = NSLock()
        private var buffer = Data()
        private let stateLock = NSLock()
        private var _closed = false
        private var _closeRequested = false
        /// True once WE issued a kill-session for this target — accessed ONLY
        /// under `ioLock` (terminate + close are both ioLock-serialized), so no
        /// separate lock. Prevents close() re-killing a target NAME that may
        /// have been reused after terminate() already killed it (review: codex).
        var killIssued = false
        /// Serializes MUTATING tmux ops on this session (write / resize /
        /// interrupt / terminate / close) so two concurrent `send-keys` calls
        /// from the manager can't interleave their 512-byte chunks and can't
        /// race a `close()` mid-write (review: codex — mirrors PtyTransport's
        /// per-handle ioLock). Read-only ops (readStdout / isAlive) don't take
        /// it. NEVER acquire it from a method the ioLock-holders call internally
        /// (e.g. isAlive) — NSLock isn't recursive.
        let ioLock = NSLock()
        var reader: Thread?

        init(sessionId: String, tmuxSession: String, control: Process,
             controlStdin: FileHandle, controlStdout: FileHandle, ownsSession: Bool) {
            self.sessionId = sessionId
            self.tmuxSession = tmuxSession
            self.control = control
            self.controlStdin = controlStdin
            self.controlStdout = controlStdout
            self.ownsSession = ownsSession
        }

        public var isClosed: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return _closed
        }
        /// Set closed exactly once; returns true if THIS call flipped it.
        func markClosed() -> Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            if _closed { return false }
            _closed = true
            return true
        }
        /// A close has been REQUESTED (set before close() acquires ioLock) so a
        /// long in-flight write can observe it BETWEEN chunks and bail early,
        /// bounding close()'s starvation to a single command timeout instead of
        /// a whole ~1 MiB paste (review: codex).
        func requestClose() { stateLock.lock(); _closeRequested = true; stateLock.unlock() }
        var isCloseRequested: Bool {
            stateLock.lock(); defer { stateLock.unlock() }
            return _closeRequested
        }
        func appendOutput(_ data: Data) {
            bufLock.lock(); defer { bufLock.unlock() }
            buffer.append(data)
        }
        /// Take up to maxBytes from the FRONT of the buffer (byte-exact,
        /// non-blocking).
        func drain(maxBytes: Int) -> Data {
            bufLock.lock(); defer { bufLock.unlock() }
            if buffer.isEmpty { return Data() }
            let take = buffer.prefix(maxBytes)
            buffer.removeFirst(take.count)
            return Data(take)
        }
    }

    private let socketPath: String
    private let tmuxBin: String
    private let defaultCols: Int
    private let defaultRows: Int
    /// Per-one-shot command timeout (Python `_tmux` default 5s).
    private let commandTimeout: TimeInterval

    public init(socketPath: String, tmuxBin: String? = nil,
                defaultCols: Int = 120, defaultRows: Int = 30,
                commandTimeout: TimeInterval = 5.0) {
        self.socketPath = socketPath
        self.tmuxBin = tmuxBin ?? TmuxTransport.whichTmux()
        self.defaultCols = defaultCols
        self.defaultRows = defaultRows
        self.commandTimeout = commandTimeout
    }

    static func whichTmux() -> String {
        // PATH probe; the bundled-tmux resolver (PR C) supersedes this for the
        // shipped .app. /opt/homebrew/bin/tmux is the Apple-silicon Homebrew
        // default fallback.
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let candidate = "\(dir)/tmux"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/opt/homebrew/bin/tmux"
    }

    // MARK: - control-mode byte unescaping (Python unescape_control_output)

    /// Reconstruct exact bytes from a tmux control-mode `%output` payload.
    /// `\ooo` (backslash + EXACTLY 3 octal digits) → that byte; `\\` → `\`;
    /// everything else literal; a lone/invalid trailing backslash is emitted
    /// verbatim (defensive — tmux never produces one).
    static func unescapeControlOutput(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        let bytes = [UInt8](data)
        var i = 0
        let n = bytes.count
        func isOctal(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x37 }
        while i < n {
            let b = bytes[i]
            if b == 0x5C && i + 1 < n {            // backslash
                let nxt = bytes[i + 1]
                if nxt == 0x5C {                   // \\ → \
                    out.append(0x5C); i += 2; continue
                }
                if isOctal(nxt) && i + 3 < n && isOctal(bytes[i + 2]) && isOctal(bytes[i + 3]) {
                    let val = (Int(bytes[i + 1] - 0x30) << 6)
                        | (Int(bytes[i + 2] - 0x30) << 3)
                        | Int(bytes[i + 3] - 0x30)
                    out.append(UInt8(val & 0xFF)); i += 4; continue
                }
            }
            out.append(b); i += 1
        }
        return out
    }

    // MARK: - tmux command helpers

    private struct CommandResult { let status: Int32; let stdout: Data; let stderr: Data }

    /// Run a one-shot `tmux -S <sock> <args…>`, capture output, enforce a
    /// timeout. Any spawn/wait failure is wrapped as `.commandFailed` (bug #6).
    @discardableResult
    private func tmux(_ args: [String], timeout: TimeInterval? = nil) throws -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxBin)
        proc.arguments = ["-S", socketPath] + args
        let outPipe = Pipe(); let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        proc.standardInput = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do {
            try proc.run()
        } catch {
            throw TmuxTransportError.commandFailed("spawn \(tmuxBin): \(error)")
        }
        // Close the PARENT's copy of each pipe's write end now that the child
        // has inherited its own — else `readDataToEndOfFile` below never sees
        // EOF (Foundation doesn't auto-close the parent ends) and would hang.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        if sem.wait(timeout: .now() + (timeout ?? commandTimeout)) == .timedOut {
            proc.terminate()
            // SIGKILL fallback (review: agy) — if the child ignores SIGTERM it
            // would never exit, leaking the Process + its fds (Foundation
            // retains a running Process). Escalate exactly like close().
            if sem.wait(timeout: .now() + 1.0) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = sem.wait(timeout: .now() + 1.0)
            }
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            throw TmuxTransportError.commandFailed("tmux \(args.first ?? "") timed out")
        }
        // Commands here produce tiny output (< pipe buffer), so reading after
        // exit can't deadlock.
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        let err = errPipe.fileHandleForReading.readDataToEndOfFile()
        try? outPipe.fileHandleForReading.close()
        try? errPipe.fileHandleForReading.close()
        return CommandResult(status: proc.terminationStatus, stdout: out, stderr: err)
    }

    /// Spawn the persistent `tmux -C attach -t <session>` control client. stdin
    /// MUST stay open (control mode's command channel — EOF → detach + output
    /// stops). Wrapped as `.spawnFailed` (bug #6).
    private func spawnControlClient(session: String) throws -> (Process, FileHandle, FileHandle) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxBin)
        proc.arguments = ["-S", socketPath, "-C", "attach", "-t", session]
        let stdinPipe = Pipe(); let stdoutPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw TmuxTransportError.spawnFailed("tmux -C attach: \(error)")
        }
        // Close the parent's copy of the ends we DON'T use: the child reads its
        // own stdin end and writes its own stdout end. Leaving the parent's
        // stdout WRITE end open would keep the reader thread's `availableData`
        // from ever seeing EOF after the control client exits (a per-session
        // reader-thread leak in the long-running daemon).
        try? stdinPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()
        return (proc, stdinPipe.fileHandleForWriting, stdoutPipe.fileHandleForReading)
    }

    private func startReader(handle: Handle, stdout: FileHandle) -> Thread {
        let t = Thread {
            var pending = Data()
            while true {
                let chunk = stdout.availableData
                if chunk.isEmpty { break }   // EOF (control client detached)
                pending.append(chunk)
                // Split into complete newline-delimited control lines.
                while let nl = pending.firstIndex(of: 0x0A) {
                    var line = pending.subdata(in: pending.startIndex..<nl)
                    pending.removeSubrange(pending.startIndex...nl)
                    // Strip a trailing CR (control lines are CRLF-terminated).
                    if line.last == 0x0D { line.removeLast() }
                    // Only %output lines carry pane bytes: `%output %<pane> <data>`.
                    let prefix = Data("%output ".utf8)
                    guard line.starts(with: prefix) else { continue }
                    // split(" ", 2): [%output][%<pane>][<data…>] — data may
                    // itself contain spaces, so only split off the first 3.
                    let afterPrefix = line.subdata(in: (line.startIndex + prefix.count)..<line.endIndex)
                    guard let sp = afterPrefix.firstIndex(of: 0x20) else { continue }
                    let payload = afterPrefix.subdata(in: (sp + 1)..<afterPrefix.endIndex)
                    // Decode BEFORE taking the buffer lock (review bug #1 — no
                    // lost data / minimal lock hold).
                    let decoded = TmuxTransport.unescapeControlOutput(payload)
                    handle.appendOutput(decoded)
                }
            }
        }
        t.name = "tmux-ctl-reader"
        t.stackSize = 512 * 1024
        return t
    }

    // MARK: - session creation (transport-specific, not on the protocol)

    /// Create a NEW detached tmux session running `argv`, then attach control
    /// mode. owns_session = true → close/terminate may kill it.
    @discardableResult
    public func start(sessionId: String, argv: [String],
                      env: [String: String] = [:], cwd: String? = nil,
                      envRemove: Set<String> = []) throws -> Handle {
        guard !argv.isEmpty else { throw TmuxTransportError.emptyArgv }
        let target = TmuxTransport.sanitize(sessionId)
        var cmd = ["new-session", "-d", "-s", target,
                   "-x", String(defaultCols), "-y", String(defaultRows)]
        if let cwd { cmd += ["-c", cwd] }
        // env_remove parity (review: codex): tmux can't truly unset an inherited
        // var, so best-effort blank it (`-e KEY=`). The wrap use-case relies on
        // the user's own login env, so this is mostly N/A — kept for parity.
        for k in envRemove.sorted() { cmd += ["-e", "\(k)="] }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) { cmd += ["-e", "\(k)=\(v)"] }
        cmd += ["--"] + argv
        let r = try tmux(cmd)
        if r.status != 0 {
            throw TmuxTransportError.commandFailed(
                "new-session: \(String(data: r.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")")
        }
        return try attach(session: target, ownsSession: true, label: sessionId)
    }

    /// Attach control mode to an ALREADY-running same-user tmux session (the
    /// "free win"). `sessionId` is our label; `tmuxSessionName` is the target
    /// inside the tmux server on `socketPath`. owns_session = FALSE → close
    /// NEVER kills it.
    @discardableResult
    public func attachExisting(sessionId: String, tmuxSessionName: String) throws -> Handle {
        let target = TmuxTransport.sanitize(tmuxSessionName)
        let has = try tmux(["has-session", "-t", target])
        if has.status != 0 {
            throw TmuxTransportError.sessionNotFound(tmuxSessionName)
        }
        return try attach(session: target, ownsSession: false, label: sessionId)
    }

    private func attach(session: String, ownsSession: Bool, label: String) throws -> Handle {
        let (proc, stdin, stdout) = try spawnControlClient(session: session)
        let handle = Handle(sessionId: label, tmuxSession: session, control: proc,
                            controlStdin: stdin, controlStdout: stdout, ownsSession: ownsSession)
        let reader = startReader(handle: handle, stdout: stdout)
        handle.reader = reader
        reader.start()
        return handle
    }

    /// `.`/`:` mangle tmux target names → sanitize for addressing (bug #4).
    static func sanitize(_ id: String) -> String {
        id.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private func payload(_ handle: SessionHandle) throws -> Handle {
        guard let h = handle as? Handle else { throw SessionTransportError.foreignHandle }
        return h
    }

    // MARK: - SessionTransport

    public func writeStdin(_ handle: SessionHandle, _ data: Data) throws -> Int {
        let p = try payload(handle)
        if data.isEmpty { return 0 }
        // Serialize the whole chunked send so two concurrent writes can't
        // interleave and a close() can't tear a write mid-way (review: codex).
        p.ioLock.lock(); defer { p.ioLock.unlock() }
        if p.isClosed { return 0 }
        if !isAlive(handle) { return 0 }   // isAlive takes NO ioLock — no recursion
        // send-keys -H <hex …> injects raw bytes exactly; chunk at 512 so a huge
        // paste doesn't blow the argv limit. Return bytes ACTUALLY written,
        // breaking on the first failed chunk (review bug #2).
        let bytes = [UInt8](data)
        let step = 512
        var written = 0
        var off = 0
        while off < bytes.count {
            // Bail if a close was requested mid-paste so we don't starve close()
            // for the whole payload (review: codex) — bounds its wait to one
            // command timeout.
            if p.isCloseRequested { break }
            let end = min(off + step, bytes.count)
            let hexes = bytes[off..<end].map { String(format: "%02x", $0) }
            let r = try tmux(["send-keys", "-t", p.tmuxSession, "-H"] + hexes)
            if r.status != 0 { break }
            written += (end - off)
            off = end
        }
        return written
    }

    public func readStdout(_ handle: SessionHandle, maxBytes: Int) throws -> Data {
        try payload(handle).drain(maxBytes: maxBytes)
    }

    public func setWinsize(_ handle: SessionHandle, cols: UInt16, rows: UInt16) throws {
        let p = try payload(handle)
        p.ioLock.lock(); defer { p.ioLock.unlock() }
        if p.isClosed { return }
        // Clamp to [1, 32767] (review bug #5). failure-soft: a resize must
        // never kill the session, so ignore the status.
        let c = max(1, min(Int(cols), 32767))
        let r = max(1, min(Int(rows), 32767))
        _ = try? tmux(["resize-window", "-t", p.tmuxSession, "-x", String(c), "-y", String(r)])
    }

    public func interrupt(_ handle: SessionHandle) {
        guard let p = try? payload(handle) else { return }
        p.ioLock.lock(); defer { p.ioLock.unlock() }
        // Gate on isClosed (review: codex) — a stale non-owning handle must NOT
        // send Ctrl-C to the user's live session AFTER we've detached.
        if p.isClosed { return }
        _ = try? tmux(["send-keys", "-t", p.tmuxSession, "C-c"])
    }

    public func terminate(_ handle: SessionHandle) {
        guard let p = try? payload(handle) else { return }
        p.ioLock.lock(); defer { p.ioLock.unlock() }
        // Gate on isClosed (review: codex) — after close(), a stale OWNING
        // handle must NOT re-kill a tmux target name that may have been REUSED
        // by a different session. Kill ONLY a session we own AND still hold,
        // and record it so close() doesn't issue a SECOND kill for a name that
        // may have been reused in between (review: codex — kill-once).
        if p.isClosed || p.killIssued { return }
        if p.ownsSession {
            _ = try? tmux(["kill-session", "-t", p.tmuxSession])
            p.killIssued = true
        }
    }

    public func isAlive(_ handle: SessionHandle) -> Bool {
        guard let p = try? payload(handle) else { return false }
        if p.isClosed { return false }
        return ((try? tmux(["has-session", "-t", p.tmuxSession]))?.status ?? 1) == 0
    }

    public func waitChild(_ handle: SessionHandle, timeoutSec: TimeInterval?) -> Int32? {
        let deadline = timeoutSec.map { ProcessInfo.processInfo.systemUptime + $0 }
        while isAlive(handle) {
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return nil }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // tmux drops the session when its command exits; the exact code isn't
        // recoverable after teardown, so report 0 for a clean gone-away.
        return 0
    }

    public func close(_ handle: SessionHandle) {
        guard let p = try? payload(handle) else { return }
        // Signal a long in-flight write to bail between chunks BEFORE we block
        // on ioLock, so close() isn't starved for a whole ~1 MiB paste
        // (review: codex).
        p.requestClose()
        // Serialize against in-flight writes/resizes (review: codex) so we never
        // tear a write, then flip closed exactly once.
        p.ioLock.lock(); defer { p.ioLock.unlock() }
        guard p.markClosed() else { return }   // idempotent
        // Kill ONLY if we own it AND terminate() didn't already (review: codex —
        // kill-once, avoids re-killing a reused target name).
        if p.ownsSession && !p.killIssued {
            _ = try? tmux(["kill-session", "-t", p.tmuxSession])
            p.killIssued = true
        }
        // EOF the control stdin → the client detaches (%exit).
        try? p.controlStdin.close()
        // Reap the control client: terminate → wait(1s) → kill → wait(1s)
        // (review bug #3 — no zombie control clients). When the process dies the
        // kernel closes its stdout WRITE end; the parent already closed its copy
        // (spawnControlClient), so the reader's read end now has NO open writers
        // → its blocked `availableData` returns EOF and the thread breaks. We do
        // NOT close the read handle from here to unblock it — closing a
        // FileHandle another thread is mid-read on can raise an uncatchable
        // Foundation exception (review: codex — reap-driven EOF instead).
        if p.control.isRunning {
            p.control.terminate()
            if !waitProcess(p.control, timeout: 1.0) {
                kill(p.control.processIdentifier, SIGKILL)
                _ = waitProcess(p.control, timeout: 1.0)
            }
        }
        // Bounded-join the reader so we don't leak a thread across many
        // attach/close cycles in the daemon; then it's safe to close the read
        // handle (the reader is done, no concurrent read).
        if let reader = p.reader {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.0
            while !reader.isFinished && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if reader.isFinished { try? p.controlStdout.close() }
        } else {
            try? p.controlStdout.close()
        }
    }

    /// Block up to `timeout` for a Process to exit. Returns true if it exited.
    private func waitProcess(_ proc: Process, timeout: TimeInterval) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while proc.isRunning {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return true
    }
}
