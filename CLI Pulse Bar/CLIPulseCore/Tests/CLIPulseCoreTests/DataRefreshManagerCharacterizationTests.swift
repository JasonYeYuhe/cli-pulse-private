import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Characterization tests for the pure `nonisolated static` helpers on
/// `DataRefreshManager` that drive the provider-data pipeline. These
/// pin the observable behavior so the v1.10 refactor of AppState /
/// DataRefreshManager can't accidentally change them.
///
/// Target functions (per plan P1-6):
///   - DataRefreshManager.mergeCloudWithLocal
///   - DataRefreshManager.applyCostScan
final class DataRefreshManagerCharacterizationTests: XCTestCase {

    // MARK: - Helpers

    private func makeMetadata(supportsQuota: Bool = true) -> ProviderMetadata {
        ProviderMetadata(
            display_name: "test",
            category: "cli",
            supports_exact_cost: false,
            supports_quota: supportsQuota
        )
    }

    private func makeProvider(
        _ name: String,
        today: Int = 0, week: Int = 0,
        todayCost: Double = 0, weekCost: Double = 0,
        quota: Int? = nil, remaining: Int? = nil,
        tiers: [TierDTO] = [],
        supportsQuota: Bool = true
    ) -> ProviderUsage {
        ProviderUsage(
            provider: name,
            today_usage: today, week_usage: week,
            estimated_cost_today: todayCost, estimated_cost_week: weekCost,
            cost_status_today: todayCost > 0 ? "Estimated" : "Unavailable",
            cost_status_week:  weekCost  > 0 ? "Estimated" : "Unavailable",
            quota: quota, remaining: remaining,
            tiers: tiers, status_text: "",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: makeMetadata(supportsQuota: supportsQuota)
        )
    }

    /// Fixed "now" used by every cost-scan test to eliminate midnight-rollover
    /// flakiness. 2026-04-21T12:00:00Z is arbitrary — must stay in sync with
    /// `todayYMD()` + `ymd(daysAgo:)` below.
    private let testNow = Date(timeIntervalSince1970: 1_774_065_600)  // 2026-04-21 noon UTC

