import Foundation

/// Classification of account-deletion failures, extracted so the decision
/// logic can be unit-tested without instantiating `AppState` or building
/// a mock `APIClient` (the actor takes a private `URLSession` and isn't
/// trivially injectable).
///
/// The `AppState.deleteAccount` catch branch routes on this enum:
///   - `.sessionExpired`: the eager pre-RPC `refreshAccessToken` failed
///     (or any downstream call surfaced `APIError.tokenExpired`). At
///     this point `APIClient.accessToken` and `refreshToken` are both
///     `nil` — the client side has acknowledged the session is dead, so
///     the UI must reconcile by signing out. Otherwise the app shows a
///     "you're signed in" UI while the API client has no auth, and
///     every subsequent call fails silently or throws 401.
///   - `.other(message)`: the server actively refused the delete (HTTP
///     4xx, RLS violation, FK conflict, network blip). The session is
///     intact (or recoverable on next refresh). Show the error in
///     place; the user can retry without re-authenticating.
///
/// iter11 hotfix (2026-04-29): added to fix the half-broken state
/// where iter10's `try?` on `refreshAccessToken` swallowed token
/// expiry, leaving the user signed in in the UI but tokenless in the
/// API client.
public enum DeleteAccountFailure: Equatable {
    case sessionExpired
    case other(message: String)

    /// Classify any error thrown out of `AuthManager.deleteAccount` /
    /// `APIClient.deleteAccount`.
    public static func classify(_ error: Error) -> DeleteAccountFailure {
        if let apiError = error as? APIError, apiError == .tokenExpired {
            return .sessionExpired
        }
        return .other(message: error.localizedDescription)
    }
}
