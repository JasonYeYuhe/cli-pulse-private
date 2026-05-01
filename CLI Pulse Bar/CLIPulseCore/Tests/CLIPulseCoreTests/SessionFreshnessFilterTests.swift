import XCTest
@testable import CLIPulseCore

/// iter22: pin the filter that strips stale + helper-process-artifact
/// rows out of the macOS Sessions tab. See `SessionFreshnessFilter`
/// for the rationale.
final class SessionFreshnessFilterTests: XCTestCase {
    // Use the same formatter shape as `SessionRecord.lastActiveDate`
    // (default ISO8601DateFormatter, no fractional seconds) so the
    // filter under test actually parses our test inputs.
    private let isoFormatter = ISO8601DateFormatter()

    private func makeSession(
        id: String = UUID().uuidString,
        name: String = "Claude · cli-pulse",
        provider: String = "Claude",
        device: String = "MacBook Pro",
        lastActive: Date,
        status: String = "running"
    ) -> SessionRecord {
        SessionRecord(
            id: id,
            name: name,
            provider: provider,
            project: "cli-pulse",
            device_name: device,
            started_at: isoFormatter.string(from: lastActive),
            last_active_at: isoFormatter.string(from: lastActive),
            status: status,
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 0,
            error_count: 0
        )
    }

    func test_filterCurrent_keepsFreshSessions() {
        let now = Date()
        let fresh = makeSession(lastActive: now.addingTimeInterval(-60))
        let result = SessionFreshnessFilter.filterCurrent([fresh], now: now)
        XCTAssertEqual(result.count, 1)
    }

    func test_filterCurrent_dropsSessionsOlderThan5Min() {
        let now = Date()
        let stale = makeSession(lastActive: now.addingTimeInterval(-301))
        let result = SessionFreshnessFilter.filterCurrent([stale], now: now)
        XCTAssertTrue(result.isEmpty, "Sessions older than 300s should be dropped")
    }

    func test_filterCurrent_dropsHelperUploadedHistoricalRows() {
        let now = Date()
        // Mirror the manual-test screenshot: 28 days old, helper device.
        let helperHistorical = makeSession(
            name: "Claude · my-project",
            device: "CLI Pulse Helper",
            lastActive: now.addingTimeInterval(-28 * 86_400),
            status: "ended"
        )
        let result = SessionFreshnessFilter.filterCurrent([helperHistorical], now: now)
        XCTAssertTrue(result.isEmpty, "28-day-old helper rows must not survive into the current Sessions tab")
    }

    func test_filterCurrent_dropsApplicationsPathArtifact() {
        let now = Date()
        let artifact = makeSession(
            name: "/Applications/Claude.app/Contents/MacOS/Claude",
            lastActive: now.addingTimeInterval(-60)
        )
        let result = SessionFreshnessFilter.filterCurrent([artifact], now: now)
        XCTAssertTrue(result.isEmpty, "Process-path artifact rows must not appear in Sessions")
    }

    func test_filterCurrent_dropsHelperBundleArtifact() {
        let now = Date()
        let artifact = makeSession(
            name: "/Applications/Codex.app/Contents/Helper",
            lastActive: now.addingTimeInterval(-30)
        )
        let result = SessionFreshnessFilter.filterCurrent([artifact], now: now)
        XCTAssertTrue(result.isEmpty)
    }

    func test_filterCurrent_dropsNodeFlagArtifact() {
        let now = Date()
        let artifact = makeSession(
            name: "node --no-warnings=DEP0040 /usr/local/bin/codex",
            lastActive: now.addingTimeInterval(-60)
        )
        let result = SessionFreshnessFilter.filterCurrent([artifact], now: now)
        XCTAssertTrue(result.isEmpty)
    }

    func test_filterCurrent_keepsSynthesizedJsonlSessionName() {
        let now = Date()
        // CostUsageScanner.synthesizeSessions emits "<provider> · <project>".
        let synthesized = makeSession(
            name: "Claude · cli-pulse",
            lastActive: now.addingTimeInterval(-60)
        )
        let result = SessionFreshnessFilter.filterCurrent([synthesized], now: now)
        XCTAssertEqual(result, [synthesized], "Synthesized JSONL sessions must survive the filter")
    }

