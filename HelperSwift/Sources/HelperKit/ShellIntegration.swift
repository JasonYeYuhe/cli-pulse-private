import Foundation

/// Opt-in shell integration — Swift port of `helper/shell_integration.py`. Wraps
/// FUTURE `claude`/`codex` launches into a CLI-Pulse-owned tmux server so the
/// app can stream their I/O and inject remote input (DEV_PLAN M4.3).
///
/// This is the ONLY way to get real remote INPUT into an externally-launched
/// agent TUI on macOS (TIOCSTI is dead; a bare TUI exposes no IPC). We can't
/// attach to a session that already started outside tmux, so we shim FUTURE
/// launches: a small `claude()` / `codex()` shell function runs the real binary
/// inside a tmux session on `~/.clipulse/tmux.sock`, and the helper's
/// `TmuxTransport` attaches out-of-band in control mode.
///
/// Safety invariants (this writes to the user's shell rc — a STANDING change):
///   * Gated by an explicit opt-in — `install()` is ONLY ever called from a
///     user-driven toggle, never automatically.
///   * The rc edit is an idempotent MARKED BLOCK that only SOURCES a separate
///     init file, so re-install/update never rewrites the rc, and `uninstall()`
///     removes exactly the block.
///   * The shim FAILS OPEN: if tmux is missing, we're already inside a CLI-Pulse
///     tmux, stdin/stdout isn't a tty, or anything errors, it runs the real
///     binary unchanged — a broken integration can NEVER brick the user's
///     `claude`.
public enum ShellIntegration {

    public static let markerBegin = "# >>> cli-pulse shell integration >>>"
    public static let markerEnd = "# <<< cli-pulse shell integration <<<"

    static let clipulseDirName = ".clipulse"
    static let initBasename = "shell-init.sh"
    static let confBasename = "tmux.conf"
    static let sockBasename = "tmux.sock"
    /// Session-name prefix so the helper can enumerate wrapped sessions and a
    /// shim never collides with the user's own tmux sessions.
    public static let sessionPrefix = "clipulse-"
    /// The providers we wrap. Small + explicit — never wrap a general shell.
    static let wrappedProviders = ["claude", "codex"]
    /// rc files we manage, in preference order.
    static let rcCandidates = [".zshrc", ".bashrc", ".bash_profile"]

    // MARK: - paths (home-parameterized for tests)

    static func home(_ override: String?) -> String {
        override ?? NSHomeDirectory()
    }
    public static func clipulseDir(home: String? = nil) -> String {
        (self.home(home) as NSString).appendingPathComponent(clipulseDirName)
    }
    public static func sockPath(home: String? = nil) -> String {
        (clipulseDir(home: home) as NSString).appendingPathComponent(sockBasename)
    }
    public static func initPath(home: String? = nil) -> String {
        (clipulseDir(home: home) as NSString).appendingPathComponent(initBasename)
    }
    public static func confPath(home: String? = nil) -> String {
        (clipulseDir(home: home) as NSString).appendingPathComponent(confBasename)
    }

    // MARK: - tmux binary resolution (M4.4b: prefer the bundled signed tmux)

