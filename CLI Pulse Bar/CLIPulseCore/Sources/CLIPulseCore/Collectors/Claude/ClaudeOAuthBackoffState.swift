#if os(macOS)
import Foundation
import CryptoKit

/// Shared backoff state for `ClaudeOAuthStrategy`.
///
/// Why this exists:
/// the Anthropic OAuth `/api/oauth/usage` endpoint enforces a per-token
/// rate budget that two callers on the same Mac can blow through:
///
///   1. The Mac app (`ClaudeOAuthStrategy`) on every refresh cycle.
///   2. The Python helper (`system_collector._fetch_claude_oauth_api`)
///      on every helper daemon cycle.
///
/// Once a token hits 429, Anthropic typically holds the cooldown for
/// minutes — often longer if we keep knocking. iter-1 of the strategy
/// chain treated 429 as "fall through to the next strategy" but had
/// no memory: every refresh blindly retried OAuth, ate another 429,
/// and fell through. Net: one wasted (and rate-limit-extending)
/// network call per cycle, plus log noise.
///
/// This actor records per-token-fingerprint backoff timestamps and
/// answers "should I skip OAuth right now?". The strategy checks at
/// the top of `fetch()` and short-circuits with
/// `ClaudeStrategyError.rateLimitBackoff(remaining:)` (which
/// `shouldFallback == true`) so the resolver continues straight to
/// the web fallback.
///
/// Design choices:
///
///   * **In-memory only.** App restart resets state; the user might
///     hit 429 once after relaunch, but web fallback still serves
///     data and the new backoff window starts cleanly. Persisting
///     across launches would buy little and complicate the test
///     surface.
///
///   * **Token-fingerprint keyed.** SHA256 prefix (16 hex chars)
///     of the raw token, never the token itself. Sign-out + sign-in
///     with a fresh token automatically gets fresh OAuth budget
///     because the new fingerprint isn't in the dict.
///
///   * **Actor-isolated.** `fetch()` is `async`, an actor is the
///     idiomatic concurrency-safe primitive. Multiple concurrent
///     refreshes serialise on the actor's executor.
///
///   * **Default 15 min window.** Conservative — Anthropic's per-token
///     `/usage` rate budget isn't published, but 15 min covers the
///     observed sticky-429 behaviour without making the user wait
///     too long when the cooldown clears.
///
///   * **Explicit reset on success.** When OAuth succeeds (transient
///     429 has cleared), drop the entry immediately rather than
///     waiting for natural expiry. Keeps state small and the next
///     observation reflects the live state, not a stale ghost.
public actor ClaudeOAuthBackoffState {

    /// Process-wide singleton used by `ClaudeOAuthStrategy` in
    /// production. Tests construct their own instance with an
    /// injected clock.
    public static let shared = ClaudeOAuthBackoffState()

    /// 15-minute default cooldown window. Made tunable via init for
    /// tests; production callers use `.shared` which uses the default.
    public static let defaultWindow: TimeInterval = 15 * 60

    /// fingerprint → expiry timestamp. Entry removed on read after
    /// expiry, on explicit `reset(...)`, or on `recordFailure(...)`
    /// for a different fingerprint (we don't track multiple tokens
    /// in flight today; if that ever changes the dict is ready).
    private var entries: [String: Date] = [:]

    private let window: TimeInterval
    private let clock: @Sendable () -> Date

    public init(
        window: TimeInterval = ClaudeOAuthBackoffState.defaultWindow,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.window = window
        self.clock = clock
    }

    /// Compute a 16-char hex fingerprint of `token`. Safe to log
    /// (it's a one-way hash) but production code does NOT log it —
    /// principle of minimum disclosure.
    public static func fingerprint(forToken token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    /// Record that the given token just got a 429. Subsequent
    /// `remainingBackoff(forFingerprint:)` calls within `window`
    /// will return a positive interval until the entry expires.
    public func recordFailure(forFingerprint fingerprint: String) {
        entries[fingerprint] = clock().addingTimeInterval(window)
    }

    /// Returns `nil` if no backoff is active for `fingerprint`,
    /// otherwise the seconds remaining until the entry expires.
    /// Side effect: lazily evicts entries that have already
    /// expired so the dict doesn't grow unboundedly across token
    /// rotations.
    public func remainingBackoff(forFingerprint fingerprint: String) -> TimeInterval? {
        guard let expiry = entries[fingerprint] else { return nil }
        let now = clock()
        if now >= expiry {
            entries.removeValue(forKey: fingerprint)
            return nil
        }
        return expiry.timeIntervalSince(now)
    }

    /// Explicitly clear backoff for a fingerprint — called on a
    /// successful OAuth response so a cleared 429 is reflected
    /// immediately rather than waiting for the 15-min window.
    public func reset(forFingerprint fingerprint: String) {
        entries.removeValue(forKey: fingerprint)
    }

    /// Test-only: clear all entries. Production code never calls
    /// this; the singleton is process-lifetime.
    public func _resetAllForTesting() {
        entries.removeAll()
    }
}
#endif
