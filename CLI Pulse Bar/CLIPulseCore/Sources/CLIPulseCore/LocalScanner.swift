#if os(macOS)
import Foundation
import Darwin
import os

/// Scans local processes to detect running AI coding tools.
///
/// This is **process-detection only** — it finds running processes whose command
/// lines match known AI tool patterns.  It does NOT perform provider-native
/// collection (no real quota, remaining, tiers, or reset times).  All
/// `ProviderUsage` instances produced here have `quota=nil` and `remaining=nil`.
///
/// For real quota/tier data, the app relies on the backend/helper cloud path
/// (`APIClient.providers()` → `provider_summary` RPC).
public final class LocalScanner: @unchecked Sendable {
    public static let shared = LocalScanner()

    private static let scanLogger = Logger(subsystem: "com.clipulse", category: "LocalScanner")

    // Patterns for process-based detection of running AI coding tools.
    // NOTE: This is process scanning only — it detects running processes, not
    // provider-native quota/usage data. All results have quota=nil, remaining=nil.
    //
    // Order matters: more-specific patterns must come before less-specific ones
    // for the same keyword (e.g. "Kimi K2" before "Kimi").
    private static let processPatterns: [(provider: String, pattern: String, confidence: String)] = [
        ("Codex", #"\bcodex\b"#, "high"),
        ("Codex", #"\bopenai\b"#, "medium"),
        ("Gemini", #"\bgemini\b"#, "high"),
        ("Claude", #"\bclaude\b"#, "high"),
        ("Cursor", #"\bcursor\b"#, "high"),
        ("OpenCode", #"\bopencode\b"#, "high"),
        ("Copilot", #"\bcopilot\b|\bgithub\.copilot\b"#, "high"),
        ("Ollama", #"\bollama\b"#, "high"),
        ("OpenRouter", #"\bopenrouter\b"#, "high"),
        ("Kilo", #"\bkilo\b|\bkilo[_-]?code\b"#, "high"),
        ("Warp", #"\bwarp\b"#, "medium"),
        ("Augment", #"\baugment\b"#, "medium"),
        ("JetBrains AI", #"\bjetbrains[\s-]?ai\b|\bjbai\b"#, "high"),
        ("Kimi K2", #"\bkimi[\s_-]*k2\b"#, "high"),
        ("Kimi", #"\bkimi\b"#, "high"),
        ("Amp", #"\bamp\b"#, "low"),
        ("MiniMax", #"\bminimax\b"#, "high"),
        ("Alibaba", #"\balibaba\b|\bqwen\b|\btongyi\b"#, "high"),
        ("z.ai", #"\bz\.ai\b|\bzai\b"#, "high"),
        ("Antigravity", #"\bantigravity\b"#, "high"),
        ("Droid", #"\bdroid\b"#, "low"),
        ("Synthetic", #"\bsynthetic\b"#, "medium"),
        ("Kiro", #"\bkiro\b"#, "high"),
        ("Vertex AI", #"\bvertex[\s_-]?ai\b|\bgcloud\b.*\baiplatform\b"#, "high"),
        ("Perplexity", #"\bperplexity\b|\bpplx\b"#, "high"),
        ("Volcano Engine", #"\bvecli\b|\bvolcengine\b|\bdoubao\b|\bvolcano[\s_-]?engine\b|\bark\b.*\bvolc"#, "high"),
    ]

    private static let ignoredPatterns: [String] = [
        #"crashpad"#,
        #"--type=renderer"#,
        #"--type=gpu-process"#,
        #"--utility-sub-type"#,
        #"codex helper"#,
        #"electron framework"#,
        #"\.vscode-server"#,
        #"--ms-enable-electron"#,
        #"node_modules/\.bin"#,
        // The Claude desktop app installs a Chrome native-messaging host bridge
        // whose argv contains the literal "Claude" plus the Chrome extension id.
        // Our `\bclaude\b` provider regex would otherwise create a zombie
        // "Claude" session for the bridge — it's not a coding CLI.
        #"chrome-native-host"#,
        #"fcoeoabgfenejglbffodgkkbkcdhcgfn"#,
        #"com\.anthropic\.claude\.nativehost"#,
        #"Claude\.app/Contents/.*/nativehost"#,
    ]

    private static let confidenceRank: [String: Int] = ["high": 3, "medium": 2, "low": 1]

    /// Pre-compiled regex patterns (compiled once, reused every scan)
    private static let compiledProcessPatterns: [(provider: String, regex: NSRegularExpression, confidence: String)] = {
        processPatterns.compactMap { entry in
            guard let regex = try? NSRegularExpression(pattern: entry.pattern, options: .caseInsensitive) else { return nil }
            return (entry.provider, regex, entry.confidence)
        }
    }()

    private static let compiledIgnorePatterns: [NSRegularExpression] = {
        ignoredPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private init() {}

    /// Scan running processes and return detected AI sessions + provider summary.
    /// - Parameter costRateLookup: Optional closure to look up cost rate per 1K tokens by provider name.
    ///   Falls back to `ProviderKind.defaultCostRate` if nil or if the closure returns nil.
    public func scan(costRateLookup: ((String) -> Double?)? = nil) -> LocalScanResult {
        let rows = listProcesses()
        var sessions: [SessionRecord] = []
        var sessionCPU: [String: Double] = [:]
        var providerUsage: [String: (usage: Int, sessions: Int, cost: Double)] = [:]
        let now = sharedISO8601Formatter.string(from: Date())
        let hostName = ProcessInfo.processInfo.hostName

        // Track best match per PID to deduplicate
        var bestByPID: [String: (provider: String, confidence: String, row: ProcessRow)] = [:]

        for row in rows {
            guard !shouldIgnore(row.command) else { continue }
            guard let (provider, confidence) = detectProvider(row.command) else { continue }

            if let existing = bestByPID[row.pid] {
                let existingRank = Self.confidenceRank[existing.confidence] ?? 0
                let newRank = Self.confidenceRank[confidence] ?? 0
                if newRank > existingRank {
                    bestByPID[row.pid] = (provider, confidence, row)
                }
            } else {
                bestByPID[row.pid] = (provider, confidence, row)
            }
        }

        // Load per-device secret once per scan so we can compute project_hash for sessions
        // whose path we can resolve. Failures here are silent: we just emit project_hash=nil.
        let secret: Data? = (try? UserSecret.loadOrCreate())

        for (pid, match) in bestByPID {
            let row = match.row
            let elapsed = elapsedToSeconds(row.etime)
            let cpu = Double(row.pcpu) ?? 0
            let usage = max(500, Int(Double(elapsed) * max(1.5, cpu + 1.0)))
            let cost = estimateCost(provider: match.provider, usage: usage, rateLookup: costRateLookup)
            // Prefer the basename of the discovered project root when a repo
            // marker (.git/package.json/...) was found nearby — that's strictly
            // a better label than what `guessProject` can derive from argv
            // alone, especially for node-launched CLIs whose argv is full of
            // version dirs and runtime sidecars. Fall back to argv-based
            // inference when no marker is present.
            let projectRoot: String? = guessProjectRoot(row.command)
            let project: String = projectRoot
                .map { ($0 as NSString).lastPathComponent }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? guessProject(row.command)
            let projectHash: String? = {
                guard let secret, let root = projectRoot else { return nil }
                return UserSecret.projectHash(secret: secret, absolutePath: root)
            }()

            let session = SessionRecord(
                id: "local-\(pid)",
                name: prettyName(row.command),
                provider: match.provider,
                project: project,
                device_name: hostName,
                started_at: sharedISO8601Formatter.string(from: Date().addingTimeInterval(-Double(elapsed))),
                last_active_at: now,
                status: "Running",
                total_usage: usage,
                estimated_cost: cost,
                cost_status: cost > 1 ? "warning" : "normal",
                requests: max(1, elapsed / 45),
                error_count: 0,
                collection_confidence: match.confidence,
                project_hash: projectHash
            )
            sessions.append(session)
            sessionCPU[session.id] = cpu

            var entry = providerUsage[match.provider] ?? (usage: 0, sessions: 0, cost: 0)
            entry.usage += usage
            entry.sessions += 1
            entry.cost += cost
            providerUsage[match.provider] = entry
        }

        let providers = providerUsage.map { (name, data) in
            ProviderUsage(
                provider: name,
                today_usage: data.usage,
                week_usage: data.usage,
                estimated_cost_today: data.cost,
                estimated_cost_week: data.cost,
                cost_status_today: "normal",
                cost_status_week: "normal",
                quota: nil,
                remaining: nil,
                status_text: "\(data.sessions) active",
                trend: [],
                recent_sessions: [],
                recent_errors: [],
                metadata: nil
            )
        }.sorted { $0.today_usage > $1.today_usage }

        let totalUsage = sessions.reduce(0) { $0 + $1.total_usage }
        let totalCost = sessions.reduce(0) { $0 + $1.estimated_cost }

        Self.scanLogger.info("scan produced \(sessions.count) sessions across \(providerUsage.count) providers")

        return LocalScanResult(
            sessions: sessions,
            providers: providers,
            totalUsage: totalUsage,
            totalCost: totalCost,
            activeSessionCount: sessions.count,
            sessionCPU: sessionCPU
        )
    }

    // MARK: - Process listing

    private struct ProcessRow {
        let pid: String
        let pcpu: String
        let pmem: String
        let etime: String
        let command: String
    }

    /// Lists running processes via libproc (in-process, no subprocess fork).
    ///
    /// Previous implementation forked /bin/ps, which returned zero rows when
    /// called from the MAS-sandboxed CLIPulseHelper LoginItem even though the
    /// main app's identical call worked. libproc avoids the subprocess hop
    /// entirely and is permitted in the default sandbox for user-owned
    /// processes.
    ///
    /// IMPORTANT: `proc_pidpath` only returns the executable path, not argv.
    /// Many AI CLIs (Claude Code, Codex CLI, Gemini CLI, …) run as
    /// `/usr/local/bin/node /path/to/tool.js` — the executable is `node`, so
    /// pattern-matching on the path alone misses them. We additionally read
    /// `KERN_PROCARGS2` via sysctl to get argv[0..n] and match on the full
    /// command line, which is what the original `ps`-based scanner saw.
    private func listProcesses() -> [ProcessRow] {
        let nowEpoch = Int(Date().timeIntervalSince1970)
        var pidBuf = [pid_t](repeating: 0, count: 8192)
        let bufSize = Int32(pidBuf.count * MemoryLayout<pid_t>.size)
        let bytesWritten = proc_listallpids(&pidBuf, bufSize)
        if bytesWritten <= 0 {
            Self.scanLogger.error("proc_listallpids failed errno=\(errno)")
            return []
        }
        let count = Int(bytesWritten) / MemoryLayout<pid_t>.size
        var rows: [ProcessRow] = []
        rows.reserveCapacity(count)

        var pathBuf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for i in 0..<count {
            let pid = pidBuf[i]
            guard pid > 0 else { continue }

            pathBuf.withUnsafeMutableBufferPointer { _ = memset($0.baseAddress, 0, Int(MAXPATHLEN)) }
            let pathLen = proc_pidpath(pid, &pathBuf, UInt32(MAXPATHLEN))
            guard pathLen > 0 else { continue }
            let path = String(cString: pathBuf)
            guard !path.isEmpty else { continue }

            // Append argv so interpreters like `node`/`python` still show
            // the script name we need to pattern-match on. Silent on
            // failure — we just fall back to the path alone.
            let fullCommand: String = {
                guard let args = Self.processArgs(pid: pid), !args.isEmpty else {
                    return path
                }
                // `path` is the canonical executable; argv[0] is how the
                // caller invoked it (often a wrapper/symlink name like
                // `claude`). Keep both so either can match a pattern.
                let argvStr = args.joined(separator: " ")
                return "\(path) \(argvStr)"
            }()

            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.stride)
            let bsdRead = withUnsafeMutablePointer(to: &bsd) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, ptr, bsdSize)
            }
            let etime: Int
            if bsdRead == bsdSize {
                etime = max(0, nowEpoch - Int(bsd.pbi_start_tvsec))
            } else {
                etime = 60
            }

            // Average CPU% over process lifetime, matching ps's pcpu semantics
            // (100% = one full core). Computed as (user+system cpu time) /
            // wall elapsed. Per-core units; AlertGenerator normalizes by core
            // count before threshold comparison.
            var taskInfo = proc_taskinfo()
            let taskSize = Int32(MemoryLayout<proc_taskinfo>.stride)
            let taskRead = withUnsafeMutablePointer(to: &taskInfo) { ptr -> Int32 in
                proc_pidinfo(pid, PROC_PIDTASKINFO, 0, ptr, taskSize)
            }
            var pcpu = 1.0
            if taskRead == taskSize, etime > 0 {
                let cpuNanos = Double(taskInfo.pti_total_user) + Double(taskInfo.pti_total_system)
                let elapsedNanos = Double(etime) * 1_000_000_000
                pcpu = min(max(cpuNanos / elapsedNanos * 100.0, 0), 10_000)
            }

            rows.append(ProcessRow(
                pid: "\(pid)",
                pcpu: String(format: "%.1f", pcpu),
                pmem: "0.0",
                etime: Self.formatEtime(etime),
                command: fullCommand
            ))
        }
        Self.scanLogger.info("libproc enumeration: \(count) pids, \(rows.count) rows")
        return rows
    }

    /// Read `argv` of a running process via sysctl(KERN_PROCARGS2).
    ///
    /// Layout of the returned buffer on Darwin (see `ps` source):
    ///
    ///   [ int32 argc ]
    ///   [ exec_path \0 ]
    ///   [ padding \0* aligned to next non-null byte ]
    ///   [ argv[0] \0 ] [ argv[1] \0 ] ... [ argv[argc-1] \0 ]
    ///   [ envp[0] \0 ] ...
    ///
    /// We return `argv[0..argc-1]`. Returns nil on sysctl failure (which
    /// happens for processes owned by other users — expected in sandbox).
    nonisolated static func processArgs(pid: pid_t) -> [String]? {
        // Query the kernel's buffer size limit first.
        var argMax: Int32 = 0
        var argMaxSize = MemoryLayout<Int32>.size
        var argMaxMib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        if sysctl(&argMaxMib, 2, &argMax, &argMaxSize, nil, 0) != 0 || argMax <= 0 {
            return nil
        }

        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = Int(argMax)
        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBufferPointer { ptr -> Int32 in
            guard let base = ptr.baseAddress else { return -1 }
            return sysctl(&mib, 3, UnsafeMutableRawPointer(base), &size, nil, 0)
        }
        if result != 0 || size < MemoryLayout<Int32>.size {
            return nil
        }

        // First 4 bytes are argc (little-endian on Darwin).
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { argcBytes in
            buffer.withUnsafeBytes { bufBytes in
                argcBytes.copyMemory(from: UnsafeRawBufferPointer(rebasing: bufBytes.prefix(4)))
            }
        }
        guard argc > 0 else { return [] }

        // Walk past exec_path + padding, then collect `argc` strings.
        var cursor = MemoryLayout<Int32>.size

        // Skip the exec_path C-string.
        while cursor < size, buffer[cursor] != 0 {
            cursor += 1
        }
        // Skip trailing NULs between exec_path and argv[0].
        while cursor < size, buffer[cursor] == 0 {
            cursor += 1
        }

        var args: [String] = []
        args.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard cursor < size else { break }
            let start = cursor
            while cursor < size, buffer[cursor] != 0 {
                cursor += 1
            }
            let byteCount = cursor - start
            if byteCount > 0 {
                let bytes: [UInt8] = buffer[start..<cursor].map { UInt8(bitPattern: $0) }
                if let str = String(bytes: bytes, encoding: .utf8) {
                    args.append(str)
                } else {
                    args.append("")
                }
            } else {
                args.append("")
            }
            // Skip the terminating NUL.
            if cursor < size, buffer[cursor] == 0 {
                cursor += 1
            }
        }
        return args
    }

    private static func formatEtime(_ seconds: Int) -> String {
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if days > 0 {
            return String(format: "%d-%02d:%02d:%02d", days, hours, minutes, secs)
        }
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    // MARK: - Detection

    /// Detect provider from a command string. Returns (providerName, confidence) or nil.
    /// Exposed as internal for testing.
    func detectProvider(_ command: String) -> (String, String)? {
        let lower = command.lowercased()
        var best: (String, String)? = nil
        var bestRank = 0
        let range = NSRange(lower.startIndex..., in: lower)
        for entry in Self.compiledProcessPatterns {
            if entry.regex.firstMatch(in: lower, range: range) != nil {
                let rank = Self.confidenceRank[entry.confidence] ?? 0
                if rank > bestRank {
                    best = (entry.provider, entry.confidence)
                    bestRank = rank
                }
            }
        }
        return best
    }

    /// Exposed at `internal` so `@testable` can exercise the ignore list
    /// without spinning a real process scan. Not part of the public API.
    func shouldIgnore(_ command: String) -> Bool {
        let lower = command.lowercased()
        let range = NSRange(lower.startIndex..., in: lower)
        for regex in Self.compiledIgnorePatterns {
            if regex.firstMatch(in: lower, range: range) != nil {
                return true
            }
        }
        return false
    }

    private func elapsedToSeconds(_ etime: String) -> Int {
        // Format: [[DD-]HH:]MM:SS
        let parts = etime.replacingOccurrences(of: "-", with: ":").split(separator: ":").map(String.init)
        var seconds = 0
        let nums = parts.compactMap { Int($0) }
        switch nums.count {
        case 4: seconds = nums[0] * 86400 + nums[1] * 3600 + nums[2] * 60 + nums[3]
        case 3: seconds = nums[0] * 3600 + nums[1] * 60 + nums[2]
        case 2: seconds = nums[0] * 60 + nums[1]
        case 1: seconds = nums[0]
        default: break
        }
        return max(1, seconds)
    }

    private func estimateCost(provider: String, usage: Int, rateLookup: ((String) -> Double?)? = nil) -> Double {
        let rate = rateLookup?(provider)
            ?? ProviderKind(rawValue: provider)?.defaultCostRate
            ?? 0.001
        return Double(usage) / 1000.0 * rate
    }

    /// Pure version strings like `1.0.1`, `v2.3.4-beta` — never useful as a
    /// project label. Caches the regex object across scans.
    private static let versionDirRegex = try? NSRegularExpression(
        pattern: #"^v?\d+(\.\d+)+[a-z0-9\-]*$"#,
        options: .caseInsensitive
    )

    /// Sidecar/runtime files we never want as a project label.
    private static let sidecarSuffixes: [String] = [
        ".pid", ".sock", ".lock", ".log", ".tmp", ".cache", ".db", ".sqlite",
        ".json", ".yaml", ".yml", ".toml", ".plist",
        ".mjs", ".cjs", ".js", ".ts", ".py", ".rb", ".go", ".rs", ".sh",
        ".env", ".pem", ".key", ".crt", ".p12", ".keychain",
    ]

    /// Reserved infrastructure / build / framework directory names. A user repo
    /// is unlikely to be one of these, so they make a poor project label.
    private static let reservedNames: Set<String> = [
        "bin", "sbin", "lib", "libexec", "share", "etc", "var", "tmp",
        "Contents", "Resources", "MacOS", "Frameworks", "PlugIns", "Helpers",
        "node_modules", "dist", "build", "out", "target",
        ".git", ".claude", ".codex", ".cache", ".config", ".local", ".npm",
        "scripts",
    ]

    /// Walk argv right-to-left and return the first basename that survives a
    /// strict allow rule. Walks up the path components inside each argv token
    /// until the user-root anchor (`/Users` / `/home`) is reached, then moves
    /// to the next argv token. Used only as a fallback when `guessProjectRoot`
    /// did not find a repo marker — a marker-derived basename always wins.
    /// `internal` so unit tests can drive it directly.
    func guessProject(_ command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)

        for part in parts.reversed() {
            guard part.contains("/"),
                  !part.hasPrefix("-"),
                  !part.hasPrefix("/usr"),
                  !part.hasPrefix("/bin"),
                  !part.hasPrefix("/opt") else { continue }

            // Path entirely inside an .app bundle is a dead end — system or
            // third-party app internals are never a useful project label.
            // Skip the whole argv token and try the next one.
            if part.range(of: #"\.app(/|$)"#, options: .regularExpression) != nil { continue }

            let pathComponents = part.split(separator: "/").map(String.init)
            // Walk leaf → root, stopping at the user-root anchors so we don't
            // ever emit `/Users` or `/home` as a label. Returns the first
            // segment that satisfies `isAcceptableProjectName`.
            for component in pathComponents.reversed() {
                if component.isEmpty { continue }
                if component == "Users" || component == "home" { break }
                if isAcceptableProjectName(component) {
                    return component
                }
            }
        }
        return "unknown"
    }

    /// Allow rule for a project label. Returns true only when the name is
    /// plausibly a human-chosen project directory.
    private func isAcceptableProjectName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }

        // Hidden dotfiles / dot-dirs that aren't repo names.
        if name.hasPrefix(".") { return false }

        // Existing secret/token/key filter — keep it.
        let lower = name.lowercased()
        if lower.contains("token") || lower.contains("secret") || lower.contains("key") {
            return false
        }

        // Pure version strings.
        if let regex = Self.versionDirRegex {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            if regex.firstMatch(in: name, options: [], range: range) != nil {
                return false
            }
        }

        // Sidecar / runtime / source-file extensions.
        for suffix in Self.sidecarSuffixes where lower.hasSuffix(suffix) {
            return false
        }

        // Reserved infrastructure / build / framework names. The reservedNames
        // set is small; the cost of an isolated false-negative for a user repo
        // literally called e.g. "scripts" is mitigated by `guessProjectRoot`
        // taking precedence whenever a `.git` marker is present nearby.
        if Self.reservedNames.contains(name) { return false }

        return true
    }

    /// Best-effort absolute project root path inferred from command's path arguments.
    /// Used only to compute project_hash (HMAC) before discarding — never transmitted.
    /// Walks up looking for a marker file; returns nil if no project structure is found.
    private static let projectMarkers = [".git", "package.json", "Cargo.toml", "pyproject.toml", "go.mod", "pom.xml", "Gemfile"]
    /// `internal` so the repo-marker test can assert the basename it returns.
    func guessProjectRoot(_ command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        let fm = FileManager.default
        for part in parts {
            // Look for absolute paths under common user roots
            guard part.hasPrefix("/Users/") || part.hasPrefix("/home/") || part.hasPrefix("/opt/") || part.hasPrefix("/var/") else { continue }
            var dir = (part as NSString).standardizingPath
            // Walk up looking for a project marker
            while dir.count > 1 && dir != "/" && dir != "/Users" && dir != "/home" {
                for marker in Self.projectMarkers {
                    let markerPath = (dir as NSString).appendingPathComponent(marker)
                    if fm.fileExists(atPath: markerPath) {
                        return dir
                    }
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    private func prettyName(_ command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        guard let first = parts.first else { return command }
        let basename = (first as NSString).lastPathComponent
        if basename.count > 30 { return String(basename.prefix(30)) }
        return basename
    }
}

public struct LocalScanResult: Sendable {
    public let sessions: [SessionRecord]
    public let providers: [ProviderUsage]
    public let totalUsage: Int
    public let totalCost: Double
    public let activeSessionCount: Int
    /// Per-session average CPU% over the process's lifetime (per-core units,
    /// 100% = one full core). Keyed by `SessionRecord.id`. Consumed by
    /// `AlertGenerator.generate` where it is normalized against core count.
    public let sessionCPU: [String: Double]

    public init(
        sessions: [SessionRecord],
        providers: [ProviderUsage],
        totalUsage: Int,
        totalCost: Double,
        activeSessionCount: Int,
        sessionCPU: [String: Double] = [:]
    ) {
        self.sessions = sessions
        self.providers = providers
        self.totalUsage = totalUsage
        self.totalCost = totalCost
        self.activeSessionCount = activeSessionCount
        self.sessionCPU = sessionCPU
    }

    public var isEmpty: Bool { sessions.isEmpty }
}
#endif
