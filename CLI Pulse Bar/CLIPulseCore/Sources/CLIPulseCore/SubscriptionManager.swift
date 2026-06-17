import Foundation
import StoreKit
import SwiftUI

public enum SubscriptionTier: String, Codable, Sendable {
    case free = "free"
    case pro = "pro"
    case team = "team"

    var tierRank: Int {
        switch self {
        case .free: return 0
        case .pro: return 1
        case .team: return 2
        }
    }
}

/// PR #18 follow-up — distinguishes "tier defaulted to free because we
/// haven't checked yet" from "tier was checked and confirmed free" from
/// "we tried to check but the receipt validator / server tier RPC
/// failed."
///
/// Why it matters: the previous code raced — `SubscriptionManager.shared`
/// kicks off `Task { await updateCurrentEntitlements() }` from `init`,
/// which in turn calls `apiClient.validateReceipt` / `apiClient.serverTier`.
/// `apiClient` is set later via `AppState.init`, so the singleton's
/// first-tick task can run with `apiClient == nil`, fall through both
/// the JWS-validation path and the server-tier fallback, and silently
/// stamp `currentTier = .free` against the StoreKit-only fallback. If
/// the local StoreKit sandbox doesn't surface a Pro entitlement (debug
/// build, fresh sandbox account, sandbox sync glitch), Pro users see
/// the free-plan banner.
///
/// The fix has three legs:
///   1. The active sign-in paths await `updateCurrentEntitlements()`
///      BEFORE `refreshAll()` so the warning eval uses the real tier.
///   2. The banner suppresses itself when this state is anything but
///      `.resolvedConfirmed` — receipt-verified or server-confirmed.
///   3. Settings exposes the resolution state + last error category as
///      a subtle diagnostic line so future debugging doesn't need
///      verbose Xcode logs.
public enum TierResolutionState: String, Sendable, Equatable, Codable {
    /// Default. `updateCurrentEntitlements()` has not finished yet, so
    /// we don't actually know the user's tier. The banner gate uses
    /// this to suppress noise during cold launch.
    case unresolved
    /// `updateCurrentEntitlements()` completed AND a verified-or-
    /// server-confirmed source produced the current tier. Safe to
    /// surface plan-limit warnings.
    case resolvedConfirmed
    /// `updateCurrentEntitlements()` ran but every authoritative
    /// path failed — receipt validator returned a network/decode
    /// error, server-tier RPC failed, or apiClient was nil at the
    /// time of the call. We may still have a StoreKit local fallback
    /// tier, but it isn't trustworthy enough to back a UI claim like
    /// "Over free plan limits." Banner suppressed; Settings shows
    /// the diagnostic.
    case resolvedDegraded
}

/// Categorised reason for the most recent tier-refresh attempt. Only
/// non-nil when `tierResolutionState == .resolvedDegraded`. Strings
/// are short, internally-known categories — never error messages
/// from the network layer (which can leak URLs / HTTP body).
public enum TierRefreshErrorCategory: String, Sendable, Equatable, Codable {
    case noApiClient = "no-api-client"
    case receiptValidatorError = "receipt-validator-error"
    case receiptValidatorRejected = "receipt-validator-rejected"
    case serverTierError = "server-tier-error"
}

@MainActor
public final class SubscriptionManager: ObservableObject {
    public static let shared = SubscriptionManager()

    // Product IDs (must match App Store Connect)
    public static let proMonthlyID = "com.clipulse.pro.monthly"
    public static let proYearlyID = "com.clipulse.pro.yearly"
    public static let teamMonthlyID = "com.clipulse.team.monthly"
    public static let teamYearlyID = "com.clipulse.team.yearly"
    /// v1.14: Pro Lifetime — Non-Consumable IAP, pro tier, never expires.
    /// ASC: com.clipulse.pro.lifetime / Apple ID 6767441323 / ¥128 CNY base.
    public static let proLifetimeID = "com.clipulse.pro.lifetime"

