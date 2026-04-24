import Foundation

/// Result of parsing a callback URL returned by Supabase after a Google/GitHub
/// OAuth round-trip. Supabase puts the response on either query items or the
/// URL fragment, and — when the user cancels at the provider consent screen —
/// sends `error=access_denied` instead of a `code`.
public enum OAuthCallbackResult: Equatable {
    /// Happy path: exchange `code` for a session (after verifying `state`).
    case success(code: String, state: String)
    /// User cancelled at the provider. Show a friendly "Sign-in cancelled" toast.
    case cancelled
    /// Any other provider / Supabase error. `description` is the best available
    /// human-ish detail we have; callers should prefix with "OAuth sign-in failed:".
    case failed(description: String)
}

public enum OAuthCallbackParser {
    /// Parse a callback URL (as received by `ASWebAuthenticationSession` on iOS,
    /// or the deep-link intent on Android) into an `OAuthCallbackResult`.
    ///
    /// Supabase returns params on query items (`?code=...`) OR on the URL
    /// fragment (`#code=...`), never both in the same response. Pick one
    /// source per callback so we can't synthesize a success by combining a
    /// `code` from the query with a `state` from the fragment.
    public static func parse(url: URL) -> OAuthCallbackResult {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        var fragmentItems: [URLQueryItem] = []
        if let fragment = components?.fragment {
            var fragComponents = URLComponents()
            fragComponents.query = fragment
            fragmentItems = fragComponents.queryItems ?? []
        }

        // If the query carries any recognized OAuth param, use the query as
        // the authoritative source; otherwise fall back to the fragment.
        // This mirrors the OAuth 2.0 guidance that a single response is
        // encoded in exactly one of the two, never mixed.
        let recognized: Set<String> = ["code", "state", "error", "error_description"]
        let usesQuery = queryItems.contains { recognized.contains($0.name) }
        let items = usesQuery ? queryItems : fragmentItems

        func read(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        let errorKind = read("error")
        let errorDesc = read("error_description") ?? errorKind

        // Prioritise a user-cancel signal over everything else.
        if errorKind == "access_denied" {
            return .cancelled
        }
        // Any other explicit error short-circuits — don't attempt to treat a
        // `code` as success when the provider told us it failed.
        if let errorKind, !errorKind.isEmpty {
            return .failed(description: errorDesc ?? errorKind)
        }

        let code = read("code")
        let state = read("state")
        if let code, let state {
            return .success(code: code, state: state)
        }
        // Never echo the raw callback URL or the authorization code back into
        // a user-facing error — an OAuth code is short-lived but still
        // sensitive, and the URL may also contain PII.
        if code != nil, state == nil {
            return .failed(description: "state missing")
        }
        if code == nil, state != nil {
            return .failed(description: "code missing")
        }
        return .failed(description: "no OAuth parameters in callback")
    }
}
