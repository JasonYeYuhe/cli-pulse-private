import Foundation

/// Decision tree for `DataRefreshManager.refreshAll`. Extracted as a
/// pure helper so the routing logic — which now spans authenticated +
/// unauthenticated × paired/unpaired/local-mode × macOS/iOS — can be
/// unit-tested without spinning up a real APIClient or collector.
///
/// iter17 (2026-04-29): added the `localOnly` route for unauthenticated
/// macOS users who explicitly opted into local mode via
/// `AppState.continueWithoutAccount()`. Pre-iter17, `refreshAll` had
/// `guard context.isAuthenticated, !context.isDemoMode else { return }`
/// at the very top, so the local-mode flag was meaningful only for
/// signed-in unpaired Mac users (a flow that's now rare post-iter9).
public enum RefreshRoute: Equatable {
    /// Don't refresh anything (demo mode, or signed out without local mode).
    case noOp
    /// macOS local scanner only — no Supabase calls. Used for both
    /// signed-in unpaired Mac users and (iter17) unauthenticated
    /// `isLocalMode` Mac users.
    case localOnly
    /// Full cloud refresh — health check, dashboard / providers / etc.
    /// Plus, on macOS, supplements with local scanner results.
    case cloud
}

public enum RefreshRouter {
    /// Pure decision: given the user's auth + tier flags + platform,
    /// what kind of refresh should `refreshAll` execute?
    ///
    /// Rules (in order of evaluation):
    ///   1. Demo mode → `.noOp` (demo data is static).
    ///   2. Authenticated:
    ///        - macOS && !isPaired → `.localOnly` (Mac menu-bar app
    ///          uploads to cloud, but renders local-merged dashboard
    ///          while waiting for first cloud round-trip).
    ///        - else → `.cloud`.
    ///   3. Unauthenticated:
    ///        - macOS && isLocalMode → `.localOnly` (iter17 user-opted
    ///          local-only mode).
    ///        - else → `.noOp` (iOS / Watch can't scan locally; signed
    ///          out non-local-mode Mac has nothing to do).
    public static func decide(
        isAuthenticated: Bool,
        isDemoMode: Bool,
        isPaired: Bool,
        isLocalMode: Bool,
        isMacOS: Bool
    ) -> RefreshRoute {
        if isDemoMode { return .noOp }

        if isAuthenticated {
            if isMacOS && !isPaired { return .localOnly }
            return .cloud
        }

        // Unauthenticated.
        if isMacOS && isLocalMode { return .localOnly }
        return .noOp
    }
}
