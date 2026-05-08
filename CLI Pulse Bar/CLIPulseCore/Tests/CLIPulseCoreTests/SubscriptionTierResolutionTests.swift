import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// PR #18 follow-up — pin the tier-resolution / banner-gate fix.
///
/// Background: a CLI Pulse Pro-entitled account was seeing the
/// `Over free plan limits — Devices: 4/1` banner at the top of the
/// popover after sign-in. Root cause was a singleton
/// `SubscriptionManager.shared` init race + active sign-in paths
/// that didn't `await subscriptionManager.updateCurrentEntitlements()`
/// before kicking off `refreshAll()`. The fix lives in three places:
///   1. `SubscriptionManager.tierResolutionState` — distinguishes
///      "haven't checked yet" / "confirmed" / "degraded".
///   2. `DataRefreshManager.tierLimitWarning(...)` — only surfaces
///      banner copy when state == `.resolvedConfirmed`.
///   3. `AppState.completeAuthenticatedSignIn(...)` — every sign-in
///      path awaits the entitlement refresh before refreshAll().
///
/// These tests pin each leg.
final class SubscriptionTierResolutionTests: XCTestCase {

    // MARK: - tierLimitWarning gate (the noisy banner)

    /// Pre-fix this would have returned the (incorrect) free-plan
    /// banner. The gate is the load-bearing part — without it the
    /// `.unresolved` state on cold launch produces the same false
    /// positive as the original bug.
    func testTierLimitWarningSuppressedWhenUnresolved() {
        let warning = DataRefreshManager.tierLimitWarning(
            deviceCount: 4,
            activeProviderCount: 0,
            maxDevices: 1,
            maxProviders: 3,
            currentTierName: "Free",
            tierResolutionState: .unresolved
        )
        XCTAssertNil(warning, "unresolved tier MUST suppress the limit banner")
    }

    /// Same for the degraded path — server / receipt validator
    /// failed, so we can't confidently claim the user is over the
    /// free-plan limit.
    func testTierLimitWarningSuppressedWhenDegraded() {
        let warning = DataRefreshManager.tierLimitWarning(
            deviceCount: 4,
            activeProviderCount: 0,
            maxDevices: 1,
            maxProviders: 3,
            currentTierName: "Free",
            tierResolutionState: .resolvedDegraded
        )
        XCTAssertNil(warning, "degraded tier MUST suppress the limit banner")
    }

    /// Confirmed-free with 4 devices vs maxDevices=1 → banner fires
    /// AND the copy explicitly mentions "CLI Pulse Free" so it's
    /// not confused with a Claude/Codex Pro provider banner.
    func testTierLimitWarningFiresForConfirmedFreeWithCliPulsePrefix() {
        let warning = DataRefreshManager.tierLimitWarning(
            deviceCount: 4,
            activeProviderCount: 0,
            maxDevices: 1,
            maxProviders: 3,
            currentTierName: "Free",
            tierResolutionState: .resolvedConfirmed
        )
        XCTAssertNotNil(warning)
        XCTAssertTrue(warning?.contains("CLI Pulse Free plan limits") ?? false,
                      "banner copy must mention the CLI Pulse plan, not just 'free plan': \(String(describing: warning))")
        XCTAssertTrue(warning?.contains("Devices: 4/1") ?? false)
    }

    /// Confirmed Pro with 4 devices and maxDevices=5 → no banner.
    /// Pin the bug surface that motivated the PR — a CLI Pulse Pro
    /// account at 4/5 devices was being told it was over the free
    /// plan limit because the upstream tier resolution hadn't
    /// finished by the time the warning was computed.
    func testTierLimitWarningNoBannerForProTierUnderLimit() {
        let warning = DataRefreshManager.tierLimitWarning(
            deviceCount: 4,
            activeProviderCount: 0,
            maxDevices: 5,
            maxProviders: -1,
            currentTierName: "Pro",
            tierResolutionState: .resolvedConfirmed
        )
        XCTAssertNil(warning, "Pro account at 4/5 devices must not produce a limit warning")
    }

