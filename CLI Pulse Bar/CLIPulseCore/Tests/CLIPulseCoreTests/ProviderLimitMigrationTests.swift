#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.10.4 free-tier fix — provider-limit migration.
/// `AppState.migrateProviderLimitsIfNeeded()` auto-disables extra providers
/// for free-tier users when active provider count exceeds the plan limit.
///
/// **iter9 hotfix (2026-04-29)** — the gate was changed from raw enabled-toggle
/// count (`providerConfigs.filter(\.isEnabled).count`) to canonical
/// `activeKindsForMigrationBanner` (server-side usage OR enabled+credentialed
/// configs). Previously every fresh user saw "Disabled 23 providers" on first
/// launch because `ProviderConfig.defaults()` enables all 26 ProviderKind
/// cases, and the migration happily disabled the 23 that didn't fit. The new
/// contract: no migration runs (and therefore no scary banner) until actively-
/// used providers genuinely exceed the plan limit.
@MainActor
final class ProviderLimitMigrationTests: XCTestCase {

    private let disabledByTierKey = "cli_pulse_providers_disabled_by_tier"
    private let configsKey = "cli_pulse_provider_configs"

    override func setUp() {
        super.setUp()
        // Ensure every test starts with a clean slate.
        UserDefaults.standard.removeObject(forKey: disabledByTierKey)
        UserDefaults.standard.removeObject(forKey: configsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: disabledByTierKey)
        UserDefaults.standard.removeObject(forKey: configsKey)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeUsage(_ provider: String, today: Int = 100, week: Int = 200) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            today_usage: today, week_usage: week,
            estimated_cost_today: 0.5, estimated_cost_week: 1.5,
            cost_status_today: "Estimated", cost_status_week: "Estimated",
            quota: 1000, remaining: 800,
            tiers: [], status_text: "",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: nil
        )
    }

    // MARK: - iter9 contract: no banner without active over-limit

    /// Regression for the iter9 user complaint:
    ///   "Kept your 3 most-used providers to fit the free plan. Disabled 23
    ///    — edit in Settings → Providers."
    /// shown when the user actually only had 2 active providers.
    /// Fresh free user with 26 default-enabled toggles and ZERO active
    /// providers (no usage, no credentials) must see no migration, no
    /// banner. All 26 toggles remain enabled.
    func testFreeUserNoActiveProvidersDoesNotMigrate() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping free-tier migration test")
        }
        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, 26,
                       "defaults() should enable all 26")
        // No usage rows, no credentials → activeCount = 0.

        state.migrateProviderLimitsIfNeeded()

        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, 26,
                       "no active providers → no toggle pruning")
        XCTAssertEqual(state.providerLimitMigrationCount, 0,
                       "no active providers → no banner")
    }

    /// 26 default toggles + 2 active providers (Ollama + Claude with usage)
    /// + free limit 3 → no migration, no banner. Pinned by user spec.
    func testTwoActiveProvidersUnderLimitDoesNotMigrate() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }
        // Simulate two active providers via server-side usage rows.
        // ProviderKind raw values are lowercase (e.g. "claude", "ollama").
        state.providers = [
            makeUsage(ProviderKind.claude.rawValue),
            makeUsage(ProviderKind.ollama.rawValue),
        ]

        state.migrateProviderLimitsIfNeeded()

        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, 26,
                       "2 active <= 3 limit → no toggle pruning")
        XCTAssertEqual(state.providerLimitMigrationCount, 0,
                       "user must NOT see 'Disabled 23' on a fresh free install")
    }

    /// Exactly at the limit (3 active, limit 3) is a no-op too.
    func testActiveCountEqualToLimitDoesNotMigrate() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }
        state.providers = [
            makeUsage(ProviderKind.claude.rawValue),
            makeUsage(ProviderKind.codex.rawValue),
            makeUsage(ProviderKind.gemini.rawValue),
        ]

        state.migrateProviderLimitsIfNeeded()

        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, 26,
                       "active == limit → still no prune (only OVER triggers)")
        XCTAssertEqual(state.providerLimitMigrationCount, 0)
    }

    // MARK: - iter9 contract: actively-used over-limit DOES migrate

    /// 6 actively-used providers + free limit 3 → migration fires. Banner
    /// reports the count of *actively-used* providers disabled (3), not the
    /// raw toggle count (which would also include the 20 untouched defaults).
    func testSixActiveProvidersOverLimitTriggersMigrationWithAccurateBanner() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }
        let limit = state.subscriptionManager.maxProviders  // 3 on free
        // 6 active providers via server-side usage rows.
        let activeKinds: [ProviderKind] = [.claude, .codex, .gemini, .ollama, .openRouter, .cursor]
        state.providers = activeKinds.map { makeUsage($0.rawValue) }

        state.migrateProviderLimitsIfNeeded()

        let stillEnabled = Set(state.providerConfigs.filter(\.isEnabled).map(\.kind))
        XCTAssertEqual(stillEnabled.count, limit,
                       "should leave exactly maxProviders enabled")
        XCTAssertTrue(stillEnabled.allSatisfy { activeKinds.contains($0) },
                      "kept providers must come from the active set")
        // Banner reports `active_disabled` (6 - 3 = 3), not `total_disabled`
        // which would be 26 - 3 = 23 (all toggles minus kept).
        XCTAssertEqual(state.providerLimitMigrationCount, activeKinds.count - limit,
                       "banner counts only actively-used providers disabled, not default toggles")
    }

    /// User spec: "migration still protects downgrade users with many
    /// credentialed/used providers." Simulate a Pro→Free downgrade where
    /// the user had configured credentials for 5 providers. Active count
    /// = 5 (each enabled+credentialed counts as active), 5 > 3 → migration
    /// runs, banner reports 2 (5 - 3) actively-used disabled.
    func testDowngradeWithFiveCredentialedProvidersFiresMigration() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }
        let limit = state.subscriptionManager.maxProviders
        // Mark 5 providers as credentialed in-memory (we don't need the
        // Keychain round-trip — `hasCredentials` reads transient apiKey).
        let credentialedKinds: [ProviderKind] = [.claude, .codex, .gemini, .ollama, .openRouter]
        for kind in credentialedKinds {
            if let idx = state.providerConfigs.firstIndex(where: { $0.kind == kind }) {
                state.providerConfigs[idx].apiKey = "test-key-\(kind.rawValue)"
            }
        }
        XCTAssertEqual(
            state.providerConfigs.filter { credentialedKinds.contains($0.kind) }.allSatisfy(\.hasCredentials),
            true,
            "test setup invariant: all 5 marked configs report hasCredentials"
        )

        state.migrateProviderLimitsIfNeeded()

        let stillEnabled = Set(state.providerConfigs.filter(\.isEnabled).map(\.kind))
        XCTAssertEqual(stillEnabled.count, limit)
        XCTAssertEqual(state.providerLimitMigrationCount, credentialedKinds.count - limit,
                       "downgrade scenario: banner reports 5-3=2 active providers disabled")
    }

    /// Paid user (or unlimited tier) — `maxProviders < 0` short-circuits
    /// before the active-count check. Banner stays at 0; the disabled-by-
    /// tier set gets cleared so a previous Free→Pro upgrade un-badges
    /// providers in Settings.
    func testPaidTierClearsBadgesAndExits() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders < 0 else {
            throw XCTSkip("Free tier in test environment — paid path can't run")
        }
        // Pre-seed disabled-by-tier (simulating a prior free-tier session).
        UserDefaults.standard.set(["claude"], forKey: disabledByTierKey)

        state.migrateProviderLimitsIfNeeded()

        XCTAssertNil(UserDefaults.standard.array(forKey: disabledByTierKey),
                     "paid-tier path must clear stale tier-disabled badges")
        XCTAssertEqual(state.providerLimitMigrationCount, 0)
    }

    // MARK: - Idempotency / dismiss

    /// After a real migration run, calling again is a no-op via the
    /// activeCount guard (active providers got pruned to 3, so 3 ≤ 3).
    func testMigrationIdempotentAfterPrune() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }
        let limit = state.subscriptionManager.maxProviders
        let activeKinds: [ProviderKind] = [.claude, .codex, .gemini, .ollama, .openRouter, .cursor]
        state.providers = activeKinds.map { makeUsage($0.rawValue) }

        state.migrateProviderLimitsIfNeeded()
        let firstBanner = state.providerLimitMigrationCount
        XCTAssertEqual(firstBanner, activeKinds.count - limit)
        // Snapshot enabled set after first call.
        let firstEnabled = Set(state.providerConfigs.filter(\.isEnabled).map(\.kind))

        // Reset banner (UI dismiss path) and call again.
        state.dismissProviderLimitMigrationBanner()
        // Second invocation: activeCount is now `limit` (3), not over → no-op.
        // BUT: the providers array still has 6 rows. Active count is computed
        // via `activeKindsForMigrationBanner` which counts usage rows whose
        // kind is recognised — 6 rows → 6. Hmm, that means the gate would
        // still fire on the second call. To test idempotency-after-prune we
        // need to also drop the providers array to reflect what the next
        // refresh cycle would do (server only returns rows for enabled
        // providers). Simulate that by intersecting `providers` with the
        // newly-enabled set:
        state.providers = state.providers.filter { row in
            ProviderKind(rawValue: row.provider).map { firstEnabled.contains($0) } ?? false
        }

        state.migrateProviderLimitsIfNeeded()
        XCTAssertEqual(state.providerLimitMigrationCount, 0,
                       "post-prune state has 3 active <= 3 limit → no second migration")
        XCTAssertEqual(Set(state.providerConfigs.filter(\.isEnabled).map(\.kind)), firstEnabled,
                       "enabled set should be unchanged on the second call")
    }

    /// `dismissProviderLimitMigrationBanner` resets the published count to 0.
    func testDismissBannerResetsCount() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }
        let activeKinds: [ProviderKind] = [.claude, .codex, .gemini, .ollama]
        state.providers = activeKinds.map { makeUsage($0.rawValue) }
        state.migrateProviderLimitsIfNeeded()
        XCTAssertGreaterThan(state.providerLimitMigrationCount, 0,
                             "test setup invariant: banner should fire")

        state.dismissProviderLimitMigrationBanner()
        XCTAssertEqual(state.providerLimitMigrationCount, 0)
    }

    // MARK: - activeKindsForMigrationBanner contract

    /// Pin the static helper that powers the gate — same criteria as
    /// `DataRefreshManager.activeProviderCount` (usage OR credentials).
    func testActiveKindsHelperCountsUsageAndCredentials() {
        let configs: [ProviderConfig] = [
            ProviderConfig(kind: .claude, isEnabled: true),                     // no creds, no usage
            ProviderConfig(kind: .codex, isEnabled: true, apiKey: "k"),          // creds → active
            ProviderConfig(kind: .gemini, isEnabled: false, apiKey: "k"),        // disabled → not active
            ProviderConfig(kind: .ollama, isEnabled: true),                      // counted via usage row below
        ]
        let usage = [
            ProviderUsage(
                provider: ProviderKind.ollama.rawValue,
                today_usage: 50, week_usage: 100,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "", cost_status_week: "",
                quota: nil, remaining: nil, tiers: [],
                status_text: "", trend: [], recent_sessions: [], recent_errors: [],
                metadata: nil
            ),
            // Unknown raw string — must NOT count.
            ProviderUsage(
                provider: "fictional_provider",
                today_usage: 999, week_usage: 999,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "", cost_status_week: "",
                quota: nil, remaining: nil, tiers: [],
                status_text: "", trend: [], recent_sessions: [], recent_errors: [],
                metadata: nil
            ),
        ]
        let active = AppState.activeKindsForMigrationBanner(
            providers: usage, providerConfigs: configs
        )
        XCTAssertEqual(active, Set([.codex, .ollama]),
                       "credentials → codex; usage row → ollama; gemini disabled; unknown raw skipped")
    }
}
#endif
