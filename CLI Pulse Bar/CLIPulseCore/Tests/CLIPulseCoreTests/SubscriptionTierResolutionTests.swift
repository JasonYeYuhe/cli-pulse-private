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

    // MARK: - Codex P1 (PR #41) — Lifetime tie-break in updateCurrentEntitlements

    /// Pro auto-renewable seen first, then Lifetime: Lifetime must win the
    /// tie so its JWS goes to validate-receipt and the server persists
    /// `current_period_end = NULL`. This pins the bug Codex caught.
    func testShouldPromote_LifetimeBeatsRenewableProOnTie() {
        // Iteration 1: highest=.free, encounter Pro auto-renewable.
        XCTAssertTrue(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: false,
                currentTier: .free, currentIsLifetime: false
            ),
            "Pro must promote over Free"
        )
        // Iteration 2: highest=.pro (auto-renewable), encounter Lifetime.
        XCTAssertTrue(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: true,
                currentTier: .pro, currentIsLifetime: false
            ),
            "Lifetime must beat Pro auto-renewable on a Pro-rank tie"
        )
    }

    /// Lifetime seen first, then Pro auto-renewable: Lifetime must STAY
    /// (don't trade two Pro-rank transactions where neither is Lifetime,
    /// and don't displace Lifetime with a renewable on the same rank).
    func testShouldPromote_LifetimeStaysWhenSeenFirst() {
        // Iteration 1: highest=.free, encounter Lifetime.
        XCTAssertTrue(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: true,
                currentTier: .free, currentIsLifetime: false
            ),
            "Lifetime must promote over Free"
        )
        // Iteration 2: highest=Lifetime, encounter Pro auto-renewable.
        XCTAssertFalse(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: false,
                currentTier: .pro, currentIsLifetime: true
            ),
            "Pro auto-renewable must NOT replace an already-elected Lifetime"
        )
    }

    /// Team always outranks both Pro variants, regardless of order.
    func testShouldPromote_TeamOutranksLifetimeAndPro() {
        // Team replaces Lifetime.
        XCTAssertTrue(
            SubscriptionManager.shouldPromote(
                newTier: .team, newIsLifetime: false,
                currentTier: .pro, currentIsLifetime: true
            ),
            "Team must outrank Lifetime (rank 2 > rank 1)"
        )
        // Lifetime does NOT replace Team.
        XCTAssertFalse(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: true,
                currentTier: .team, currentIsLifetime: false
            ),
            "Lifetime must NOT outrank Team"
        )
    }

    /// Two non-Lifetime Pro-rank transactions never swap. Pre-v1.14 had
    /// a single Pro auto-renewable; this pins the no-behavior-change case.
    func testShouldPromote_NoSwapBetweenTwoNonLifetimeProTransactions() {
        XCTAssertFalse(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: false,
                currentTier: .pro, currentIsLifetime: false
            ),
            "Two non-Lifetime Pro transactions must not trade — pre-v1.14 behavior preserved"
        )
    }

    /// Lower-rank transactions never promote. (Free can't replace Pro,
    /// Pro can't replace Team.)
    func testShouldPromote_LowerRankNeverPromotes() {
        XCTAssertFalse(
            SubscriptionManager.shouldPromote(
                newTier: .free, newIsLifetime: false,
                currentTier: .pro, currentIsLifetime: false
            )
        )
        XCTAssertFalse(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: false,
                currentTier: .team, currentIsLifetime: false
            )
        )
        XCTAssertFalse(
            SubscriptionManager.shouldPromote(
                newTier: .pro, newIsLifetime: true,
                currentTier: .team, currentIsLifetime: false
            ),
            "Even Lifetime must not displace Team — Team rank is strictly higher"
        )
    }

    // MARK: - NEW-M9: server-authoritative reject must downgrade (not keep Pro)

    func testReceiptResolution_verified_confirmsServerTier() {
        let r = SubscriptionManager.resolveJWSReceipt(
            .init(verified: true, tier: "team", error: nil),
            localHighestTier: .pro
        )
        XCTAssertEqual(r.tier, .team)
        XCTAssertEqual(r.state, .resolvedConfirmed)
        XCTAssertEqual(r.source, "store-jws-server-verified")
    }

    func testReceiptResolution_authoritativeReject_downgradesToConfirmed() {
        // 2xx + verified:false + error:nil = server says "not entitled" (refund/
        // revoke/sandbox). A local StoreKit .pro must NOT survive it.
        let r = SubscriptionManager.resolveJWSReceipt(
            .init(verified: false, tier: "free", error: nil),
            localHighestTier: .pro
        )
        XCTAssertEqual(r.tier, .free, "authoritative reject must downgrade, not keep local Pro")
        XCTAssertEqual(r.state, .resolvedConfirmed, "an authoritative answer is CONFIRMED, not degraded")
        XCTAssertEqual(r.source, "store-jws-server-rejected")
        XCTAssertEqual(r.error, .receiptValidatorRejected)
    }

    func testReceiptResolution_transportError_keepsLocalTierDegraded() {
        // A network/decode failure is NOT authoritative — keep the local
        // StoreKit entitlement but mark degraded.
        let r = SubscriptionManager.resolveJWSReceipt(
            .init(verified: false, tier: "free", error: .receiptValidatorError),
            localHighestTier: .pro
        )
        XCTAssertEqual(r.tier, .pro, "transient error must keep the local StoreKit tier")
        XCTAssertEqual(r.state, .resolvedDegraded)
        XCTAssertEqual(r.source, "local-only-fallback")
        XCTAssertEqual(r.error, .receiptValidatorError)
    }

    // MARK: - NEW-M10: sign-out drops the server-granted tier

    @MainActor
    func testResetForSignOut_immediatelyDropsServerGrantedTier() {
        let mgr = SubscriptionManager()
        mgr.currentTier = .team
        mgr.isLifetime = true
        mgr.tierResolutionState = .resolvedConfirmed
        mgr.resetForSignOut()
        // Synchronous reset (the async StoreKit re-resolve can't interleave
        // before this @MainActor method returns).
        XCTAssertEqual(mgr.currentTier, .free, "sign-out must immediately drop the server-granted tier")
        XCTAssertFalse(mgr.isLifetime)
        XCTAssertEqual(mgr.tierResolutionState, .unresolved)
    }
}

#endif