    private func todayYMD() -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: testNow)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func ymd(daysAgo: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: testNow)!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: - mergeCloudWithLocal

    func testMergeEmptyCloudEmptyLocal() {
        let (merged, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: [], local: [])
        XCTAssertTrue(merged.isEmpty)
        XCTAssertTrue(supp.isEmpty)
    }

    func testMergeCloudOnlyReturnsCloudUnchanged() {
        let cloud = [makeProvider("Codex", today: 42)]
        let (merged, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: [])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.provider, "Codex")
        XCTAssertEqual(merged.first?.today_usage, 42)
        XCTAssertTrue(supp.isEmpty)
    }

    func testMergeLocalOnlyPromotesToProviderUsage() {
        let local = [
            CollectorResult(
                usage: makeProvider("Claude", quota: 100, remaining: 25),
                dataKind: .quota
            )
        ]
        let (merged, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: [], local: local)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.provider, "Claude")
        XCTAssertEqual(merged.first?.quota, 100)
        XCTAssertEqual(merged.first?.remaining, 25)
        XCTAssertEqual(supp, ["Claude"])
    }

    func testMergeStatusOnlyLocalResultsIgnored() {
        let local = [
            CollectorResult(
                usage: makeProvider("Ollama"),
                dataKind: .statusOnly
            )
        ]
        let (merged, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: [], local: local)
        XCTAssertTrue(merged.isEmpty, "statusOnly collector results must not promote to merged output")
        XCTAssertTrue(supp.isEmpty)
    }

    func testMergeCreditsKindAppliedSameAsQuota() {
        let local = [
            CollectorResult(
                usage: makeProvider("OpenRouter", today: 5),
                dataKind: .credits
            )
        ]
        let (merged, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: [], local: local)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(supp, ["OpenRouter"])
    }

    func testMergeOverlapReplacesQuotaAndTiersFromLocal() {
        let cloudTier = TierDTO(name: "CloudTier", quota: 100, remaining: 10)
        let localTier = TierDTO(name: "LocalTier", quota: 100, remaining: 90)
        let cloud = [makeProvider("Codex", quota: 100, remaining: 10, tiers: [cloudTier])]
        let local = [CollectorResult(
            usage: makeProvider("Codex", quota: 200, remaining: 150, tiers: [localTier]),
            dataKind: .quota
        )]
        let (merged, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: local)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.quota, 200, "local quota must win over cloud")
        XCTAssertEqual(merged.first?.remaining, 150)
        XCTAssertEqual(merged.first?.tiers.map(\.name), ["LocalTier"])
        XCTAssertEqual(supp, ["Codex"])
    }

    func testMergeOverlapPreservesCloudActivitySeries() {
        let cloudTrend = [UsagePoint(timestamp: "2026-04-21", value: 5)]
        let cloudRecent = ["s1", "s2"]
        let cloud = [ProviderUsage(
            provider: "Gemini",
            today_usage: 20, week_usage: 80,
            estimated_cost_today: 1.2, estimated_cost_week: 3.1,
            cost_status_today: "Estimated", cost_status_week: "Estimated",
            quota: 100, remaining: 80,
            tiers: [], status_text: "",
            trend: cloudTrend, recent_sessions: cloudRecent, recent_errors: [],
            metadata: nil
        )]
        let local = [CollectorResult(
            usage: makeProvider("Gemini", quota: 100, remaining: 50),
            dataKind: .quota
        )]
        let (merged, _) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: local)
        XCTAssertEqual(merged.first?.trend.count, 1)
        XCTAssertEqual(merged.first?.recent_sessions, cloudRecent)
        XCTAssertEqual(merged.first?.remaining, 50, "local remaining still wins")
    }

    func testMergeResultSortedByTodayUsageDescending() {
        let cloud = [
            makeProvider("Low", today: 5),
            makeProvider("Top", today: 100),
            makeProvider("Mid", today: 50),
        ]
        let (merged, _) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: [])
        XCTAssertEqual(merged.map(\.provider), ["Top", "Mid", "Low"])
    }

    /// P1-6 follow-up: ties on `today_usage` must fall back to provider-name
    /// ascending so the UI order is deterministic across refreshes. Without
    /// a secondary key, Dictionary iteration order could flip two tied
    /// providers on every refresh and cause visible jitter.
    func testMergeTiesBreakByProviderNameAscending() {
        let cloud = [
            makeProvider("Zulu",    today: 50),
            makeProvider("Alpha",   today: 50),
            makeProvider("Mike",    today: 50),
            makeProvider("Bravo",   today: 100),
        ]
        let (merged, _) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: [])
        XCTAssertEqual(merged.map(\.provider), ["Bravo", "Alpha", "Mike", "Zulu"])
    }

    func testMergeSupplementedSetContainsAllLocalProviders() {
        let local = [
            CollectorResult(usage: makeProvider("A"), dataKind: .quota),
            CollectorResult(usage: makeProvider("B"), dataKind: .credits),
            CollectorResult(usage: makeProvider("C"), dataKind: .statusOnly),  // skipped
        ]
        let (_, supp) = DataRefreshManager.mergeCloudWithLocal(cloud: [], local: local)
        XCTAssertEqual(supp, ["A", "B"])
    }

    func testMergeLocalTodayUsageReplacesWhenGreaterThanZero() {
        let cloud = [makeProvider("Cursor", today: 10, week: 50)]
        let local = [CollectorResult(
            usage: makeProvider("Cursor", today: 30, week: 0),
            dataKind: .quota
        )]
        let (merged, _) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: local)
        XCTAssertEqual(merged.first?.today_usage, 30, "non-zero local today wins")
        XCTAssertEqual(merged.first?.week_usage, 50, "zero local week falls back to cloud")
    }

    /// Day-side counterpart of the week fallback test: a zero local `today_usage`
    /// must fall back to cloud, same rule as week.
    func testMergeLocalZeroTodayFallsBackToCloudTodayUsage() {
        let cloud = [makeProvider("Cursor", today: 10, week: 50)]
        let local = [CollectorResult(
            usage: makeProvider("Cursor", today: 0, week: 80),
            dataKind: .quota
        )]
        let (merged, _) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: local)
        XCTAssertEqual(merged.first?.today_usage, 10, "zero local today falls back to cloud")
        XCTAssertEqual(merged.first?.week_usage, 80)
    }

    /// An empty local tiers array must NOT wipe the cloud tiers. Local only
    /// replaces cloud tiers when local provides its own.
    func testMergeOverlapEmptyLocalTiersPreservesCloudTiers() {
        let cloudTier = TierDTO(name: "CloudTier", quota: 100, remaining: 20)
        let cloud = [makeProvider("Codex", quota: 100, remaining: 10, tiers: [cloudTier])]
        let local = [CollectorResult(
            usage: makeProvider("Codex", quota: 150, remaining: 120, tiers: []),
            dataKind: .quota
        )]
        let (merged, _) = DataRefreshManager.mergeCloudWithLocal(cloud: cloud, local: local)
        XCTAssertEqual(merged.first?.tiers.map(\.name), ["CloudTier"],
                       "empty local tiers must not overwrite cloud tiers")
        XCTAssertEqual(merged.first?.quota, 150, "non-tier local quota still wins")
    }

    /// Ancillary merge fields (plan_type / reset_time / status_text / metadata):
    /// local wins if non-nil / non-empty, else cloud survives.
    func testMergeOverlapAncillaryFieldsPreferNonEmptyLocalOtherwiseCloud() {
        let cloud = ProviderUsage(
            provider: "Codex",
            today_usage: 10, week_usage: 50,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 10,
            plan_type: "Pro", reset_time: "2026-05-01T00:00:00Z",
            tiers: [], status_text: "cloud-status",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: makeMetadata()
        )
        // Local omits plan_type / reset_time / status_text / metadata → cloud survives
        let localEmpty = [CollectorResult(
            usage: ProviderUsage(
                provider: "Codex",
                today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: 100, remaining: 50,
                plan_type: nil, reset_time: nil,
                tiers: [], status_text: "",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: nil
            ),
            dataKind: .quota
        )]
        let (m1, _) = DataRefreshManager.mergeCloudWithLocal(cloud: [cloud], local: localEmpty)
        XCTAssertEqual(m1.first?.plan_type, "Pro")
        XCTAssertEqual(m1.first?.reset_time, "2026-05-01T00:00:00Z")
        XCTAssertEqual(m1.first?.status_text, "cloud-status")
        XCTAssertNotNil(m1.first?.metadata, "metadata nil on local must preserve cloud metadata")

        // Local supplies non-empty versions → local wins
        let localFull = [CollectorResult(
            usage: ProviderUsage(
                provider: "Codex",
                today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: 100, remaining: 50,
                plan_type: "Team", reset_time: "2026-06-01T00:00:00Z",
                tiers: [], status_text: "local-status",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: makeMetadata(supportsQuota: false)
            ),
            dataKind: .quota
        )]
        let (m2, _) = DataRefreshManager.mergeCloudWithLocal(cloud: [cloud], local: localFull)
        XCTAssertEqual(m2.first?.plan_type, "Team")
        XCTAssertEqual(m2.first?.reset_time, "2026-06-01T00:00:00Z")
        XCTAssertEqual(m2.first?.status_text, "local-status")
        XCTAssertEqual(m2.first?.metadata?.supports_quota, false,
                       "non-nil local metadata wins over cloud metadata")
    }

    // MARK: - applyCostScan

    func testApplyCostScanNilReturnsProvidersUnchanged() {
        let input = [makeProvider("Codex", today: 5, todayCost: 1.5)]
        let out = DataRefreshManager.applyCostScan(to: input, scan: nil)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.estimated_cost_today, 1.5)
    }

    func testApplyCostScanEmptyEntriesReturnsProvidersUnchanged() {
        let input = [makeProvider("Codex", todayCost: 2.5)]
        let scan = CostUsageScanResult(entries: [])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.estimated_cost_today, 2.5)
    }

    func testApplyCostScanProviderMissingFromScanUnchanged() {
        let input = [
            makeProvider("Codex", todayCost: 2.0),
            makeProvider("Claude", todayCost: 3.0),
        ]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Codex", model: "x",
                inputTokens: 1000, cachedTokens: 0, outputTokens: 500, costUSD: 2.5
            )
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first { $0.provider == "Claude" }?.estimated_cost_today, 3.0,
                       "provider absent from scan must be returned unchanged")
    }

    func testApplyCostScanMaxSemanticsCostNeverDecreases() {
        let input = [makeProvider("Codex", todayCost: 10.0)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Codex", model: "x",
                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 2.0
            )
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.estimated_cost_today, 10.0,
                       "scan cost 2.0 < cloud cost 10.0 → cloud preserved via max")
    }

    func testApplyCostScanMergesWhenScanExceedsCloud() {
        let input = [makeProvider("Codex", todayCost: 1.0)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Codex", model: "x",
                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 5.5
            )
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.estimated_cost_today ?? 0, 5.5, accuracy: 0.001)
        XCTAssertEqual(out.first?.cost_status_today, "Estimated")
    }

    func testApplyCostScanNonQuotaProviderUpdatesTokens() {
        let input = [makeProvider("Copilot", supportsQuota: false)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Copilot", model: "gpt-4o",
                inputTokens: 2000, cachedTokens: 0, outputTokens: 1000, costUSD: 0.3
            )
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.today_usage, 3000,
                       "non-quota provider's today_usage must reflect input+output token totals")
    }

    func testApplyCostScanQuotaProviderTokensNotOverwritten() {
        let input = [makeProvider("Codex", today: 75, supportsQuota: true)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Codex", model: "x",
                inputTokens: 10_000, cachedTokens: 0, outputTokens: 5_000, costUSD: 1.0
            )
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.today_usage, 75,
                       "quota-provider today_usage (% utilization) must survive scan application")
    }

    func testApplyCostScanRollingWeekIncludesSevenDays() {
        // Day -6 (inclusive) should contribute to week cost, day -7 should not.
        let input = [makeProvider("Codex", weekCost: 0)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: ymd(daysAgo: 6), provider: "Codex", model: "x",
                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 10.0
            ),
            CostUsageScanResult.DailyEntry(
                date: ymd(daysAgo: 7), provider: "Codex", model: "x",
                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 99.0
            ),
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.estimated_cost_week ?? 0, 10.0, accuracy: 0.001,
                       "rolling week spans today + previous 6 days (off-by-one regression guard)")
    }

    /// Multiple scan rows for the same (provider, day) must aggregate, not
    /// overwrite. Regression guard — a naive last-write-wins refactor would
    /// silently drop costs from models-other-than-the-last.
    func testApplyCostScanAggregatesMultipleEntriesForSameProvider() {
        let input = [makeProvider("Codex", supportsQuota: false)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Codex", model: "gpt-5",
                inputTokens: 1000, cachedTokens: 0, outputTokens: 500, costUSD: 1.2
            ),
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Codex", model: "gpt-4o",
                inputTokens: 2000, cachedTokens: 0, outputTokens: 800, costUSD: 0.8
            ),
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.estimated_cost_today ?? 0, 2.0, accuracy: 0.001,
                       "multi-model scan rows for same provider+day must sum")
        XCTAssertEqual(out.first?.today_usage, 4300,
                       "non-quota provider today_usage sums across all scan rows")
    }

    /// Week-side cost + status: must roll up same way as today, and flip
    /// `cost_status_week` to "Estimated" when a non-zero weekly cost lands.
    func testApplyCostScanUpdatesWeekUsageAndStatusWeek() {
        let input = [makeProvider("Copilot", weekCost: 0, supportsQuota: false)]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: ymd(daysAgo: 3), provider: "Copilot", model: "gpt-4o",
                inputTokens: 500, cachedTokens: 0, outputTokens: 500, costUSD: 4.0
            ),
            CostUsageScanResult.DailyEntry(
                date: todayYMD(), provider: "Copilot", model: "gpt-4o",
                inputTokens: 100, cachedTokens: 0, outputTokens: 100, costUSD: 1.0
            ),
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.estimated_cost_week ?? 0, 5.0, accuracy: 0.001,
                       "week cost must sum today + within-window entries")
        XCTAssertEqual(out.first?.cost_status_week, "Estimated",
                       "non-zero week cost flips status to Estimated")
        XCTAssertEqual(out.first?.week_usage, 1200,
                       "non-quota week_usage = Σ(input+output) within window")
    }

    func testApplyCostScanTodayFilterExcludesYesterday() {
        let input = [makeProvider("Codex")]
        let scan = CostUsageScanResult(entries: [
            CostUsageScanResult.DailyEntry(
                date: ymd(daysAgo: 1), provider: "Codex", model: "x",
                inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: 99.0
            )
        ])
        let out = DataRefreshManager.applyCostScan(to: input, scan: scan, now: testNow)
        XCTAssertEqual(out.first?.estimated_cost_today, 0.0,
                       "yesterday's entries must not count toward todayCost")
    }
}

#endif
