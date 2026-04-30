import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Phase 1 (App Store sandbox session fallback) tests for
/// `CostUsageScanner.activeSessionCandidates` + `synthesizeSessions`,
/// plus the boundary helper on `DataRefreshManager`.
final class CostUsageScannerSessionSynthTests: XCTestCase {

    private var tmpRoot: URL!
    private var codexSessionsRoot: URL!
    private var claudeProjectsRoot: URL!
    private var cacheRoot: URL!

    override func setUpWithError() throws {
        tmpRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipulse-synth-\(UUID().uuidString)", isDirectory: true)
        codexSessionsRoot = tmpRoot.appendingPathComponent("codex-sessions", isDirectory: true)
        claudeProjectsRoot = tmpRoot.appendingPathComponent("claude-projects", isDirectory: true)
        cacheRoot = tmpRoot.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessionsRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: claudeProjectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpRoot)
        tmpRoot = nil
    }

    // MARK: - Helpers

    /// Write a Codex JSONL fixture into a date-partitioned directory and
    /// stamp its mtime so freshness can be controlled.
    @discardableResult
    private func writeCodexFixture(
        sessionId: String,
        date: Date,
        mtime: Date,
        tokens: (input: Int, cached: Int, output: Int) = (1000, 0, 500)
    ) throws -> URL {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let dir = codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", comps.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", comps.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(sessionId).jsonl")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let ts = iso.string(from: date)
        let meta = #"{"type":"session_meta","timestamp":"\#(ts)","payload":{"session_id":"\#(sessionId)"}}"#
        let turn = #"{"type":"turn_context","timestamp":"\#(ts)","payload":{"model":"gpt-5"}}"#
        let event = #"""
        {"type":"event_msg","timestamp":"\#(ts)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(tokens.input),"cached_input_tokens":\#(tokens.cached),"output_tokens":\#(tokens.output)}}}}
        """#
        let body = ([meta, turn, event].joined(separator: "\n") + "\n")
        try body.write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
        return fileURL
    }

    /// Write a Claude JSONL fixture under an encoded project dir and stamp
    /// its mtime.
    @discardableResult
    private func writeClaudeFixture(
        encodedProject: String,
        sessionId: String,
        date: Date,
        mtime: Date,
        inputTokens: Int = 200,
        outputTokens: Int = 100
    ) throws -> URL {
        let projectDir = claudeProjectsRoot.appendingPathComponent(encodedProject, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let fileURL = projectDir.appendingPathComponent("\(sessionId).jsonl")

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let ts = iso.string(from: date)
        // One assistant event with usage so token totals + message count both
        // populate. JSON formatted on a single line because the parser is
        // line-oriented.
        let line = """
        {"type":"assistant","timestamp":"\(ts)","requestId":"req-1","message":{"id":"msg-1","model":"claude-sonnet-4-5","usage":{"input_tokens":\(inputTokens),"output_tokens":\(outputTokens)}}}
        """
        try (line + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: fileURL.path)
        return fileURL
    }

    private func makeScanOptions() -> CostUsageScanner.Options {
        CostUsageScanner.Options(
            codexSessionsRoot: codexSessionsRoot,
            claudeProjectsRoots: [claudeProjectsRoot],
            cacheRoot: cacheRoot,
            daysToScan: 7
        )
    }

    // MARK: - Codex candidate

    func testFreshCodexJsonlYieldsCandidate() throws {
        let now = Date()
        try writeCodexFixture(sessionId: "c-fresh", date: now, mtime: now)
        let result = CostUsageScanner.scan(options: makeScanOptions())
        let codexCandidates = result.activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertEqual(codexCandidates.count, 1, "fresh Codex JSONL must yield exactly one candidate")
        let c = try XCTUnwrap(codexCandidates.first)
        XCTAssertEqual(c.sessionId, "c-fresh")
        XCTAssertEqual(c.projectName, "Codex")
        XCTAssertNil(c.projectRoot)
        XCTAssertGreaterThan(c.totalTokens, 0)
        XCTAssertEqual(c.messageCount, 0, "Codex doesn't track per-event message count")
    }

    // MARK: - Claude candidate

    func testFreshClaudeJsonlYieldsCandidate() throws {
        let now = Date()
        try writeClaudeFixture(
            encodedProject: "-Users-jason-cli-pulse",
            sessionId: "claude-session-uuid",
            date: now,
            mtime: now
        )
        let result = CostUsageScanner.scan(options: makeScanOptions())
        let claudeCandidates = result.activeSessionCandidates.filter { $0.provider == "Claude" }
        XCTAssertEqual(claudeCandidates.count, 1, "fresh Claude JSONL must yield exactly one candidate")
        let c = try XCTUnwrap(claudeCandidates.first)
        XCTAssertEqual(c.sessionId, "claude-session-uuid")
        XCTAssertEqual(c.projectName, "cli-pulse",
                       "hyphenated repo name `cli-pulse` must survive the Claude encoded-dir decoder")
        XCTAssertGreaterThan(c.totalTokens, 0)
        XCTAssertGreaterThan(c.messageCount, 0, "Claude assistant event contributes a message count")
    }

    // MARK: - humanReadableClaudeProject heuristic

    func testHumanReadableClaudeProjectKeepsHyphenatedRepoName() {
        XCTAssertEqual(
            CostUsageScanner.humanReadableClaudeProject(encodedDir: "-Users-jason-cli-pulse"),
            "cli-pulse"
        )
    }

    func testHumanReadableClaudeProjectHandlesLinuxRoot() {
        XCTAssertEqual(
            CostUsageScanner.humanReadableClaudeProject(encodedDir: "-home-alice-myrepo"),
            "myrepo"
        )
    }

    func testHumanReadableClaudeProjectKeepsDeeperPathReadable() {
        // Project sitting at /Users/jason/Documents/cli-pulse — the function
        // can't safely reconstruct the slash, but it must NOT lose the
        // hyphenated tail. Returning the user-relative remainder verbatim
        // keeps the repo name intact in the label.
        XCTAssertEqual(
            CostUsageScanner.humanReadableClaudeProject(encodedDir: "-Users-jason-Documents-cli-pulse"),
            "Documents-cli-pulse"
        )
    }

    func testHumanReadableClaudeProjectPassesThroughSimpleNames() {
        XCTAssertEqual(
            CostUsageScanner.humanReadableClaudeProject(encodedDir: "myrepo"),
            "myrepo"
        )
        XCTAssertEqual(
            CostUsageScanner.humanReadableClaudeProject(encodedDir: "some-project"),
            "some-project",
            "non-encoded labels must NOT be split — `some-project` stays whole"
        )
    }

    // MARK: - Stale ignored

    func testStaleCodexJsonlIsIgnored() throws {
        let now = Date()
        let stale = now.addingTimeInterval(-(CostUsageScanner.activeSessionFreshnessWindow + 60))
        try writeCodexFixture(sessionId: "c-stale", date: now, mtime: stale)
        let result = CostUsageScanner.scan(options: makeScanOptions())
        let codexCandidates = result.activeSessionCandidates.filter { $0.provider == "Codex" }
        XCTAssertTrue(codexCandidates.isEmpty,
                      "JSONL older than activeSessionFreshnessWindow must NOT produce a candidate")
    }

    func testStaleClaudeJsonlIsIgnored() throws {
        let now = Date()
        let stale = now.addingTimeInterval(-(CostUsageScanner.activeSessionFreshnessWindow + 60))
        try writeClaudeFixture(
            encodedProject: "-Users-jason-old-project",
            sessionId: "claude-old",
            date: now,
            mtime: stale
        )
        let result = CostUsageScanner.scan(options: makeScanOptions())
        let claudeCandidates = result.activeSessionCandidates.filter { $0.provider == "Claude" }
        XCTAssertTrue(claudeCandidates.isEmpty)
    }

    // MARK: - synthesizeSessions

    func testSynthesizeSessionsProducesValidSessionRecord() {
        let now = Date()
        let candidate = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex",
            filePath: "/tmp/foo.jsonl",
            projectName: "Codex",
            projectRoot: nil,
            sessionId: "abc-123",
            lastModified: now,
            totalTokens: 1500,
            totalCost: 0.42,
            messageCount: 0
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [candidate], now: now, deviceName: "TestMac"
        )
        XCTAssertEqual(sessions.count, 1)
        let s = sessions[0]
        XCTAssertEqual(s.id, "jsonl-codex-abc-123")
        XCTAssertEqual(s.provider, "Codex")
        XCTAssertEqual(s.project, "Codex")
        XCTAssertEqual(s.status, "Running")
        XCTAssertEqual(s.device_name, "TestMac")
        XCTAssertEqual(s.total_usage, 1500)
        XCTAssertEqual(s.estimated_cost, 0.42, accuracy: 1e-9)
        XCTAssertEqual(s.cost_status, "normal")
        XCTAssertGreaterThanOrEqual(s.requests, 1)
        XCTAssertEqual(s.error_count, 0)
        XCTAssertEqual(s.collection_confidence, "medium")
    }

    func testSynthesizeSessionsWarnsWhenCostExceedsOneDollar() {
        let now = Date()
        let candidate = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Claude",
            filePath: "/tmp/foo.jsonl",
            projectName: "myproj",
            projectRoot: nil,
            sessionId: "x-1",
            lastModified: now,
            totalTokens: 999_000,
            totalCost: 4.20,
            messageCount: 12
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [candidate], now: now, deviceName: "TestMac"
        )
        XCTAssertEqual(sessions.first?.cost_status, "warning")
        XCTAssertEqual(sessions.first?.requests, 12, "messageCount drives requests for Claude")
    }

    func testSynthesizeSessionsDeduplicatesSameProviderAndSessionId() {
        let now = Date()
        let earlier = now.addingTimeInterval(-30)
        let later = now
        let dupA = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex", filePath: "/tmp/a.jsonl",
            projectName: "Codex", projectRoot: nil, sessionId: "same-id",
            lastModified: earlier, totalTokens: 100, totalCost: 0, messageCount: 0
        )
        let dupB = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex", filePath: "/tmp/b.jsonl",
            projectName: "Codex", projectRoot: nil, sessionId: "same-id",
            lastModified: later, totalTokens: 200, totalCost: 0, messageCount: 0
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [dupA, dupB], now: now, deviceName: "TestMac"
        )
        XCTAssertEqual(sessions.count, 1, "(provider, sessionId) collisions must dedupe")
        XCTAssertEqual(sessions.first?.total_usage, 200,
                       "later mtime wins on dedup so we don't show stale totals")
    }

    /// Defensive freshness filter inside `synthesizeSessions` — even when
    /// a stale candidate slips into the input list (e.g. a caller built
    /// candidates from cached state and forgot to re-stat the JSONL),
    /// the synthesizer must drop it rather than produce a "Running"
    /// session for a dead tool.
    func testSynthesizeSessionsDropsStaleCandidate() {
        let now = Date()
        let stale = now.addingTimeInterval(-(CostUsageScanner.activeSessionFreshnessWindow + 60))
        let candidate = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex",
            filePath: "/tmp/stale.jsonl",
            projectName: "Codex",
            projectRoot: nil,
            sessionId: "old-session",
            lastModified: stale,
            totalTokens: 999,
            totalCost: 0,
            messageCount: 0
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [candidate], now: now, deviceName: "TestMac"
        )
        XCTAssertTrue(sessions.isEmpty,
                      "candidates older than activeSessionFreshnessWindow must be filtered out")
    }

    /// Mixed fresh + stale input: only the fresh one synthesizes.
    func testSynthesizeSessionsKeepsFreshDropsStaleInSameCall() {
        let now = Date()
        let stale = now.addingTimeInterval(-(CostUsageScanner.activeSessionFreshnessWindow + 60))
        let staleC = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex", filePath: "/tmp/old.jsonl", projectName: "Codex",
            projectRoot: nil, sessionId: "old", lastModified: stale,
            totalTokens: 1, totalCost: 0, messageCount: 0
        )
        let freshC = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Claude", filePath: "/tmp/now.jsonl", projectName: "myproj",
            projectRoot: nil, sessionId: "new", lastModified: now,
            totalTokens: 10, totalCost: 0, messageCount: 1
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [staleC, freshC], now: now, deviceName: "TestMac"
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "jsonl-claude-new")
    }

    /// Boundary case — exactly at the freshness window edge is still kept.
    func testSynthesizeSessionsKeepsBoundaryFreshness() {
        let now = Date()
        let edge = now.addingTimeInterval(-CostUsageScanner.activeSessionFreshnessWindow)
        let candidate = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex", filePath: "/tmp/edge.jsonl", projectName: "Codex",
            projectRoot: nil, sessionId: "edge", lastModified: edge,
            totalTokens: 1, totalCost: 0, messageCount: 0
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [candidate], now: now, deviceName: "TestMac"
        )
        XCTAssertEqual(sessions.count, 1, "candidate AT the window edge is fresh enough")
    }

    /// `DataRefreshManager.resolveLocalSessions(...)` must propagate the
    /// staleness filter — when the live scanner is empty AND the only
    /// candidate is stale, the resolved list is empty.
    func testResolveLocalSessionsFiltersStaleCandidatesWhenScannerEmpty() {
        let now = Date()
        let stale = now.addingTimeInterval(-(CostUsageScanner.activeSessionFreshnessWindow + 60))
        let costScan = CostUsageScanResult(
            entries: [],
            activeSessionCandidates: [
                .init(provider: "Codex", filePath: "/tmp/stale.jsonl", projectName: "Codex",
                      projectRoot: nil, sessionId: "stale-id", lastModified: stale,
                      totalTokens: 1, totalCost: 0, messageCount: 0)
            ]
        )
        let resolved = DataRefreshManager.resolveLocalSessions(
            scannerSessions: [],
            scanResult: costScan,
            deviceName: "TestMac",
            now: now
        )
        XCTAssertTrue(resolved.isEmpty,
                      "stale-only candidate must NOT surface as a synthesized session")
    }

    func testSynthesizeSessionsDedupesByFilePathWhenSessionIdMissing() {
        let now = Date()
        let a = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex", filePath: "/tmp/same.jsonl",
            projectName: "Codex", projectRoot: nil, sessionId: nil,
            lastModified: now.addingTimeInterval(-5),
            totalTokens: 10, totalCost: 0, messageCount: 0
        )
        let b = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex", filePath: "/tmp/same.jsonl",
            projectName: "Codex", projectRoot: nil, sessionId: nil,
            lastModified: now,
            totalTokens: 99, totalCost: 0, messageCount: 0
        )
        let sessions = CostUsageScanner.synthesizeSessions(
            candidates: [a, b], now: now, deviceName: "TestMac"
        )
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.total_usage, 99)
    }

    // MARK: - DataRefreshManager.resolveLocalSessions boundary

    /// Pure-function test of the boundary helper: when the live process scan
    /// is non-empty it wins; when it's empty and JSONL candidates exist, the
    /// candidates are synthesized.
    func testResolveLocalSessionsKeepsScannerSessionsWhenNonEmpty() {
        let now = Date()
        let scannerSession = SessionRecord(
            id: "real-1", name: "claude", provider: "Claude", project: "demo",
            device_name: "TestMac", started_at: "2026-04-30T12:00:00Z",
            last_active_at: "2026-04-30T12:05:00Z", status: "Running",
            total_usage: 100, estimated_cost: 0, cost_status: "normal",
            requests: 1, error_count: 0
        )
        let costScan = CostUsageScanResult(
            entries: [],
            activeSessionCandidates: [
                .init(provider: "Codex", filePath: "/tmp/x.jsonl", projectName: "Codex",
                      projectRoot: nil, sessionId: "y", lastModified: now,
                      totalTokens: 1, totalCost: 0, messageCount: 0)
            ]
        )
        let resolved = DataRefreshManager.resolveLocalSessions(
            scannerSessions: [scannerSession],
            scanResult: costScan,
            deviceName: "TestMac",
            now: now
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.id, "real-1",
                       "live process scan must win over JSONL synthesis when non-empty")
    }

    func testResolveLocalSessionsFallsBackToCandidatesWhenScannerEmpty() {
        let now = Date()
        let costScan = CostUsageScanResult(
            entries: [],
            activeSessionCandidates: [
                .init(provider: "Codex", filePath: "/tmp/x.jsonl", projectName: "Codex",
                      projectRoot: nil, sessionId: "y", lastModified: now,
                      totalTokens: 1, totalCost: 0, messageCount: 0)
            ]
        )
        let resolved = DataRefreshManager.resolveLocalSessions(
            scannerSessions: [],
            scanResult: costScan,
            deviceName: "TestMac",
            now: now
        )
        XCTAssertEqual(resolved.count, 1)
        XCTAssertEqual(resolved.first?.id, "jsonl-codex-y")
        XCTAssertEqual(resolved.first?.status, "Running")
    }

    /// "No AI tools detected" risk-signal path: when both the scanner and
    /// JSONL synthesis are empty, the helper returns an empty list so the
    /// caller can surface the empty-state hint. When EITHER source has
    /// data, the empty-state hint must be suppressed.
    func testResolveLocalSessionsEmptyWhenBothEmpty() {
        let now = Date()
        let costScan = CostUsageScanResult(entries: [], activeSessionCandidates: [])
        let resolved = DataRefreshManager.resolveLocalSessions(
            scannerSessions: [],
            scanResult: costScan,
            deviceName: "TestMac",
            now: now
        )
        XCTAssertTrue(resolved.isEmpty, "empty scanner + empty JSONL ⇒ suppress nothing; risk hint legitimate")
    }
}

#endif
