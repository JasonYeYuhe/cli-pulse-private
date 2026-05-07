import XCTest
@testable import HelperKit
import Foundation

/// Tests for `SessionDetector` (Phase 4E Slice 2a). Pin the parsing
/// + classification + dedup + sort invariants against canned `ps`
/// output so wire-shape and behaviour match `helper/system_collector.py`'s
/// `collect_sessions` semantics 1:1.
final class SessionDetectorTests: XCTestCase {

    // MARK: - Fixtures

    /// Canned `ps -axo pid=,pcpu=,pmem=,etime=,command=` output exercising:
    ///   - A real Codex CLI (high confidence)
    ///   - A real Claude Code 2.x path with embedded spaces
    ///   - A Gemini CLI
    ///   - An ignored row (codex helper)
    ///   - An ignored row (vscode-server)
    ///   - A non-AI process that should drop out of provider detection
    private let psFixture: String = """
    12345  3.5  1.2 00:42 /usr/local/bin/codex --model gpt-5
    12346  0.5  0.8 01:23 /Users/dev/.npm/codex helper --type=worker
    23456 12.0  4.5 1-02:00:00 /Users/dev/Library/Application Support/Claude/claude-code/2.1.0/claude.app/Contents/MacOS/claude --plugin-dir /Users/dev/.openai-codex/plugins
    23457  2.1  0.9 00:05:12 /opt/homebrew/bin/gemini --interactive
    99999  0.0  0.1 00:00:01 /Applications/iTerm.app/Contents/MacOS/iTerm2
    77777  0.5  0.5 00:00:30 node /Users/dev/projects/myapp/node_modules/.bin/something --provider claude
    """

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDetector(
        psOutput: String? = nil,
        fileExists: @escaping @Sendable (String) -> Bool = { _ in false }
    ) -> SessionDetector {
        let captured = psOutput ?? psFixture
        let nowDate = fixedNow
        return SessionDetector(
            userSecret: Data("k".utf8),
            hooks: SessionDetector.TestHooks(
                psOutput: { captured },
                now: { nowDate },
                fileExists: fileExists
            )
        )
    }

    // MARK: - elapsedToSeconds

    func testElapsedToSeconds_secondsOnly() {
        XCTAssertEqual(SessionDetector.elapsedToSeconds("30"), 30)
        XCTAssertEqual(SessionDetector.elapsedToSeconds("0"), 0)
    }

    func testElapsedToSeconds_minutesSeconds() {
        XCTAssertEqual(SessionDetector.elapsedToSeconds("12:34"), 12 * 60 + 34)
        XCTAssertEqual(SessionDetector.elapsedToSeconds("00:01"), 1)
    }

    func testElapsedToSeconds_hoursMinutesSeconds() {
        XCTAssertEqual(
            SessionDetector.elapsedToSeconds("01:23:45"),
            1 * 3600 + 23 * 60 + 45
        )
    }

    func testElapsedToSeconds_daysHHMMSS() {
        // 1-02:30:00 = 1 day + 2h 30m = 86400 + 9000 = 95400.
        XCTAssertEqual(SessionDetector.elapsedToSeconds("1-02:30:00"), 95_400)
    }

    // MARK: - detectProvider

    func testDetectProvider_codexBareBinary() {
        let result = SessionDetector.detectProvider("/usr/local/bin/codex --model gpt-5")
        XCTAssertEqual(result?.provider, "Codex")
        XCTAssertEqual(result?.confidence, "high")
    }

    func testDetectProvider_claudeCode2xPathWithSpaces() {
        // The macOS path has TWO embedded spaces ("Application Support"
        // and "claude-code"). Splitting on first whitespace would cut
        // mid-path; the implementation cuts at first ` -X` arg flag.
        let cmd = "/Users/dev/Library/Application Support/Claude/claude-code/2.1.0/claude.app/Contents/MacOS/claude --plugin-dir /tmp"
        let result = SessionDetector.detectProvider(cmd)
        XCTAssertEqual(result?.provider, "Claude")
        XCTAssertEqual(result?.confidence, "high")
    }

    func testDetectProvider_dontMisclassifyClaudeViaCodexInArgv() {
        // Real Claude Code 2.x with `--plugin-dir openai-codex/...` —
        // `codex` appears in argv but NOT in the executable part.
        // Should classify as Claude (high), not Codex.
        let cmd = "/usr/local/bin/claude --plugin-dir /Users/dev/.openai-codex/plugins"
        let result = SessionDetector.detectProvider(cmd)
        XCTAssertEqual(result?.provider, "Claude",
                       "claude binary with `--plugin-dir openai-codex` argv must classify as Claude, not Codex")
    }