    /// Path to a tmux bundled ALONGSIDE the helper executable, if present +
    /// executable — `Contents/Helpers/tmux` in the shipped .app. `nil`
    /// otherwise. Unlike the Python version (gated on `sys.frozen`), the Swift
    /// helper is always a compiled binary, so we always probe its own dir — but
    /// via `ExecutablePath.current()` (the resolved on-disk path), NEVER argv[0]
    /// which can point at an attacker-writable CWD.
    static func bundledTmuxPath() -> String? {
        guard let exe = ExecutablePath.current() else { return nil }
        let cand = ((exe as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent("tmux")
        return isExecutableRegularFile(cand) ? cand : nil
    }

    /// Resolve which tmux to use: explicit → bundled next to the helper →
    /// PATH → the Homebrew fallback. Single source of truth for every
    /// tmux-touching entry point.
    public static func resolveTmuxBin(explicit: String? = nil) -> String {
        if let explicit, !explicit.isEmpty { return explicit }
        if let bundled = bundledTmuxPath() { return bundled }
        if let onPath = whichOnPath("tmux") { return onPath }
        return "/opt/homebrew/bin/tmux"
    }

    static func whichOnPath(_ name: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let cand = "\(dir)/\(name)"
            if isExecutableRegularFile(cand) { return cand }
        }
        return nil
    }

    /// True iff `path` is an executable REGULAR file — NOT a searchable
    /// directory. `FileManager.isExecutableFile` returns true for a directory
    /// with the +x (search) bit (e.g. `/bin`), which would then be reported as
    /// "tmux" and pass the shim's `[ -x ]` guard, so `claude` would try to
    /// EXECUTE the directory instead of failing open (review: codex).
    static func isExecutableRegularFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    // MARK: - rendered file contents (pure)

    /// POSIX single-quote a value so it's safe to embed as a shell literal —
    /// wrap in `'…'`, and encode any embedded `'` as `'\''` (review: codex —
    /// these paths are written into shell code SOURCED by every login shell; a
    /// `"`, `$()`, backtick or backslash in a home/tmux path must not become
    /// executable code). More defensive than the Python original, which
    /// interpolates inside double quotes.
    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Minimal tmux config for wrapped sessions — invisible chrome so a wrapped
    /// `claude` looks native; generous scrollback; no surprising key remaps.
    public static func renderTmuxConf() -> String {
        """
        # CLI Pulse wrapped-session tmux config (managed — do not edit).
        set -g status off
        set -g history-limit 50000
        set -g mouse on
        set -g default-terminal "tmux-256color"
        set -g escape-time 10
        set -g focus-events on

        """
    }

    /// POSIX-sh init sourced by the rc block. Defines a wrap helper + one shim
    /// function per provider. Fails open in every degenerate case.
    public static func renderShellInit(tmuxBin: String, sock: String, conf: String) -> String {
        let providerFns = wrappedProviders
            .map { "\($0)() { _clipulse_wrap \($0) \($0) \"$@\"; }" }
            .joined(separator: "\n")
        // Assignment RHS is NOT subject to word-splitting/globbing, and the
        // single-quoted default protects every shell metachar — so a path with
        // spaces / `$` / backticks is inert. `${VAR:-'…'}` keeps the env-var
        // override working (review: codex — was double-quoted → injectable).
        return """
        # CLI Pulse shell integration (managed — do not edit; toggle in the app).
        # Runs future `claude`/`codex` inside a CLI-Pulse tmux so the app can stream I/O
        # and inject remote input. Fails open: runs the real binary if anything is off.
        CLIPULSE_TMUX_BIN=${CLIPULSE_TMUX_BIN:-\(shQuote(tmuxBin))}
        CLIPULSE_TMUX_SOCK=${CLIPULSE_TMUX_SOCK:-\(shQuote(sock))}
        CLIPULSE_TMUX_CONF=${CLIPULSE_TMUX_CONF:-\(shQuote(conf))}

        _clipulse_wrap() {
          # usage: _clipulse_wrap <label> <real-cmd> [args...]
          _clip_label="$1"; shift
          # FAIL OPEN — run the real binary unchanged (never brick the user's command)
          # when: already inside a CLI-Pulse wrap; wrapping disabled; tmux unavailable; OR
          # stdin/stdout is NOT a terminal. The last is CRITICAL: `tmux new-session -A`
          # ATTACHES and needs a controlling tty, so a non-interactive launch (headless
          # `claude -p …`, a pipe, a script, an IDE task) MUST run unwrapped or it breaks.
          if [ -n "$CLIPULSE_WRAP_ACTIVE" ] || [ "$CLIPULSE_WRAP_DISABLE" = "1" ] \\
             || [ ! -t 0 ] || [ ! -t 1 ] || [ ! -x "$CLIPULSE_TMUX_BIN" ]; then
            command "$@"; return $?
          fi
          _clip_sess="\(sessionPrefix)${_clip_label}-$$"
          CLIPULSE_WRAP_ACTIVE=1 "$CLIPULSE_TMUX_BIN" -S "$CLIPULSE_TMUX_SOCK" \\
            -f "$CLIPULSE_TMUX_CONF" new-session -A -s "$_clip_sess" \\
            -e CLIPULSE_WRAP_ACTIVE=1 -- "$@"
        }

        \(providerFns)

        """
    }

    /// The idempotent marked block added to each rc file — sources the init file
    /// only if it exists (so a leftover block after a manual dir delete is inert).
    public static func renderRcBlock(initPath: String) -> String {
        // Single-quote the path (review: codex) — this line is sourced by every
        // login shell; a metachar in the home path must stay inert.
        let q = shQuote(initPath)
        return "\(markerBegin)\n[ -f \(q) ] && . \(q)\n\(markerEnd)\n"
    }

    // MARK: - status

    public struct Status: Sendable, Equatable {
        public let installed: Bool
        public let initPresent: Bool
        public let tmuxBin: String?
        public let rcFilesWithBlock: [String]
        public let sock: String
    }

    static func rcTargets(home: String?) -> [String] {
        let h = self.home(home)
        var targets = rcCandidates
            .map { (h as NSString).appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0) }
        // Always ensure the zsh rc (macOS default login shell) so a first-time
        // user with no rc still gets wrapped.
        let zshrc = (h as NSString).appendingPathComponent(".zshrc")
        if !targets.contains(zshrc) { targets.append(zshrc) }
        return targets
    }