    func test_filterCurrent_dropsSessionsWithUnparseableTimestamp() {
        let now = Date()
        let bad = SessionRecord(
            id: "x", name: "Claude · cli-pulse", provider: "Claude", project: "cli-pulse",
            device_name: "Mac", started_at: "not-a-date", last_active_at: "also-not-a-date",
            status: "running", total_usage: 0, estimated_cost: 0,
            cost_status: "Estimated", requests: 0, error_count: 0
        )
        XCTAssertTrue(SessionFreshnessFilter.filterCurrent([bad], now: now).isEmpty)
    }

    // MARK: - mergeCloudAndLocalSessions (iter23)

    private func makeLocalSynthSession(
        id: String,
        provider: String = "Codex",
        project: String,
        device: String = "MacBook Pro",
        lastActive: Date
    ) -> SessionRecord {
        SessionRecord(
            id: "jsonl-\(provider.lowercased())-\(id)",
            name: "\(provider) session",
            provider: provider,
            project: project,
            device_name: device,
            started_at: isoFormatter.string(from: lastActive.addingTimeInterval(-300)),
            last_active_at: isoFormatter.string(from: lastActive),
            status: "Running",
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "normal",
            requests: 1,
            error_count: 0,
            collection_confidence: "medium",
            project_hash: nil
        )
    }