    private static let allProductIDs: Set<String> = [
        proMonthlyID, proYearlyID, teamMonthlyID, teamYearlyID, proLifetimeID
    ]

    @Published public var currentTier: SubscriptionTier = .free
    @Published public var products: [Product] = []
    @Published public var purchasedSubscriptions: [StoreKit.Transaction] = []
    @Published public var isLoading = false
    /// v1.14: true when the user has redeemed `proLifetimeID` (Non-Consumable
    /// purchase recorded in `Transaction.currentEntitlements`). Drives the
    /// "You own Pro Lifetime" badge in paywall surfaces.
    @Published public var isLifetime: Bool = false

    /// PR #18 follow-up: resolution state + diagnostic fields. See
    /// `TierResolutionState` doc comment for the rationale.
    @Published public var tierResolutionState: TierResolutionState = .unresolved
    /// Short category string describing where `currentTier` came from
    /// on the most recent successful resolution. Stable values:
    ///   `store-jws-server-verified`  — local StoreKit JWS that the
    ///       server-side validate-receipt edge function approved.
    ///   `server-tier`                — admin override / promo /
    ///       profiles.tier path via `get_user_tier` RPC.
    ///   `local-only-fallback`        — StoreKit had a verified
    ///       transaction but the validator round-trip didn't land
    ///       (we still trust the local entitlement enough to show
    ///       Pro features, but mark resolution as degraded).
    @Published public var lastTierRefreshSource: String?
    /// Non-nil only when the most recent refresh failed somewhere
    /// authoritative. See `TierRefreshErrorCategory` doc.
    @Published public var lastTierRefreshError: TierRefreshErrorCategory?

    public var isProOrAbove: Bool { currentTier == .pro || currentTier == .team }
    public var isTeam: Bool { currentTier == .team }

    // Tier limits
    public var maxProviders: Int { currentTier == .free ? 3 : -1 }
    public var maxDevices: Int {
        switch currentTier {
        case .free: return 2
        case .pro: return 5
        case .team: return -1
        }
    }
    public var dataRetentionDays: Int {
        switch currentTier {
        case .free: return 7
        case .pro: return 90
        case .team: return 365
        }
    }

    // Convenience product accessors
    public var proMonthly: Product? { products.first { $0.id == Self.proMonthlyID } }
    public var proYearly: Product? { products.first { $0.id == Self.proYearlyID } }
    public var teamMonthly: Product? { products.first { $0.id == Self.teamMonthlyID } }
    public var teamYearly: Product? { products.first { $0.id == Self.teamYearlyID } }
    public var proLifetime: Product? { products.first { $0.id == Self.proLifetimeID } }

    private var updateListenerTask: Task<Void, Error>?

    public init() {
        updateListenerTask = listenForTransactions()
        Task { await loadProducts() }
        Task { await updateCurrentEntitlements() }
    }

    deinit {
        updateListenerTask?.cancel()
    }

    // MARK: - Load Products

    public func loadProducts() async {
        isLoading = true
        do {
            let storeProducts = try await Product.products(for: Self.allProductIDs)
            products = storeProducts.sorted { $0.price < $1.price }
        } catch {
            // Products not available yet (e.g., not configured in App Store Connect)
            products = []
        }
        isLoading = false
    }

    // MARK: - Purchase

