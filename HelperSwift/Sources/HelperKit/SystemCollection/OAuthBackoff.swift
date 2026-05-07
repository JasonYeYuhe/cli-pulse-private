import Foundation
import CryptoKit

/// Per-token OAuth 429 backoff state. After Anthropic's OAuth usage
/// API returns 429 for a given access token, the helper suppresses
/// further OAuth API calls for that token's fingerprint for 15 minutes,
/// falling through to the web-cookie / CLI paths instead. This avoids
/// hammering an already rate-limited account and matches the macOS
/// app's `ClaudeOAuthBackoffState` actor.
///
/// Phase 4E v2 P1 — Gemini decision: actor-isolated single-writer
/// semantics. Two concurrent `register` calls for the same fingerprint
/// produce one entry; the second call no-ops if a backoff is already
/// active. This is the deliberate departure from Python's
/// `_OAUTH_BACKOFF` module-level dict ("racy but benign" — last-write-
/// wins), since there's no value in preserving a known race for parity's
/// sake.
public actor OAuthBackoff {

    public static let windowSeconds: TimeInterval = 15 * 60

    /// Test hook for the clock. Default: real wall-clock seconds since 1970.
    public typealias Clock = @Sendable () -> TimeInterval

    private let clock: Clock
    private var expiryByFingerprint: [String: TimeInterval] = [:]

    public init(clock: @escaping Clock = { Date().timeIntervalSince1970 }) {
        self.clock = clock
    }

    /// Compute the 16-char hex prefix of `SHA256(token)`. Safe to log
    /// (one-way hash) but the production helper does NOT log it
    /// (principle of minimum disclosure). Mirrors Python
    /// `_oauth_token_fingerprint`.
    public static func fingerprint(forToken token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Mark `fingerprint` as in-cooldown. **Actor-isolated single-writer**:
    /// if the fingerprint already has an active (non-expired) entry, the
    /// existing expiry is preserved and this call is a no-op. The first
    /// register-after-expiry resets the 15-minute window.
    public func register(_ fingerprint: String) {
        if let existing = expiryByFingerprint[fingerprint], clock() < existing {
            return  // already in cooldown — preserve original window
        }
        expiryByFingerprint[fingerprint] = clock() + Self.windowSeconds
    }

    /// Returns `nil` when no backoff is active for `fingerprint`,
    /// otherwise the seconds remaining until the entry expires. Lazily
    /// evicts expired entries.
    public func remaining(_ fingerprint: String) -> TimeInterval? {
        guard let expiry = expiryByFingerprint[fingerprint] else { return nil }
        let now = clock()
        if now >= expiry {
            expiryByFingerprint.removeValue(forKey: fingerprint)
            return nil
        }
        return expiry - now
    }

    /// Drop the entry for `fingerprint`. Called on a successful OAuth
    /// response so a transient 429 that clears doesn't get stuck in
    /// suppression.
    public func reset(_ fingerprint: String) {
        expiryByFingerprint.removeValue(forKey: fingerprint)
    }

    /// Test-only: drop all entries.
    public func resetAllForTesting() {
        expiryByFingerprint.removeAll()
    }
}