    func test_merge_emptyCloud_oneLocalCandidate_yieldsOneCodexRow() {
        let now = Date()
        let local = makeLocalSynthSession(id: "abc", project: "cli-pulse", lastActive: now.addingTimeInterval(-30))
        let merged = SessionFreshnessFilter.mergeCloudAndLocalSessions(cloudFresh: [], localFresh: [local])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.provider, "Codex")
        XCTAssertEqual(merged.first?.project, "cli-pulse")
    }

    func test_merge_freshCloudFromOtherDevice_andLocal_keepsBoth() {
        let now = Date()
        let local = makeLocalSynthSession(id: "abc", project: "cli-pulse", device: "MacBookPro", lastActive: now.addingTimeInterval(-30))
        let cloudOther = makeSession(
            id: "cloud-xyz",
            name: "Claude · backend",
            provider: "Claude",
            device: "OtherMac",
            lastActive: now.addingTimeInterval(-60)
        )
        let merged = SessionFreshnessFilter.mergeCloudAndLocalSessions(
            cloudFresh: [cloudOther],
            localFresh: [local]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains(where: { $0.provider == "Codex" }))
        XCTAssertTrue(merged.contains(where: { $0.provider == "Claude" }))
    }

    func test_merge_collidingId_localWins() {
        let now = Date()
        // Cloud uploaded a synthesized row earlier; local has a fresher mtime.
        let local = makeLocalSynthSession(id: "abc", project: "cli-pulse", lastActive: now.addingTimeInterval(-10))
        let cloudOlder = SessionRecord(
            id: "jsonl-codex-abc",          // same id key
            name: "Codex session",
            provider: "Codex",
            project: "cli-pulse",
            device_name: "MacBook Pro",
            started_at: isoFormatter.string(from: now.addingTimeInterval(-400)),
            last_active_at: isoFormatter.string(from: now.addingTimeInterval(-200)),
            status: "Running",
            total_usage: 1,
            estimated_cost: 0,
            cost_status: "normal",
            requests: 1, error_count: 0
        )
        let merged = SessionFreshnessFilter.mergeCloudAndLocalSessions(
            cloudFresh: [cloudOlder],
            localFresh: [local]
        )
        XCTAssertEqual(merged.count, 1, "collision must dedupe to one row")
        XCTAssertEqual(merged.first?.last_active_at, local.last_active_at, "local wins")
    }

    func test_merge_isOrderedByMostRecentlyActive() {
        let now = Date()
        let older = makeLocalSynthSession(id: "old", project: "p1", lastActive: now.addingTimeInterval(-200))
        let newer = makeLocalSynthSession(id: "new", project: "p2", lastActive: now.addingTimeInterval(-30))
        let merged = SessionFreshnessFilter.mergeCloudAndLocalSessions(
            cloudFresh: [],
            localFresh: [older, newer]
        )
        XCTAssertEqual(merged.first?.project, "p2", "Most recently active first")
    }

    // MARK: - resolveCloudSessions (iter23.1 bug fix)

    /// Pin the iter23 → iter23.1 regression: the cloud-route session
    /// merge MUST consume `costScanData.activeSessionCandidates`
    /// directly. Pre-iter23.1 it pulled from
    /// `scanResult?.activeSessionCandidates ?? []` where
    /// `scanResult` was `nil` whenever `costScanData.entries`
    /// was empty — which happens for a brand-new Codex JSONL
    /// before the daily-bucket parser has caught up. The result
    /// was an empty Sessions tab while Codex was still actively
    /// writing.
    func test_resolveCloudSessions_freshCandidate_withEmptyEntries_yieldsFinalSession() {
        let now = Date()
        // The candidate input mimics what
        // `CostUsageScanner.buildCodexCandidates` emits for a
        // freshly-written rollout JSONL whose token entries
        // haven't been parsed into the cache yet.
        let candidate = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex",
            filePath: "/tmp/fresh.jsonl",
            projectName: "cli-pulse",
            projectRoot: "/Users/jason/cli-pulse",
            sessionId: "fresh-session-1",
            lastModified: now.addingTimeInterval(-30),
            totalTokens: 0,
            totalCost: 0,
            messageCount: 0
        )

        let resolution = SessionFreshnessFilter.resolveCloudSessions(
            cloudSessions: [],          // server hasn't seen this session yet
            candidates: [candidate],
            deviceName: "test-host",
            now: now
        )

        XCTAssertEqual(resolution.candidatesRaw, 1, "Helper must count candidates BEFORE the empty-entries gate")
        XCTAssertEqual(resolution.localSynth, 1, "Synthesized session must be retained")
        XCTAssertEqual(resolution.merged.count, 1)
        let session = resolution.merged.first
        XCTAssertEqual(session?.provider, "Codex")
        XCTAssertEqual(session?.project, "cli-pulse")
    }

    func test_resolveCloudSessions_staleCloudHelperRow_andFreshCandidate_dropsHelperRow() {
        let now = Date()
        let staleHelperRow = SessionRecord(
            id: "cloud-stale-1",
            name: "/Applications/Claude.app/Contents/MacOS/Claude",   // process artifact
            provider: "Claude",
            project: "cli-pulse",
            device_name: "CLI Pulse Helper",
            started_at: isoFormatter.string(from: now.addingTimeInterval(-30 * 86400)),
            last_active_at: isoFormatter.string(from: now.addingTimeInterval(-28 * 86400)),
            status: "ended",
            total_usage: 0, estimated_cost: 0, cost_status: "Estimated",
            requests: 0, error_count: 0
        )
        let candidate = CostUsageScanResult.ActiveSessionCandidate(
            provider: "Codex",
            filePath: "/tmp/fresh-2.jsonl",
            projectName: "cli-pulse",
            projectRoot: "/Users/jason/cli-pulse",
            sessionId: "fresh-2",
            lastModified: now.addingTimeInterval(-15),
            totalTokens: 0, totalCost: 0, messageCount: 0
        )
        let resolution = SessionFreshnessFilter.resolveCloudSessions(
            cloudSessions: [staleHelperRow],
            candidates: [candidate],
            deviceName: "MacBook Pro",
            now: now
        )
        XCTAssertEqual(resolution.cloudFresh, 0, "stale helper row must be filtered before merge")
        XCTAssertEqual(resolution.merged.count, 1)
        XCTAssertEqual(resolution.merged.first?.provider, "Codex")
    }

    func test_resolveCloudSessions_emptyEverywhere_returnsEmpty() {
        let resolution = SessionFreshnessFilter.resolveCloudSessions(
            cloudSessions: [],
            candidates: [],
            deviceName: "MacBook Pro",
            now: Date()
        )
        XCTAssertTrue(resolution.merged.isEmpty)
        XCTAssertEqual(resolution.cloudRaw, 0)
        XCTAssertEqual(resolution.candidatesRaw, 0)
    }

    func test_merge_dropsCloudRowsThatLookLikeProcessArtifacts_throughUpstreamFilter() {
        // The merge function trusts that callers already passed
        // both inputs through `filterCurrent`. This test pins the
        // documented expectation: artifact rows must be removed by
        // the caller's filter step before merging — this test mirrors
        // what the cloud-route caller in DataRefreshManager does.
        let now = Date()
        let cloudArtifact = makeSession(
            name: "/Applications/Claude.app/Contents/MacOS/Claude",
            device: "CLI Pulse Helper",
            lastActive: now.addingTimeInterval(-30)
        )
        let local = makeLocalSynthSession(id: "live", project: "cli-pulse", lastActive: now.addingTimeInterval(-10))

        // Caller-side filter step that must precede the merge.
        let filteredCloud = SessionFreshnessFilter.filterCurrent([cloudArtifact], now: now)
        let merged = SessionFreshnessFilter.mergeCloudAndLocalSessions(
            cloudFresh: filteredCloud,
            localFresh: [local]
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.provider, "Codex")
    }
}
