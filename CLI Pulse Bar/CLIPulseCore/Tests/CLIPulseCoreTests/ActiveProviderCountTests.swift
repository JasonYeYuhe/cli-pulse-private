import XCTest
@testable import CLIPulseCore

/// Pin the contract for the canonical "active provider count" used in the
/// plan-limit warning banner. The user-reported bug v1.11.0 was "Providers:
/// 26/3" warning even though they only had Ollama + Claude actually running
/// — the previous count was `providerConfigs.filter(\.isEnabled).count`,
/// which counts ALL 26 toggles enabled by `defaults()`, not actual usage.
///
/// These tests pin the new behaviour so no future refactor regresses
/// back to the toggle-counting model.
final class ActiveProviderCountTests: XCTestCase {

    // MARK: - test fixtures

    /// Build a ProviderUsage with non-zero today_usage so it counts as
    /// "active" by the rule. Other fields are filled with neutral defaults.
    private func usage(
        provider: String,
        today: Int = 5,
        week: Int = 5,
        costToday: Double = 0,
        costWeek: Double = 0
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            today_usage: today,
            week_usage: week,
            estimated_cost_today: costToday,
            estimated_cost_week: costWeek,
            estimated_cost_30_day: 0,
            cost_status_today: "Estimated",
            cost_status_week: "Estimated",
            quota: nil,
            remaining: nil,
            tiers: [],
            status_text: "",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
    }

