import Foundation
import Darwin

/// Slice 2a — port of `helper/system_collector.py`'s session-detection
/// pipeline. Runs `ps -axo pid=,pcpu=,pmem=,etime=,command=`, classifies
/// each row by provider (Claude / Codex / Gemini / Cursor / OpenCode /
/// Copilot / …), filters out helper / renderer / wrapper noise,
/// builds `CollectedSession` rows, dedupes by (provider, project), and
/// returns the top 12 sorted by CPU then last-active.
///
/// Mirrors Python wire shape exactly — provider names are capitalized
/// (`"Claude"` not `"claude"`); `confidence` strings use `"high"`,
/// `"medium"`, `"low"`.
public struct SessionDetector: Sendable {

    // MARK: - Configuration

    /// (provider, regex pattern, confidence). Order matters: the first
    /// matching pattern wins. Mirrors `system_collector.py::PROCESS_PATTERNS`
    /// 1:1 — drift here would silently misclassify processes that were
    /// detected correctly by the Python helper.
    static let providerPatterns: [(provider: String, pattern: String, confidence: String)] = [
        ("Codex", #"\bcodex\b"#, "high"),
        ("Codex", #"\bopenai\b"#, "medium"),
        ("Gemini", #"\bgemini\b"#, "high"),
        ("Gemini", #"\bgoogle-generativeai\b"#, "medium"),
        ("Claude", #"\bclaude\b"#, "high"),
        ("Cursor", #"\bcursor\b"#, "high"),
        ("OpenCode", #"\bopencode\b"#, "high"),
        ("Droid", #"\bdroid\b"#, "low"),
        ("Antigravity", #"\bantigravity\b"#, "high"),
        // `agy` is the Antigravity CLI that CLI Pulse spawns as the managed
        // Gemini-on-plan wrapper (GeminiSpawner). Without this, every managed
        // Gemini session (process `.../agy`, no "gemini" substring) is invisible
        // to the system-wide session/Swarm scan. Placed AFTER the explicit
        // "antigravity" pattern (first-match-wins) so a full Antigravity reference
        // still classifies as Antigravity, while the bare `agy` binary classifies
        // as Gemini (the provider the user selected).
        ("Gemini", #"\bagy\b"#, "high"),
        ("Copilot", #"\bcopilot\b|\bgithub.copilot\b"#, "high"),
        ("z.ai", #"\bz\.ai\b|\bzai\b"#, "high"),
        ("MiniMax", #"\bminimax\b"#, "high"),
        ("Augment", #"\baugment\b"#, "medium"),
        ("JetBrains AI", #"\bjetbrains[\s-]?ai\b|\bjbai\b"#, "high"),
        ("Kimi K2", #"\bkimi[\s_-]*k2\b"#, "high"),
        ("Kimi", #"\bkimi\b"#, "medium"),
        ("Amp", #"\bamp\b"#, "low"),
        ("Synthetic", #"\bsynthetic\b"#, "medium"),
        ("Warp", #"\bwarp\b"#, "medium"),
        ("Kilo", #"\bkilo\b|\bkilo[_-]?code\b"#, "high"),
        ("Ollama", #"\bollama\b"#, "high"),
        ("OpenRouter", #"\bopenrouter\b"#, "high"),
        ("Alibaba", #"\balibaba\b|\bqwen\b|\btongyi\b"#, "high"),
        ("Kiro", #"\bkiro\b"#, "high"),
        ("Vertex AI", #"\bvertex[\s_-]?ai\b"#, "high"),
        ("Perplexity", #"\bperplexity\b"#, "high"),
        ("Volcano Engine", #"\bvolcano[\s_-]?engine\b|\bvolcengine\b"#, "high"),
    ]

    /// Patterns that DROP a row before provider classification — Chromium
    /// renderer/gpu subprocesses, Codex helper / app-server-broker, the
    /// Claude desktop disclaimer wrapper, etc. Mirrors Python
    /// `IGNORED_COMMAND_PATTERNS` 1:1.
    static let ignoredCommandPatterns: [String] = [
        #"crashpad"#,
        #"--type=renderer"#,
        #"--type=gpu-process"#,
        #"--utility-sub-type"#,
        #"codex helper"#,
        #"electron framework"#,
        #"\.vscode-server"#,
        #"--ms-enable-electron"#,
        #"node_modules/\.bin"#,
        #"contents/helpers/disclaimer"#,
        #"codex computer use\.app"#,
        #"skycomputeruseclient"#,
        #"app-server-broker"#,
        #"app-server-launcher"#,
    ]

    /// Project marker files in order of specificity. First marker
    /// found in the path's ancestors wins.
    static let projectMarkers: [String] = [
        "package.json",
        "Cargo.toml",
        "go.mod",
        "pyproject.toml",
        "setup.py",
        "Makefile",
        "CMakeLists.txt",
        ".git",
    ]

    /// Confidence ranking for dedup tie-breaking — higher beats lower.
    static let confidenceRank: [String: Int] = ["high": 3, "medium": 2, "low": 1]

    // MARK: - Test hooks

    public struct TestHooks: Sendable {
        /// Returns the raw stdout of `ps -axo pid=,pcpu=,pmem=,etime=,command=`.
        /// **Async** — live path uses `SubprocessRunner` which honors
        /// cooperative cancellation and avoids pipe-buffer deadlock.
        /// Tests pass a sync closure (`{ canned }`) and Swift adapts it
        /// to async automatically. (Phase 4E Slice 2a Gemini P0 fix.)
        public var psOutput: @Sendable () async -> String?

        /// `now()` for `started_at` / `last_active_at` derivation.
        /// Tests pin a fixed clock so timestamps are reproducible.
        public var now: @Sendable () -> Date

        /// File-existence check used by `guessProjectRoot`. Tests inject
        /// a closure that returns canned answers without touching disk.
        public var fileExists: @Sendable (String) -> Bool

        public init(
            psOutput: @escaping @Sendable () async -> String?,
            now: @escaping @Sendable () -> Date,
            fileExists: @escaping @Sendable (String) -> Bool
        ) {
            self.psOutput = psOutput
            self.now = now
            self.fileExists = fileExists
        }

        public static let live: TestHooks = TestHooks(
            psOutput: { await SessionDetector.livePsOutput() },
            now: { Date() },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    private let hooks: TestHooks
    private let userSecret: Data

    public init(userSecret: Data, hooks: TestHooks = .live) {
        self.userSecret = userSecret
        self.hooks = hooks
    }

    // MARK: - Public entry point

    /// Run the full session-detection pipeline. Always returns; an
    /// error reading `ps` degrades silently to `[]` (matches Python).
    public func collect() async -> [CollectedSession] {
        let rows = await parseProcessRows()
        var raw: [CollectedSession] = []
        let isoFormatter = SessionDetector.makeISOFormatter()
        let nowDate = hooks.now()
        let nowISO = isoFormatter.string(from: nowDate)

        for row in rows {
            if Self.shouldIgnoreCommand(row.command) { continue }
            guard let match = Self.detectProvider(row.command) else { continue }

            let elapsedSeconds = max(1, Self.elapsedToSeconds(row.etime))
            let startedAt = nowDate.addingTimeInterval(-Double(elapsedSeconds))
            let project = guessProject(row.command)
            let projectRoot = guessProjectRoot(row.command)
            let projectHash = projectRoot.map {
                GitCollector.computeProjectHashHex(secret: userSecret, absolutePath: $0.path)
            }
            let cpu = row.pcpu

            raw.append(CollectedSession(
                sessionId: "proc-\(row.pid)",
                name: Self.prettyName(row.command),
                provider: match.provider,
                project: project,
                status: "Running",
                totalUsage: max(500, Int(Double(elapsedSeconds) * max(1.5, cpu + 1.0))),
                requests: max(1, elapsedSeconds / 45),
                errorCount: 0,
                startedAt: isoFormatter.string(from: startedAt),
                lastActiveAt: nowISO,
                exactCost: nil,
                cpuUsage: cpu,
                command: row.command,
                collectionConfidence: match.confidence,
                projectHash: projectHash,
                projectRoot: projectRoot
            ))
        }

        // Dedup by (provider, project), then sort by (cpu, lastActive) desc, take top 12.
        let merged = Self.deduplicateSessions(raw)
        let sorted = merged.sorted { lhs, rhs in
            let lcpu = lhs.cpuUsage ?? 0
            let rcpu = rhs.cpuUsage ?? 0
            if lcpu != rcpu { return lcpu > rcpu }
            let lActive = lhs.lastActiveAt ?? ""
            let rActive = rhs.lastActiveAt ?? ""
            return lActive > rActive
        }
        return Array(sorted.prefix(12))
    }

    // MARK: - Process row parsing

    /// One row out of `ps -axo pid=,pcpu=,pmem=,etime=,command=`. Empty
    /// header (the trailing `=` on each column suppresses it), so every
    /// stdout line is one process.
    public struct ProcessRow: Sendable, Equatable {
        public let pid: String
        public let pcpu: Double
        public let pmem: Double
        public let etime: String
        public let command: String
    }

    /// Fetch ps output (live or test-injected) and parse into rows.
    /// Splits on whitespace WITH a 5-field maxsplit so the command
    /// column keeps its embedded spaces.
    func parseProcessRows() async -> [ProcessRow] {
        guard let output = await hooks.psOutput(), !output.isEmpty else { return [] }
        var rows: [ProcessRow] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let stripped = String(line).trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { continue }
            // Match Python `stripped.split(None, 4)` — 5 fields, the
            // 5th absorbs the rest including embedded whitespace.
            let parts = Self.splitFirstFour(stripped)
            guard parts.count == 5 else { continue }
            let pcpu = Double(parts[1]) ?? 0
            let pmem = Double(parts[2]) ?? 0
            rows.append(ProcessRow(
                pid: parts[0],
                pcpu: pcpu,
                pmem: pmem,
                etime: parts[3],
                command: parts[4]
            ))
        }
        return rows
    }

    /// Split on whitespace, but only the first 4 splits — any whitespace
    /// in the 5th field is preserved verbatim. Python's
    /// `str.split(None, 4)` semantics. (Swift's `split(maxSplits:)`
    /// requires a `Character`; we want "any whitespace run", so we
    /// hand-roll it.)
    static func splitFirstFour(_ s: String) -> [String] {
        var parts: [String] = []
        var idx = s.startIndex
        let end = s.endIndex
        for _ in 0..<4 {
            // skip leading whitespace
            while idx < end && s[idx].isWhitespace { idx = s.index(after: idx) }
            if idx == end { break }
            let start = idx
            while idx < end && !s[idx].isWhitespace { idx = s.index(after: idx) }
            parts.append(String(s[start..<idx]))
        }
        // Remaining: skip leading whitespace, take rest verbatim.
        while idx < end && s[idx].isWhitespace { idx = s.index(after: idx) }
        if idx < end {
            parts.append(String(s[idx..<end]))
        }
        return parts
    }

    // MARK: - etime parsing

    /// Convert ps's `etime` format (`[D-]HH:MM:SS` or `MM:SS` or `SS`)
    /// to seconds. Mirrors Python `_elapsed_to_seconds`.
    static func elapsedToSeconds(_ raw: String) -> Int {
        let chunks = raw.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let timePart = String(chunks.last ?? "")
        let days = chunks.count == 2 ? (Int(chunks[0]) ?? 0) : 0
        let parts = timePart.split(separator: ":").compactMap { Int($0) }

        let hours: Int
        let minutes: Int
        let seconds: Int
        switch parts.count {
        case 3:
            hours = parts[0]; minutes = parts[1]; seconds = parts[2]
        case 2:
            hours = 0; minutes = parts[0]; seconds = parts[1]
        case 1:
            hours = 0; minutes = 0; seconds = parts[0]
        default:
            return 0
        }
        return days * 86_400 + hours * 3_600 + minutes * 60 + seconds
    }

    // MARK: - Provider detection

    /// Returns `(provider, confidence)` if the executable part matches
    /// any pattern, else `nil`. Mirrors Python `_detect_provider`
    /// including the "cut at first arg-flag" logic — see Python source
    /// for the rationale around macOS paths with embedded spaces.
    static func detectProvider(_ command: String) -> (provider: String, confidence: String)? {
        let lowered = command.lowercased().trimmingCharacters(in: .whitespaces)
        if lowered.isEmpty { return nil }
        // Cut at the first ` -X` or ` --X` arg flag. Matches the
        // Python regex `\s-(?=[\w-])`.
        let executablePart: String
        if let flagRange = lowered.range(of: #"\s-(?=[\w-])"#, options: .regularExpression) {
            executablePart = String(lowered[lowered.startIndex..<flagRange.lowerBound])
        } else {
            executablePart = lowered
        }

        for entry in providerPatterns {
            if executablePart.range(of: entry.pattern, options: .regularExpression) != nil {
                return (entry.provider, entry.confidence)
            }
        }
        return nil
    }

    static func shouldIgnoreCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        for pattern in ignoredCommandPatterns {
            if lowered.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Project inference

    /// Walk the command line for absolute paths, then walk each path's
    /// ancestors looking for a project-marker file (`.git`,
    /// `package.json`, …). Returns the deepest ancestor with a marker,
    /// or `nil`. Mirrors Python `_guess_project_root`.
    func guessProjectRoot(_ command: String) -> URL? {
        let pattern = #"(/(?:Users|home|opt|var|tmp|srv)[^\s\"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(command.startIndex..<command.endIndex, in: command)
        let matches = regex.matches(in: command, range: nsRange)
        for match in matches {
            guard let r = Range(match.range, in: command) else { continue }
            let candidate = String(command[r])
            // Walk candidate + all ancestors.
            var cur = URL(fileURLWithPath: candidate)
            while true {
                let curPath = cur.path
                if curPath == "/" || curPath == "/Users" || curPath == "/home"
                    || curPath == "/opt" || curPath == "/var" || curPath == "/tmp" || curPath == "/srv" {
                    break
                }
                for marker in Self.projectMarkers {
                    if hooks.fileExists(cur.appendingPathComponent(marker).path) {
                        return cur
                    }
                }
                let parent = cur.deletingLastPathComponent()
                if parent == cur { break }
                cur = parent
            }
        }
        return nil
    }

    /// Display project name. Tries `guessProjectRoot` first; falls
    /// back to walking the path components for the deepest non-system
    /// directory; final fallback is the host's CWD basename.
    func guessProject(_ command: String) -> String {
        if let root = guessProjectRoot(command) {
            return root.lastPathComponent
        }
        // Path scan fallback.
        let pattern = #"(/(?:Users|home|opt|var|tmp|srv)[^\s\"']+)"#
        if let regex = try? NSRegularExpression(pattern: pattern) {
            let nsRange = NSRange(command.startIndex..<command.endIndex, in: command)
            for match in regex.matches(in: command, range: nsRange) {
                guard let r = Range(match.range, in: command) else { continue }
                let candidate = String(command[r])
                let parts = candidate.split(separator: "/", omittingEmptySubsequences: true)
                    .map { String($0) }
                    .filter { !["Users", "home", "opt", "var", "tmp", "srv"].contains($0) }
                if parts.count >= 2 { return parts[1] }
                if let only = parts.first { return only }
            }
        }
        let cwd = FileManager.default.currentDirectoryPath
        let cwdName = (cwd as NSString).lastPathComponent
        return cwdName.isEmpty ? "local-workspace" : cwdName
    }

    /// Compact whitespace + truncate to 48 chars (with ellipsis at 45).
    /// Mirrors Python `_pretty_name`.
    static func prettyName(_ command: String) -> String {
        let compact = command.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)
        if compact.count <= 48 { return compact }
        let prefix = String(compact.prefix(45))
        return prefix + "..."
    }

    // MARK: - Dedup

    /// Group sessions by (provider, project) and merge multi-process
    /// groups into a single representative. Highest-confidence row
    /// becomes primary; metrics aggregate; earliest start, latest
    /// active. Mirrors Python `_deduplicate_sessions`.
    static func deduplicateSessions(_ sessions: [CollectedSession]) -> [CollectedSession] {
        // Group, preserving first-seen order so the output is stable.
        var keyOrder: [String] = []
        var groups: [String: [CollectedSession]] = [:]
        for session in sessions {
            let key = (session.provider) + "\u{1F}" + (session.project ?? "")
            if groups[key] == nil { keyOrder.append(key) }
            groups[key, default: []].append(session)
        }

        var merged: [CollectedSession] = []
        for key in keyOrder {
            let group = groups[key] ?? []
            if group.count == 1 {
                merged.append(group[0])
                continue
            }
            // Sort by confidence rank desc, take primary.
            let sortedGroup = group.sorted { lhs, rhs in
                let l = confidenceRank[lhs.collectionConfidence ?? "low"] ?? 0
                let r = confidenceRank[rhs.collectionConfidence ?? "low"] ?? 0
                return l > r
            }
            let primary = sortedGroup[0]
            let totalUsage = group.compactMap { $0.totalUsage }.reduce(0, +)
            let totalRequests = group.compactMap { $0.requests }.reduce(0, +)
            let totalErrors = group.compactMap { $0.errorCount }.reduce(0, +)
            let totalCpu = group.compactMap { $0.cpuUsage }.reduce(0, +)
            let earliestStart = group.compactMap { $0.startedAt }.min() ?? primary.startedAt
            let latestActive = group.compactMap { $0.lastActiveAt }.max() ?? primary.lastActiveAt

            merged.append(CollectedSession(
                sessionId: primary.sessionId,
                name: group.count > 1
                    ? "\(primary.name ?? "") (+\(group.count - 1) workers)"
                    : primary.name,
                provider: primary.provider,
                project: primary.project,
                status: primary.status,
                totalUsage: totalUsage,
                requests: totalRequests,
                errorCount: totalErrors,
                startedAt: earliestStart,
                lastActiveAt: latestActive,
                exactCost: primary.exactCost,
                cpuUsage: totalCpu,
                command: primary.command,
                collectionConfidence: primary.collectionConfidence,
                projectHash: primary.projectHash,
                projectRoot: primary.projectRoot
            ))
        }
        return merged
    }

    // MARK: - Helpers

    static func makeISOFormatter() -> ISO8601DateFormatter {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }

    /// Run `/bin/ps -axo pid=,pcpu=,pmem=,etime=,command=` with bounded
    /// execution + concurrent drain + cancellation honoring. See
    /// `SubprocessRunner` for hygiene details.
    static func livePsOutput() async -> String? {
        return await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axo", "pid=,pcpu=,pmem=,etime=,command="],
            timeoutSeconds: 10.0
        )
    }
}