    /// Remove our marked block (and a trailing blank line we may have added).
    /// Tolerant of a missing END marker (truncated file). Mirrors Python
    /// `_strip_block` byte-for-byte.
    static func stripBlock(_ text: String) -> String {
        guard let beginRange = text.range(of: markerBegin) else { return text }
        let begin = beginRange.lowerBound
        let cutEnd: String.Index
        if let endRange = text.range(of: markerEnd, range: begin..<text.endIndex) {
            if let eol = text.range(of: "\n", range: endRange.upperBound..<text.endIndex) {
                cutEnd = eol.upperBound
            } else {
                cutEnd = text.endIndex
            }
        } else {
            // no end marker — drop from begin to EOL of begin (defensive).
            if let eol = text.range(of: "\n", range: begin..<text.endIndex) {
                cutEnd = eol.upperBound
            } else {
                cutEnd = text.endIndex
            }
        }
        let before = trimTrailingNewlines(String(text[text.startIndex..<begin]))
        let after = trimLeadingNewlines(String(text[cutEnd..<text.endIndex]))
        if !before.isEmpty && !after.isEmpty { return before + "\n\n" + after }
        let joined = before.isEmpty ? after : before
        return joined.isEmpty ? "" : joined + "\n"
    }

    private static func trimTrailingNewlines(_ s: String) -> String {
        var out = Substring(s)
        while out.last == "\n" { out = out.dropLast() }
        return String(out)
    }
    private static func trimLeadingNewlines(_ s: String) -> String {
        var out = Substring(s)
        while out.first == "\n" { out = out.dropFirst() }
        return String(out)
    }

    // MARK: - install / uninstall / status

    public enum ShellIntegrationError: Error, Equatable {
        /// The rc file EXISTS but couldn't be read/decoded (invalid UTF-8,
        /// permission denied, is-a-directory). We refuse rather than overwrite
        /// it with just our block (review: codex — a `try? … ?? ""` would
        /// DESTROY the user's rc).
        case rcUnreadable(String)
        /// The rc path is a symlink we couldn't resolve to a real file (a cycle
        /// / dangling chain). Refuse rather than replace the symlink itself
        /// (review: codex).
        case rcUnresolvableSymlink(String)
    }

    /// Read an rc file's contents. Returns nil ONLY when the file is genuinely
    /// ABSENT (→ caller treats as empty); THROWS if it EXISTS but can't be read
    /// or decoded, so we never clobber an unreadable rc. Distinguishing
    /// absent-vs-unreadable via the error CODE (not `fileExists`) correctly
    /// classifies a permission-denied parent too (review: codex).
    static func readRcOrThrow(_ path: String) throws -> String? {
        do {
            return try String(contentsOfFile: path, encoding: .utf8)
        } catch let err as NSError {
            let missing = (err.domain == NSCocoaErrorDomain
                           && (err.code == NSFileReadNoSuchFileError || err.code == NSFileNoSuchFileError))
                || (err.domain == NSPOSIXErrorDomain && err.code == Int(ENOENT))
            if missing { return nil }   // genuinely absent → create fresh
            throw ShellIntegrationError.rcUnreadable("\(path): \(err.localizedDescription)")
        }
    }

    /// Write text to an rc path, FOLLOWING a symlink (chain) so a dotfile
    /// manager's `~/.zshrc -> ~/dotfiles/zshrc` keeps its symlink + inode
    /// (review: codex — an atomic write to the link path would replace the
    /// symlink with a plain file and reset its metadata). When the path is a
    /// symlink we resolve the WHOLE chain to the final real file (matching
    /// Python's `open("w")` follow-the-link semantics) and write atomically
    /// there; a non-symlink path is written directly (no canonicalization).
    static func writeRc(_ text: String, to path: String) throws {
        func isSymlink(_ p: String) -> Bool {
            ((try? FileManager.default.attributesOfItem(atPath: p))?[.type]
                as? FileAttributeType) == .typeSymbolicLink
        }
        var target = path
        if isSymlink(path) {
            target = (path as NSString).resolvingSymlinksInPath
            // On a cycle / unresolvable chain, resolvingSymlinksInPath returns
            // the ORIGINAL path (still a symlink). Refuse rather than replace
            // the symlink with a plain file (review: codex).
            if isSymlink(target) {
                throw ShellIntegrationError.rcUnresolvableSymlink(path)
            }
        }
        try text.write(toFile: target, atomically: true, encoding: .utf8)
    }

