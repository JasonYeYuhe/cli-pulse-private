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

    private static let allProductIDs: Set<String> = [
        proMonthlyID, proYearlyID, teamMonthlyID, teamYearlyID
    ]

    @Published public var currentTier: SubscriptionTier = .free
    @Published public var products: [Product] = []
    @Published public var purchasedSubscriptions: [StoreKit.Transaction] = []
    @Published public var isLoading = false

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
        case .free: return 1
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

    public func updateCurrentEntitlements() async {
        var activeSubs: [StoreKit.Transaction] = []
        var highestTier: SubscriptionTier = .free
        var highestJWS: String?
        var highestProductID: String?

        for await result in StoreKit.Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result) else { continue }

            if transaction.productType == .autoRenewable {
                activeSubs.append(transaction)

                let txTier: SubscriptionTier
                if transaction.productID == Self.teamMonthlyID ||
                   transaction.productID == Self.teamYearlyID {
                    txTier = .team
                } else if transaction.productID == Self.proMonthlyID ||
                          transaction.productID == Self.proYearlyID {
                    txTier = .pro
                } else {
                    txTier = .free
                }

                if txTier.tierRank > highestTier.tierRank {
                    highestTier = txTier
                    highestJWS = result.jwsRepresentation
                    highestProductID = transaction.productID
                }
            }
        }

        purchasedSubscriptions = activeSubs

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
            if result.verified {
                let serverTier = SubscriptionTier(rawValue: result.tier) ?? .free
                currentTier = serverTier
                tierResolutionState = .resolvedConfirmed
                lastTierRefreshSource = "store-jws-server-verified"
                lastTierRefreshError = nil
                return
            }
            // Server reachable but said "not verified", OR a transport
            // error happened. Either way we don't want to slap a
            // confirmed-free on the user. Keep the local highestTier
            // (so Pro features still light up if the StoreKit
            // entitlement is real), but mark degraded.
            currentTier = highestTier
            tierResolutionState = .resolvedDegraded
            lastTierRefreshSource = "local-only-fallback"
            lastTierRefreshError = (result.error != nil)
                ? .receiptValidatorError
                : .receiptValidatorRejected
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