    /// Confirmed Team with -1 caps → no banner regardless of count.
    func testTierLimitWarningNoBannerForTeamTier() {
        let warning = DataRefreshManager.tierLimitWarning(
            deviceCount: 99,
            activeProviderCount: 99,
            maxDevices: -1,
            maxProviders: -1,
            currentTierName: "Team",
            tierResolutionState: .resolvedConfirmed
        )
        XCTAssertNil(warning)
    }

    // MARK: - SubscriptionManager.updateCurrentEntitlements lifecycle

    /// A freshly-constructed SubscriptionManager has not run
    /// updateCurrentEntitlements to completion yet. Banner gate
    /// reads `.unresolved` so the popover can't accidentally
    /// surface the free-plan banner during cold launch.
    @MainActor
    func testInitialResolutionStateIsUnresolved() {
        let mgr = SubscriptionManager()
        XCTAssertEqual(mgr.tierResolutionState, .unresolved,
                       "default state must be .unresolved so the banner is suppressed until the first refresh completes")
        XCTAssertNil(mgr.lastTierRefreshError)
        XCTAssertNil(mgr.lastTierRefreshSource)
    }

    /// `updateCurrentEntitlements()` with `apiClient == nil`
    /// (singleton init race the bug surface depends on) must NOT
    /// stamp `.resolvedConfirmed`. It records `.resolvedDegraded`
    /// + `.noApiClient` so the diagnostic surface can show the
    /// race + the banner gate suppresses.
    @MainActor
    func testUpdateEntitlementsWithoutApiClientRecordsNoApiClient() async {
        let mgr = SubscriptionManager()
        // No apiClient assignment — simulates the race.
        await mgr.updateCurrentEntitlements()
        XCTAssertEqual(mgr.tierResolutionState, .resolvedDegraded,
                       "missing apiClient must NOT silently produce confirmed-free")
        XCTAssertEqual(mgr.lastTierRefreshError, .noApiClient)
        XCTAssertEqual(mgr.lastTierRefreshSource, "local-only-fallback")
    }

    // MARK: - Diagnostic field semantics

    /// `TierRefreshErrorCategory` rawValues are the exact strings
    /// the SubscriptionSection diagnostic surface displays. Pin
    /// them so a refactor doesn't silently change what the user
    /// sees ("server-tier-error" → "serverTierError" or whatever).
    func testTierRefreshErrorCategoryRawValuesStable() {
        XCTAssertEqual(TierRefreshErrorCategory.noApiClient.rawValue, "no-api-client")
        XCTAssertEqual(TierRefreshErrorCategory.receiptValidatorError.rawValue, "receipt-validator-error")
        XCTAssertEqual(TierRefreshErrorCategory.receiptValidatorRejected.rawValue, "receipt-validator-rejected")
        XCTAssertEqual(TierRefreshErrorCategory.serverTierError.rawValue, "server-tier-error")
    }

    // MARK: - v1.14 Pro Lifetime IAP

    /// Lifetime product ID is exposed and the all-products set includes it.
    /// Pin the constants so an ASC-side rename doesn't silently drop the
    /// product from `Product.products(for:)`.
    func testLifetimeProductIDIsRegistered() {
        XCTAssertEqual(SubscriptionManager.proLifetimeID, "com.clipulse.pro.lifetime")
    }

    /// `isLifetime` defaults to false and the property is readable. Pinned
    /// because the paywall surfaces gate the Lifetime tile on this exact
    /// signal — an accidental rename to `hasLifetime` would silently
    /// re-show the tile to users who already own it.
    @MainActor
    func testIsLifetimeDefaultsToFalse() {
        let mgr = SubscriptionManager()
        XCTAssertFalse(mgr.isLifetime, "fresh manager must report isLifetime = false")
    }

    /// `proLifetime` accessor returns nil when products haven't loaded.
    /// (Verifying the accessor exists at all is the load-bearing part —
    /// `manager.proLifetime` is referenced by SubscriptionView, the iOS
    /// SettingsTab paywall, and SubscriptionSection's inline IAP cards.)
    @MainActor
    func testProLifetimeAccessorIsNilBeforeProductsLoad() {
        let mgr = SubscriptionManager()
        XCTAssertNil(mgr.proLifetime, "proLifetime must be nil until ASC products list arrives")
    }
}

#endif