    func testDetectProvider_returnsNilForNonAIProcess() {
        XCTAssertNil(SessionDetector.detectProvider("/Applications/iTerm.app/Contents/MacOS/iTerm2"))
        XCTAssertNil(SessionDetector.detectProvider(""))
    }

    func testDetectProvider_geminiAndCursor() {
        XCTAssertEqual(SessionDetector.detectProvider("/opt/homebrew/bin/gemini --interactive")?.provider, "Gemini")
        XCTAssertEqual(SessionDetector.detectProvider("/Applications/Cursor.app/Contents/MacOS/Cursor")?.provider, "Cursor")
    }

    // MARK: - shouldIgnoreCommand

    func testShouldIgnoreCommand_codexHelper() {
        XCTAssertTrue(SessionDetector.shouldIgnoreCommand(
            "/Users/dev/.npm/codex helper --type=worker"
        ))
    }

    func testShouldIgnoreCommand_chromiumRenderer() {
        XCTAssertTrue(SessionDetector.shouldIgnoreCommand(
            "/Applications/Some.app/Contents/Frameworks/Helper --type=renderer --enable-features=foo"
        ))
    }

    func testShouldIgnoreCommand_nodeModulesBin() {
        XCTAssertTrue(SessionDetector.shouldIgnoreCommand(
            "node /Users/dev/projects/myapp/node_modules/.bin/something --provider claude"
        ))
    }

    func testShouldIgnoreCommand_passesNormalCommand() {
        XCTAssertFalse(SessionDetector.shouldIgnoreCommand("/usr/local/bin/codex"))
        XCTAssertFalse(SessionDetector.shouldIgnoreCommand("/usr/local/bin/claude"))
    }

    // MARK: - prettyName

    func testPrettyName_compactsWhitespace() {
        let name = SessionDetector.prettyName("a   b\t\tc\nd")
        XCTAssertEqual(name, "a b c d")
    }

    func testPrettyName_truncatesAt45WithEllipsis() {
        let long = String(repeating: "x", count: 60)
        let name = SessionDetector.prettyName(long)
        XCTAssertTrue(name.hasSuffix("..."))
        XCTAssertEqual(name.count, 48,
                       "prefix(45) + 3-char ellipsis = 48 chars total")
    }

    func testPrettyName_passesShortCommandUnchanged() {
        XCTAssertEqual(SessionDetector.prettyName("codex --help"), "codex --help")
    }

    // MARK: - splitFirstFour parser

    func testSplitFirstFour_preservesEmbeddedWhitespaceInLastField() {
        let parts = SessionDetector.splitFirstFour(
            "12345 3.5 1.2 00:42 /Users/dev/Library/Application Support/Claude/claude --flag"
        )
        XCTAssertEqual(parts.count, 5)
        XCTAssertEqual(parts[0], "12345")
        XCTAssertEqual(parts[3], "00:42")
        XCTAssertEqual(parts[4], "/Users/dev/Library/Application Support/Claude/claude --flag")
    }

    // MARK: - End-to-end collect()

    func testCollect_filtersIgnoredAndUnclassified() async {
        let detector = makeDetector()
        let sessions = await detector.collect()

        // From the 6 ps lines, 3 should classify (codex, claude, gemini),
        // 3 should drop (codex helper, iTerm not-AI, node_modules/.bin
        // ignored).
        let providers = sessions.map { $0.provider }
        XCTAssertEqual(Set(providers), Set(["Codex", "Claude", "Gemini"]))
        XCTAssertEqual(sessions.count, 3)
    }

    func testCollect_dedupsSameProviderProject() async {
        // Two Codex CLI processes under the same project root — should
        // merge into one session with aggregated metrics.
        let canned = """
        100  5.0 1.0 00:30 /usr/local/bin/codex --model gpt-5
        101  3.0 0.8 00:25 /usr/local/bin/codex --workers 2
        """
        let detector = makeDetector(psOutput: canned)
        let sessions = await detector.collect()

        XCTAssertEqual(sessions.count, 1)
        // CPU aggregates: 5.0 + 3.0 = 8.0
        XCTAssertEqual(sessions[0].cpuUsage, 8.0)
        // Name gains "(+1 workers)" suffix.
        XCTAssertTrue(sessions[0].name?.contains("workers") ?? false,
                      "merged name must indicate worker count: \(sessions[0].name ?? "nil")")
    }

