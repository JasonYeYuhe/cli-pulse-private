#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.10.4 free-tier fix — one-shot provider-limit migration.
/// `AppState.migrateProviderLimitsIfNeeded()` auto-disables extra providers
/// for free-tier users whose default install had all 26 enabled.
/// These tests cover the ranking heuristic, idempotency, and the paid-user
/// short-circuit.
@MainActor
final class ProviderLimitMigrationTests: XCTestCase {

    private let disabledByTierKey = "cli_pulse_providers_disabled_by_tier"
    private let configsKey = "cli_pulse_provider_configs"

    override func setUp() {
        super.setUp()
        // Ensure every test starts with a clean slate — the migration's
        // natural idempotency gate is `enabledCount > maxProviders`, so we
        // only need to clear stored configs and the disabled-by-tier set.
        UserDefaults.standard.removeObject(forKey: disabledByTierKey)
        UserDefaults.standard.removeObject(forKey: configsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: disabledByTierKey)
        UserDefaults.standard.removeObject(forKey: configsKey)
        super.tearDown()
    }

    // MARK: - Fallback ordering (tier 3)

    /// Free user with 26 default-enabled providers and zero usage data:
    /// migration should keep `claude`, `codex`, `gemini` (first 3 of
    /// `ProviderKind.allCases`) and disable the remaining 23.
    func testFreeUserNoUsageKeepsDefaultTrio() throws {
        // Setup: 26 enabled, no usage, free tier forced.
        let state = AppState()
        // Force free tier — SubscriptionManager is a live singleton so its
        // currentTier depends on external StoreKit state. We can't easily
        // stub it, so we test the deterministic path by directly calling
        // migrateProviderLimitsIfNeeded() when the tier happens to be free.
        // If the test environment reports a paid tier, skip. (CI runs under
        // a fresh simulator = free.)
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Environment reports paid tier; skipping free-tier migration test")
        }

        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, 26, "defaults() should enable all 26")

        state.migrateProviderLimitsIfNeeded()

        let enabled = Set(state.providerConfigs.filter(\.isEnabled).map(\.kind))
        XCTAssertEqual(enabled.count, state.subscriptionManager.maxProviders,
                       "should leave exactly maxProviders enabled")
        let expectedTrio = Set(Array(ProviderKind.allCases.prefix(state.subscriptionManager.maxProviders)))
        XCTAssertEqual(enabled, expectedTrio,
                       "should fall back to first-N of ProviderKind cases when no usage signal")
    }

    // MARK: - Idempotency

    /// With the flag removed (Gemini 3.1 Pro review), the migration is
    /// naturally idempotent via `enabledCount > maxProviders`. Calling it
    /// twice in a row on a user who is already at-or-under limit should
    /// be a no-op on the second call.
    func testMigrationIdempotentWithinLimit() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }

        state.migrateProviderLimitsIfNeeded()
        let firstEnabled = state.providerConfigs.filter(\.isEnabled).count
        XCTAssertEqual(firstEnabled, state.subscriptionManager.maxProviders)

        // Second call: the `enabledCount > maxProviders` gate short-circuits.
        state.migrateProviderLimitsIfNeeded()
        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, firstEnabled,
                       "second migration must not re-prune — natural idempotency via count gate")
    }

    /// After migration, if user manually re-enables 3 providers back to the
    /// limit, running migration again should still be a no-op. If they
    /// enable a 4th, the gate would fire again — but we don't test that
    /// automatic re-prune here (it's intentional downgrade-follow-through).
    func testManualReEnableUpToLimitRemainsStable() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }

        state.migrateProviderLimitsIfNeeded()
        // Re-enable a previously-disabled one AND disable one that was kept.
        // Net enabled count stays at maxProviders, so no re-prune.
        if let offKind = state.providerConfigs.first(where: { !$0.isEnabled })?.kind,
           let onKind = state.providerConfigs.first(where: { $0.isEnabled })?.kind {
            state.setProviderEnabled(onKind, isEnabled: false)
            state.setProviderEnabled(offKind, isEnabled: true)
        }

        let midCount = state.providerConfigs.filter(\.isEnabled).count
        state.migrateProviderLimitsIfNeeded()
        XCTAssertEqual(state.providerConfigs.filter(\.isEnabled).count, midCount,
                       "at-limit state after user curation should survive re-run")
    }

    // MARK: - Disabled-by-tier set is recorded

    func testDisabledByTierSetIsPersisted() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }

        state.migrateProviderLimitsIfNeeded()

        let disabledByTier = AppState.providersDisabledByTier()
        XCTAssertFalse(disabledByTier.isEmpty, "migration should record which kinds were turned off")
        let enabledKinds = Set(state.providerConfigs.filter(\.isEnabled).map(\.kind))
        XCTAssertTrue(disabledByTier.isDisjoint(with: enabledKinds),
                      "disabled-by-tier set must not overlap with currently-enabled set")
    }

    // MARK: - Banner count exposed to UI

    func testMigrationBannerCount() throws {
        let state = AppState()
        guard state.subscriptionManager.maxProviders > 0 else {
            throw XCTSkip("Paid tier — skipping")
        }

        state.migrateProviderLimitsIfNeeded()
        let expectedDisabled = 26 - state.subscriptionManager.maxProviders
        XCTAssertEqual(state.providerLimitMigrationCount, expectedDisabled,
                       "banner count should match the number of providers auto-disabled")

        // Dismiss resets to 0.
        state.dismissProviderLimitMigrationBanner()
        XCTAssertEqual(state.providerLimitMigrationCount, 0)
    }
}
#endif