    /// Write the init file + tmux.conf under ~/.clipulse and add the idempotent
    /// marked block to the shell rc(s). NEVER call except from an explicit user
    /// opt-in. Returns the resulting status.
    @discardableResult
    public static func install(home: String? = nil, tmuxBin: String? = nil,
                               rcFiles: [String]? = nil) throws -> Status {
        let h = self.home(home)
        let tb = resolveTmuxBin(explicit: tmuxBin)
        let dir = clipulseDir(home: h)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // 0700 — the dir holds the tmux CONTROL socket, which can inject input
        // into the user's agent sessions; keep it strictly user-only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        let initP = initPath(home: h)
        let confP = confPath(home: h)
        let sock = sockPath(home: h)
        try renderTmuxConf().write(toFile: confP, atomically: true, encoding: .utf8)
        try renderShellInit(tmuxBin: tb, sock: sock, conf: confP)
            .write(toFile: initP, atomically: true, encoding: .utf8)
        let block = renderRcBlock(initPath: initP)
        let targets = rcFiles ?? rcTargets(home: h)
        for rc in targets {
            let existing = try readRcOrThrow(rc) ?? ""   // throws if unreadable
            let stripped = trimTrailingNewlines(stripBlock(existing))  // idempotent
            let new = (stripped.isEmpty ? "" : stripped + "\n\n") + block
            try writeRc(new, to: rc)
        }
        return status(home: h, rcFiles: targets)
    }

    /// Remove the marked block from every rc file and (optionally) the managed
    /// ~/.clipulse files. Idempotent — safe if never installed.
    @discardableResult
    public static func uninstall(home: String? = nil, rcFiles: [String]? = nil,
                                 removeFiles: Bool = true) throws -> Status {
        let h = self.home(home)
        let targets = rcFiles ?? rcTargets(home: h)
        for rc in targets {
            guard let text = try readRcOrThrow(rc) else { continue }  // absent → skip; unreadable → throw
            let new = stripBlock(text)
            if new != text {
                try writeRc(new, to: rc)
            }
        }
        if removeFiles {
            for p in [initPath(home: h), confPath(home: h)] {
                try? FileManager.default.removeItem(atPath: p)
            }
        }
        return status(home: h, rcFiles: targets)
    }

    public static func status(home: String? = nil, tmuxBin: String? = nil,
                              rcFiles: [String]? = nil) -> Status {
        let h = self.home(home)
        let initP = initPath(home: h)
        let targets = rcFiles ?? rcTargets(home: h)
        var withBlock: [String] = []
        for rc in targets {
            // status() is read-only + best-effort — an unreadable rc simply
            // isn't counted (never throws here; install/uninstall are the
            // mutating paths that refuse to clobber).
            if let text = try? String(contentsOfFile: rc, encoding: .utf8), text.contains(markerBegin) {
                withBlock.append(rc)
            }
        }
        let initExists = FileManager.default.fileExists(atPath: initP)
        // Report a tmux that ACTUALLY EXISTS — an EXECUTABLE explicit path, the
        // bundled binary, or one on PATH — but NEVER the may-not-exist Homebrew
        // fallback from resolveTmuxBin (which would falsely read "installed"),
        // and never a non-existent EXPLICIT path (review: codex). nil →
        // genuinely "tmux not found".
        let reportedTmux = [tmuxBin, bundledTmuxPath(), whichOnPath("tmux")]
            .compactMap { $0 }
            .first { !$0.isEmpty && isExecutableRegularFile($0) }
        return Status(
            installed: !withBlock.isEmpty && initExists,
            initPresent: initExists,
            tmuxBin: reportedTmux,
            rcFilesWithBlock: withBlock,
            sock: sockPath(home: h)
        )
    }

    /// Enumerate CLI-Pulse-wrapped tmux sessions (name starts with the prefix).
    /// Returns [] if the socket/server isn't up or tmux is unavailable.
    public static func listWrappedSessions(tmuxBin: String? = nil, sock: String? = nil) -> [String] {
        let tb = resolveTmuxBin(explicit: tmuxBin)
        let sk = sock ?? sockPath()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tb)
        proc.arguments = ["-S", sk, "list-sessions", "-F", "#{session_name}"]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        let sem = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in sem.signal() }
        do { try proc.run() } catch { return [] }
        try? outPipe.fileHandleForWriting.close()
        if sem.wait(timeout: .now() + 5.0) == .timedOut {
            proc.terminate()
            _ = sem.wait(timeout: .now() + 1.0)
            try? outPipe.fileHandleForReading.close()
            return []
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        try? outPipe.fileHandleForReading.close()
        if proc.terminationStatus != 0 { return [] }
        return (String(data: out, encoding: .utf8) ?? "")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0.hasPrefix(sessionPrefix) }
    }
}