    func testCollect_sortsByCpuDescending() async {
        let canned = """
        100  1.0 1.0 00:30 /usr/local/bin/codex --workers 1
        101  9.0 1.0 00:30 /usr/local/bin/claude
        102  5.0 1.0 00:30 /opt/homebrew/bin/gemini
        """
        let detector = makeDetector(psOutput: canned)
        let sessions = await detector.collect()

        XCTAssertEqual(sessions.map { $0.provider }, ["Claude", "Gemini", "Codex"])
    }

    func testCollect_capsAtTop12() async {
        // 15 distinct provider+project combos — collect() must cap to 12.
        // Project distinctness comes from `--cwd /Users/dev/projN`, which
        // `guessProject`'s path-scan fallback resolves to the second
        // non-system component (`projN`) — ensures each row is its own
        // dedup group.
        let lines = (0..<15).map { i in
            "\(100 + i)  \(Double(15 - i)).0 1.0 00:30 /usr/local/bin/claude --cwd /Users/dev/proj\(i)"
        }
        let canned = lines.joined(separator: "\n")
        let detector = makeDetector(psOutput: canned)
        let sessions = await detector.collect()
        XCTAssertEqual(sessions.count, 12)
        // Top-12 should be the highest-CPU rows: i=0 (cpu=15) … i=11 (cpu=4).
        let projects = sessions.compactMap { $0.project }
        XCTAssertEqual(projects.first, "proj0",
                       "highest-CPU project should be first; got \(projects.first ?? "nil")")
        XCTAssertFalse(projects.contains("proj14"),
                       "lowest-CPU rows beyond top-12 must be dropped")
    }

    func testCollect_buildsExpectedFieldsForCodexCliRow() async {
        let canned = "12345  3.5  1.2 00:42 /usr/local/bin/codex --model gpt-5"
        let detector = makeDetector(psOutput: canned)
        let sessions = await detector.collect()

        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.sessionId, "proc-12345")
        XCTAssertEqual(s.provider, "Codex")
        XCTAssertEqual(s.collectionConfidence, "high")
        XCTAssertEqual(s.cpuUsage, 3.5)
        XCTAssertEqual(s.status, "Running")
        XCTAssertEqual(s.errorCount, 0)
        XCTAssertNil(s.exactCost,
                     "Slice 2a never sets exactCost — that's a Slice 2c quota-fetcher concern")
        // started_at = now - 42s; lastActiveAt = now.
        XCTAssertNotNil(s.startedAt)
        XCTAssertNotNil(s.lastActiveAt)
    }

    func testCollect_returnsEmptyWhenPsOutputIsNil() async {
        let detector = SessionDetector(
            userSecret: Data("k".utf8),
            hooks: .init(
                psOutput: { nil },
                now: { Date() },
                fileExists: { _ in false }
            )
        )
        let result = await detector.collect()
        XCTAssertEqual(result, [])
    }

    // MARK: - Wire-shape parity

    func testCollectedSessionEncodesSnakeCase() throws {
        let session = CollectedSession(
            sessionId: "proc-123",
            name: "codex --help",
            provider: "Codex",
            project: "myapp",
            status: "Running",
            totalUsage: 500,
            requests: 1,
            errorCount: 0,
            startedAt: "2026-05-07T01:23:45Z",
            lastActiveAt: "2026-05-07T01:24:00Z",
            exactCost: nil,
            cpuUsage: 1.5,
            command: "codex --help",
            collectionConfidence: "high",
            projectHash: "deadbeef",
            projectRoot: URL(fileURLWithPath: "/Users/dev/myapp")
        )
        let data = try JSONEncoder().encode(session)
        let json = String(data: data, encoding: .utf8) ?? ""
        for needle in [
            "\"session_id\":\"proc-123\"",
            "\"total_usage\":500",
            "\"error_count\":0",
            "\"started_at\":",
            "\"last_active_at\":",
            "\"cpu_usage\":1.5",
            "\"collection_confidence\":\"high\"",
            "\"project_hash\":\"deadbeef\"",
            "\"project_root\":",
        ] {
            XCTAssertTrue(json.contains(needle),
                          "CollectedSession wire shape missing `\(needle)`; got \(json)")
        }
        // No camelCase leak.
        for camelKey in ["sessionId", "totalUsage", "errorCount", "startedAt"] {
            XCTAssertFalse(json.contains("\"\(camelKey)\":"),
                           "CollectedSession leaked camelCase key `\(camelKey)`")
        }
    }
}
