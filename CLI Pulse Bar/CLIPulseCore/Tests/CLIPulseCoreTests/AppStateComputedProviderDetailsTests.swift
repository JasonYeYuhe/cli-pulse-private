import XCTest
@testable import CLIPulseCore

/// P1-6 follow-up: characterization tests for `AppState.computedProviderDetails`,
/// the pure form extracted from `AppState.buildProviderDetails()` so this
/// user-visible contract can be pinned before the P2-3 refactor splits up
/// AppState.
///
/// Pinned behaviors:
///   - sort order follows `config.sortOrder` ascending
///   - configs without a matching `ProviderUsage` are skipped (compactMap)
///   - tier synthesis: per-tier data wins; else "Default" bar for
///     non-Claude providers with quota>0; else no tiers
///   - Claude with empty tiers + quota > 0 → NO synthesised bar
///   - sourceMode=.auto drives the effective source:
///       * isLocalMode → .local
///       * else supplemented → .merged
///       * else → .api
///     sourceMode != .auto overrides everything
final class AppStateComputedProviderDetailsTests: XCTestCase {

    private func makeMetadata() -> ProviderMetadata {
        ProviderMetadata(display_name: "test", category: "cli")
    }

    private func makeUsage(
        provider: String, today: Int = 0, quota: Int? = nil, remaining: Int? = nil,
        planType: String? = nil, tiers: [TierDTO] = []
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            today_usage: today, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: quota, remaining: remaining, plan_type: planType,
            tiers: tiers, status_text: "",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: makeMetadata()
        )
    }

    private func config(_ kind: ProviderKind, sortOrder: Int = 0,
                        source: SourceType = .auto) -> ProviderConfig {
        ProviderConfig(kind: kind, sortOrder: sortOrder, sourceMode: source)
    }

    // MARK: - Ordering + skipping

    func testSortOrderAscendingDrivesOutput() {
        let usages = [
            makeUsage(provider: ProviderKind.codex.rawValue),
            makeUsage(provider: ProviderKind.gemini.rawValue),
            makeUsage(provider: ProviderKind.claude.rawValue),
        ]
        let configs = [
            config(.codex,  sortOrder: 10),
            config(.gemini, sortOrder: 5),
            config(.claude, sortOrder: 1),
        ]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: configs,
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.map { $0.provider.provider },
                       [ProviderKind.claude.rawValue,
                        ProviderKind.gemini.rawValue,
                        ProviderKind.codex.rawValue])
    }

    func testConfigWithNoMatchingUsageIsSkipped() {
        let usages = [makeUsage(provider: ProviderKind.codex.rawValue)]
        let configs = [config(.codex, sortOrder: 1),
                       config(.gemini, sortOrder: 2)]   // no matching usage
        let out = AppState.computedProviderDetails(
            providers: usages, configs: configs,
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.provider.provider, ProviderKind.codex.rawValue)
    }

    // MARK: - Tier synthesis

    func testPerTierDataPreservedWhenPresent() {
        let tierA = TierDTO(name: "Weekly",  quota: 100, remaining: 20)
        let tierB = TierDTO(name: "Session", quota: 50,  remaining: 10)
        let usages = [makeUsage(
            provider: ProviderKind.codex.rawValue, tiers: [tierA, tierB]
        )]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex)],
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.first?.tiers.map(\.name), ["Weekly", "Session"])
        XCTAssertEqual(out.first?.tiers.map(\.usage),    [80, 40])
        XCTAssertEqual(out.first?.tiers.map(\.quota),    [100, 50])
    }

    func testZeroQuotaTierIsFilteredOut() {
        let tierA = TierDTO(name: "Active",   quota: 100, remaining: 20)
        let tierB = TierDTO(name: "Disabled", quota: 0,   remaining: 0)
        let usages = [makeUsage(
            provider: ProviderKind.codex.rawValue, tiers: [tierA, tierB]
        )]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex)],
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.first?.tiers.map(\.name), ["Active"])
    }

    func testDefaultTierSynthesizedForNonClaudeProviderWithQuota() {
        let usages = [makeUsage(
            provider: ProviderKind.cursor.rawValue, today: 42,
            quota: 100, remaining: 58, tiers: []
        )]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.cursor)],
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.first?.tiers.count, 1)
        XCTAssertEqual(out.first?.tiers.first?.name, "Default")
        XCTAssertEqual(out.first?.tiers.first?.usage, 42)
        XCTAssertEqual(out.first?.tiers.first?.quota, 100)
    }

    /// Claude-specific: empty tiers + quota present → NO synthesised bar.
    /// For Claude, missing tier data means "data unavailable", not a generic
    /// bar — critical UX contract.
    func testClaudeWithEmptyTiersDoesNotSynthesizeDefaultBar() {
        let usages = [makeUsage(
            provider: ProviderKind.claude.rawValue, today: 42,
            quota: 100, remaining: 58, tiers: []
        )]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.claude)],
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertTrue(out.first?.tiers.isEmpty ?? false,
                      "Claude with no per-tier data must NOT produce a Default bar")
    }

    func testNoQuotaAndNoTiersProducesEmptyTierList() {
        let usages = [makeUsage(provider: ProviderKind.codex.rawValue, quota: nil, remaining: nil)]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex)],
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertTrue(out.first?.tiers.isEmpty ?? false)
    }

    // MARK: - Source resolution

    func testAutoSourceMapsToLocalInLocalMode() {
        let usages = [makeUsage(provider: ProviderKind.codex.rawValue)]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex, source: .auto)],
            isLocalMode: true, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.first?.sourceType, .local)
    }

    func testAutoSourceMapsToMergedWhenSupplemented() {
        let usages = [makeUsage(provider: ProviderKind.codex.rawValue)]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex, source: .auto)],
            isLocalMode: false,
            locallySupplementedProviders: [ProviderKind.codex.rawValue]
        )
        XCTAssertEqual(out.first?.sourceType, .merged)
    }

    func testAutoSourceFallsBackToApi() {
        let usages = [makeUsage(provider: ProviderKind.codex.rawValue)]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex, source: .auto)],
            isLocalMode: false, locallySupplementedProviders: []
        )
        XCTAssertEqual(out.first?.sourceType, .api)
    }

    func testExplicitSourceModeOverridesAutoResolution() {
        let usages = [makeUsage(provider: ProviderKind.codex.rawValue)]
        // Explicit .api set even though we're in local mode — explicit wins.
        let out = AppState.computedProviderDetails(
            providers: usages, configs: [config(.codex, source: .api)],
            isLocalMode: true, locallySupplementedProviders: [ProviderKind.codex.rawValue]
        )
        XCTAssertEqual(out.first?.sourceType, .api)
    }

    // MARK: - End-to-end round-trip

    func testMultipleProvidersSortedFilteredAndResolved() {
        let usages = [
            makeUsage(provider: ProviderKind.codex.rawValue,  quota: 100, remaining: 30),  // non-Claude
            makeUsage(provider: ProviderKind.gemini.rawValue),                              // no quota
            makeUsage(provider: ProviderKind.claude.rawValue, quota: 100, remaining: 30),  // Claude, empty tiers
        ]
        let configs = [
            config(.codex,  sortOrder: 3),
            config(.gemini, sortOrder: 1),
            config(.claude, sortOrder: 2),
        ]
        let out = AppState.computedProviderDetails(
            providers: usages, configs: configs,
            isLocalMode: false, locallySupplementedProviders: [ProviderKind.codex.rawValue]
        )
        XCTAssertEqual(out.map { $0.provider.provider },
                       [ProviderKind.gemini.rawValue,
                        ProviderKind.claude.rawValue,
                        ProviderKind.codex.rawValue])
        // gemini: no quota, no tiers
        XCTAssertTrue(out[0].tiers.isEmpty)
        // claude: quota present but no per-tier → NO default bar
        XCTAssertTrue(out[1].tiers.isEmpty)
        // codex: default bar synthesised
        XCTAssertEqual(out[2].tiers.first?.name, "Default")
        // sources
        XCTAssertEqual(out[2].sourceType, .merged, "codex supplemented")
        XCTAssertEqual(out[0].sourceType, .api)
    }
}