    /// Build a ProviderUsage with NO usage signal — should be filtered out
    /// by the activeProviderCount rule.
    private func staleUsage(provider: String) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            estimated_cost_30_day: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            tiers: [],
            status_text: "",
            trend: [], recent_sessions: [], recent_errors: []
        )
    }

    /// Default-shaped `ProviderConfig.defaults()` returns 26 entries, all
    /// enabled, no credentials.
    private func freshDefaults() -> [ProviderConfig] {
        ProviderConfig.defaults()
    }

    /// Convenience: enable credentials on one specific kind in a configs array.
    private func configsWithCredentials(_ kinds: [ProviderKind]) -> [ProviderConfig] {
        var configs = freshDefaults()
        for kind in kinds {
            guard let idx = configs.firstIndex(where: { $0.kind == kind }) else { continue }
            // Use apiKey for credential signal (matches `hasCredentials`
            // which checks apiKey OR cookieSource).
            configs[idx].apiKey = "fake-api-key-for-test"
        }
        return configs
    }

    // MARK: - the 5 cases the spec requires

    func test_allTogglesEnabledNoUsageNoCredentials_countsAsZero() {
        // The user-reported bug, exact reproduction.
        // ProviderConfig.defaults() enables every ProviderKind, 0 credentials, 0 server usage.
        // Asserted against allCases.count so new providers (Phase B/C) don't re-break this.
        let configs = freshDefaults()
        XCTAssertEqual(configs.filter(\.isEnabled).count, ProviderKind.allCases.count,
                       "sanity check: defaults() enables every ProviderKind")
        let count = DataRefreshManager.activeProviderCount(
            providers: [],
            providerConfigs: configs
        )
        XCTAssertEqual(count, 0,
                       "all enabled toggles with no usage and no credentials must count as 0 — that's the bug")
    }

    func test_OllamaWithManyModelsSessionsCountsAsOne() {
        // Server-side `provider_quotas` is keyed (user_id, provider) UNIQUE,
        // so even 20+ Ollama models running collapse into a single
        // ProviderUsage row server-side. Dedup at the activeProviderCount
        // layer is a defense-in-depth: even if duplicates leaked through
        // (e.g. multi-device path), Set<ProviderKind> dedupes.
        // We pass a single Ollama row to mirror real server output.
        let count = DataRefreshManager.activeProviderCount(
            providers: [usage(provider: "Ollama", today: 50)],
            providerConfigs: freshDefaults()
        )
        XCTAssertEqual(count, 1, "Ollama with any number of models = 1 provider")
    }

    func test_OllamaPlusClaudeUsage_24UnusedToggles_countsAsTwo() {
        // The user's actual scenario: Ollama + Claude both have usage,
        // other 24 ProviderKinds enabled by defaults() but never used and
        // no credentials configured. Expected: 2 (not 26).
        let count = DataRefreshManager.activeProviderCount(
            providers: [
                usage(provider: "Ollama", today: 30),
                usage(provider: "Claude", today: 70),
            ],
            providerConfigs: freshDefaults()
        )
        XCTAssertEqual(count, 2,
                       "the actual bug case: Ollama + Claude usage among 26 toggles must count as 2")
    }

    func test_ClaudeUsageAndClaudeCredentialsDeduplicate() {
        // Same provider visible via two different signals (server usage AND
        // local credentials) must be counted ONCE because the dedup is keyed
        // on canonical ProviderKind, not on the signal source.
        let configs = configsWithCredentials([.claude])
        let count = DataRefreshManager.activeProviderCount(
            providers: [usage(provider: "Claude", today: 40)],
            providerConfigs: configs
        )
        XCTAssertEqual(count, 1,
                       "Claude with both server usage and local credentials = 1, not 2")
    }

    func test_MultiDeviceSameProviderAlreadyDedupedInput_countsAsOne() {
        // Server-side `provider_quotas` is UNIQUE on (user_id, provider) so
        // a user with Claude on Mac A and Claude on Mac B sees ONE
        // ProviderUsage row server-side (helper_sync upserts into the same
        // row). We mirror that pre-deduped input here. Set<ProviderKind>
        // would also collapse a hypothetical duplicate, but the right
        // assertion is "trust server dedup → still 1."
        let count = DataRefreshManager.activeProviderCount(
            providers: [usage(provider: "Claude", today: 100)],
            providerConfigs: freshDefaults()
        )
        XCTAssertEqual(count, 1, "multi-device same Claude already deduped server-side = 1")
    }

    // MARK: - extra defensive cases

    func test_StaleProvidersWithNoUsageAreIgnored() {
        // A provider row that lingers from a previous session but has zero
        // usage signal in the current period must NOT count.
        let count = DataRefreshManager.activeProviderCount(
            providers: [
                staleUsage(provider: "Codex"),
                staleUsage(provider: "Gemini"),
            ],
            providerConfigs: freshDefaults()
        )
        XCTAssertEqual(count, 0)
    }

    func test_CostOnlyButZeroTokenUsageStillCounts() {
        // estimated_cost_today > 0 OR estimated_cost_week > 0 is enough
        // signal — some providers (e.g. cost-imported) report cost without
        // token counts. They should still count toward the plan limit.
        let count = DataRefreshManager.activeProviderCount(
            providers: [
                usage(provider: "OpenRouter", today: 0, week: 0, costToday: 0.42)
            ],
            providerConfigs: freshDefaults()
        )
        XCTAssertEqual(count, 1)
    }

    func test_UnknownProviderStringIsSilentlyDroppedNotCounted() {
        // A `provider` value the client doesn't recognise as ProviderKind
        // must NOT count — undercount is safer than over-warn for the user,
        // and prevents a typo / future-kind from inflating the count.
        let count = DataRefreshManager.activeProviderCount(
            providers: [
                usage(provider: "ThisKindDoesNotExist", today: 50)
            ],
            providerConfigs: freshDefaults()
        )
        XCTAssertEqual(count, 0)
    }

    func test_DisabledConfigWithCredentialsIsNotCounted() {
        // If the user explicitly disabled a provider toggle, even configured
        // credentials shouldn't make it count — the toggle is the user's
        // intent.
        var configs = configsWithCredentials([.claude])
        // Find Claude and disable it.
        if let idx = configs.firstIndex(where: { $0.kind == .claude }) {
            configs[idx].isEnabled = false
        }
        let count = DataRefreshManager.activeProviderCount(
            providers: [],
            providerConfigs: configs
        )
        XCTAssertEqual(count, 0,
                       "disabled config + credentials = 0; toggle is authoritative")
    }

    func test_CredentialOnlyNoServerUsageStillCounts() {
        // User just configured an API key but hasn't run anything yet —
        // they're set up to use it, so it counts toward the plan limit.
        // (This avoids a confusing UX where adding a key suddenly bumps
        // them over limit only after they USE it.)
        let count = DataRefreshManager.activeProviderCount(
            providers: [],
            providerConfigs: configsWithCredentials([.codex, .gemini])
        )
        XCTAssertEqual(count, 2)
    }

    func test_FreeTierLimitOf3IsNotExceededWith2ActualProviders() {
        // The end-to-end semantic check: with the free-tier maxProviders=3
        // and the user's actual scenario (2 active), we should be UNDER
        // limit. This pin guards against any future change that re-uses
        // the toggle count.
        let count = DataRefreshManager.activeProviderCount(
            providers: [
                usage(provider: "Ollama", today: 30),
                usage(provider: "Claude", today: 70),
            ],
            providerConfigs: freshDefaults()
        )
        XCTAssertLessThanOrEqual(count, 3,
                                  "user's actual 2-provider setup must fit within free-tier 3-cap")
    }
}