    public func purchase(_ product: Product) async throws -> StoreKit.Transaction? {
        let result = try await product.purchase()

        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await updateCurrentEntitlements()
            await transaction.finish()
            return transaction

        case .userCancelled:
            return nil

        case .pending:
            return nil

        @unknown default:
            return nil
        }
    }

    // MARK: - Restore

    public func restorePurchases() async {
        isLoading = true
        try? await AppStore.sync()
        await updateCurrentEntitlements()
        isLoading = false
    }

    // MARK: - Entitlements

    /// Tie-break for `Transaction.currentEntitlements` selection.
    ///
    /// Returns `true` if a transaction with `(newTier, newIsLifetime)` should
    /// replace the running highest `(currentTier, currentIsLifetime)`.
    ///
    /// Rules:
    /// - Strictly higher rank wins (Team beats both Pro variants).
    /// - On a Pro-rank tie, Lifetime beats auto-renewable Pro. This routes
    ///   the long-term receipt to `validate-receipt`, which persists
    ///   `current_period_end = NULL` server-side. Without this tie-break,
    ///   whichever transaction `Transaction.currentEntitlements` yielded
    ///   first won; Apple does not document a stable order, so a Pro-yearly
    ///   user who later buys Lifetime could end up with the server still
    ///   holding the yearly's expiry timestamp.
    /// - Two non-Lifetime equals never trade places (no behavior change for
    ///   pre-v1.14 entitlement combinations).
    nonisolated static func shouldPromote(
        newTier: SubscriptionTier,
        newIsLifetime: Bool,
        currentTier: SubscriptionTier,
        currentIsLifetime: Bool
    ) -> Bool {
        if newTier.tierRank > currentTier.tierRank { return true }
        if newTier.tierRank == currentTier.tierRank
           && newIsLifetime && !currentIsLifetime { return true }
        return false
    }

    /// Pure decision for how a StoreKit-JWS `validate-receipt` result maps to
    /// (tier, resolution-state, source, error). Extracted so NEW-M9 is
    /// unit-testable without a live StoreKit / network round-trip.
    struct ReceiptResolution: Equatable {
        let tier: SubscriptionTier
        let state: TierResolutionState
        let source: String
        let error: TierRefreshErrorCategory?
    }

    nonisolated static func resolveJWSReceipt(
        _ result: APIClient.ValidateReceiptResult,
        localHighestTier: SubscriptionTier
    ) -> ReceiptResolution {
        if result.verified {
            return ReceiptResolution(
                tier: SubscriptionTier(rawValue: result.tier) ?? .free,
                state: .resolvedConfirmed,
                source: "store-jws-server-verified",
                error: nil
            )
        }
        if result.error == nil {
            // NEW-M9: a 2xx response with verified:false is an AUTHORITATIVE
            // reject (refunded / revoked / sandbox / invalid receipt). Trust
            // the server tier and mark CONFIRMED so the entitlement gate stops
            // honoring the stale local StoreKit tier. Previously this kept
            // `highestTier` as degraded, so a refunded user retained Pro/Team.
            return ReceiptResolution(
                tier: SubscriptionTier(rawValue: result.tier) ?? .free,
                state: .resolvedConfirmed,
                source: "store-jws-server-rejected",
                error: .receiptValidatorRejected
            )
        }
        // Transport / decode error — not a confirmed answer. Keep the local
        // StoreKit highest tier (Apple still surfaces the entitlement on-device)
        // but mark degraded so the banner stays silent.
        return ReceiptResolution(
            tier: localHighestTier,
            state: .resolvedDegraded,
            source: "local-only-fallback",
            error: .receiptValidatorError
        )
    }

    struct StoreKitScan {
        var activeSubs: [StoreKit.Transaction] = []
        var highestTier: SubscriptionTier = .free
        var highestJWS: String?
        var highestProductID: String?
        var sawLifetime = false
    }

    /// Scan `Transaction.currentEntitlements` — local, Apple-verified
    /// on-device, **NO network** — and compute the highest device-bound tier.
    /// Shared by `updateCurrentEntitlements` (which then server-confirms) and
    /// `resetForSignOut` (which uses the StoreKit result directly, so it can't
    /// race the sign-out token-clear into re-granting a server tier).
    private func scanStoreKitEntitlements() async -> StoreKitScan {
        var scan = StoreKitScan()
        for await result in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }

            // v1.14: a Lifetime purchase appears once in
            // `currentEntitlements` as a Non-Consumable transaction with no
            // `expirationDate`. Apple keeps it there forever (until refund).
            // We surface it through `isLifetime` for UI and treat it as a
            // .pro tier signal — Team (auto-renewable) still outranks
            // Lifetime if both are active.
            let txTier: SubscriptionTier
            let txIsLifetime: Bool
            switch transaction.productType {
            case .autoRenewable:
                scan.activeSubs.append(transaction)
                if transaction.productID == Self.teamMonthlyID ||
                   transaction.productID == Self.teamYearlyID {
                    txTier = .team
                } else if transaction.productID == Self.proMonthlyID ||
                          transaction.productID == Self.proYearlyID {
                    txTier = .pro
                } else {
                    txTier = .free
                }
                txIsLifetime = false
            case .nonConsumable where transaction.productID == Self.proLifetimeID:
                scan.activeSubs.append(transaction)
                scan.sawLifetime = true
                txTier = .pro
                txIsLifetime = true
            default:
                txTier = .free
                txIsLifetime = false
            }

            // Codex P1 (PR #41 review, 2026-05-08): see `shouldPromote`
            // doc comment for the tie-break rationale.
            let currentHighestIsLifetime = (scan.highestProductID == Self.proLifetimeID)
            if Self.shouldPromote(
                newTier: txTier, newIsLifetime: txIsLifetime,
                currentTier: scan.highestTier, currentIsLifetime: currentHighestIsLifetime
            ) {
                scan.highestTier = txTier
                scan.highestJWS = result.jwsRepresentation
                scan.highestProductID = transaction.productID
            }
        }
        return scan
    }

    public func updateCurrentEntitlements() async {
        // v1.19 SR1: Developer ID Beta channel users have no Mac App
        // Store receipt — StoreKit's currentEntitlements stream is
        // empty for them. Without this short-circuit, the rest of
        // this function would fall through to `.free`, hiding all
        // premium features. The DEVID DMG is positioned as a power-
        // user / dev-community beta tier, so we treat all DEVID
        // installs as Pro Lifetime locally.
        //
        // Server-side endpoints that validate the MAS receipt will
        // still reject DEVID requests until v1.19.1 adds an
        // `X-CLI-Pulse-Channel: beta` allow-list (gated on backend
        // schema-change user authorization per
        // feedback_cli_pulse_autonomy §"When to flag" #1). Cloud-
        // dependent premium features therefore degrade gracefully
        // until that lands.
        #if DEVID_BUILD
        self.currentTier = .pro
        self.isLifetime = true
        self.tierResolutionState = .resolvedConfirmed
        self.lastTierRefreshSource = "devid-beta-channel"
        self.lastTierRefreshError = nil
        return
        #endif

        let scan = await scanStoreKitEntitlements()
        var highestTier = scan.highestTier
        let highestJWS = scan.highestJWS
        let highestProductID = scan.highestProductID
        purchasedSubscriptions = scan.activeSubs
        isLifetime = scan.sawLifetime

        // Path 1: signed StoreKit 2 JWS exists → server-side validate.
        //
        // Outcomes:
        //   verified          → trust the server tier, mark CONFIRMED.
        //   server rejected   → degrade (invalid receipt is a real
        //                       answer, but it's not a `confirmed
        //                       free` either — could be a transient
        //                       store-server hiccup).
        //   network/decode    → degrade with the error category so
        //                       Settings can surface it.
        if let jwsString = highestJWS, !jwsString.isEmpty,
           let productID = highestProductID, let api = apiClient {
            let result = await api.validateReceipt(
                transactionJWS: jwsString,
                productId: productID
            )
            let resolved = Self.resolveJWSReceipt(result, localHighestTier: highestTier)
            currentTier = resolved.tier
            tierResolutionState = resolved.state
            lastTierRefreshSource = resolved.source
            lastTierRefreshError = resolved.error
            return
        }

        // Path 2: no JWS (no local subscription transaction). Fall
        // back to the server-side tier RPC so admin grants / promo
        // redemptions / Team membership still resolve.
        guard let api = apiClient else {
            // Singleton-init race: SubscriptionManager.shared started
            // updateCurrentEntitlements before AppState wired apiClient.
            // We can't authoritatively check tier — keep whatever
            // local StoreKit said (most likely .free) but flag
            // degraded so the banner stays silent.
            currentTier = highestTier
            tierResolutionState = .resolvedDegraded
            lastTierRefreshSource = "local-only-fallback"
            lastTierRefreshError = .noApiClient
            return
        }
        let serverResult = await api.serverTier()
        if let category = serverResult.error {
            // Server reachable failure — not a confirmed `free`.
            currentTier = highestTier   // probably .free anyway
            tierResolutionState = .resolvedDegraded
            lastTierRefreshSource = "server-tier-failed"
            lastTierRefreshError = category
            return
        }
        let serverTier = SubscriptionTier(rawValue: serverResult.tier) ?? .free
        if serverTier.tierRank > highestTier.tierRank {
            highestTier = serverTier
        }
        currentTier = highestTier
        tierResolutionState = .resolvedConfirmed
        lastTierRefreshSource = "server-tier"
        lastTierRefreshError = nil
    }

    /// NEW-M10: on sign-out / entering local mode, drop any SERVER-granted
    /// entitlement (admin grant / promo / Team membership — all account-bound)
    /// immediately, then re-resolve from StoreKit so a device/Apple-ID-bound
    /// local purchase (Pro / Lifetime) survives. Without this, `AuthManager`
    /// cleared every other field but left `currentTier`, so a former .team/.pro
    /// user kept paid gates after signing out into the no-account local mode.
    public func resetForSignOut() {
        currentTier = .free
        isLifetime = false
        purchasedSubscriptions = []
        tierResolutionState = .unresolved
        lastTierRefreshSource = nil
        lastTierRefreshError = nil
        // Re-resolve from StoreKit ONLY (no server call) so a device-bound
        // purchase (Pro / Lifetime) survives while server-granted tiers stay
        // dropped. updateCurrentEntitlements() would RACE the sign-out
        // token-clear: its serverTier()/validate-receipt calls could reach the
        // APIClient actor before sign-out nils the token and re-grant the
        // just-dropped account tier (Codex review of NEW-M10).
        Task { [weak self] in
            guard let self else { return }
            let scan = await self.scanStoreKitEntitlements()
            self.purchasedSubscriptions = scan.activeSubs
            self.isLifetime = scan.sawLifetime
            self.currentTier = scan.highestTier
            // A StoreKit entitlement is Apple-verified on-device; in no-account
            // local mode there's no server to confirm against, so treat it as
            // resolved rather than degraded.
            self.tierResolutionState = .resolvedConfirmed
            self.lastTierRefreshSource = "storekit-local-signout"
            self.lastTierRefreshError = nil
        }
    }

    /// Server-side tier override — set by admin in profiles.tier or
    /// promo redemptions. Wired by `AppState.init` after construction.
    /// Until that wiring lands, `updateCurrentEntitlements()` records
    /// `lastTierRefreshError = .noApiClient` rather than silently
    /// stamping confirmed-free.
    public var apiClient: APIClient?

    // MARK: - Transaction Listener

    private func listenForTransactions() -> Task<Void, Error> {
        Task.detached { [weak self] in
            for await result in StoreKit.Transaction.updates {
                guard let self else { break }
                if let transaction = try? await self.checkVerified(result) {
                    await self.updateCurrentEntitlements()
                    await transaction.finish()
                }
            }
        }
    }

    // MARK: - Verification

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }

    // MARK: - Tier Display Helpers

    public func tierName(for tier: SubscriptionTier) -> String {
        switch tier {
        case .free: return L10n.subscription.free
        case .pro: return L10n.subscription.pro
        case .team: return L10n.subscription.team
        }
    }

    public func tierDescription(for tier: SubscriptionTier) -> String {
        switch tier {
        case .free: return L10n.subscription.freeDescription
        case .pro: return L10n.subscription.proDescription
        case .team: return L10n.subscription.teamDescription
        }
    }
}
