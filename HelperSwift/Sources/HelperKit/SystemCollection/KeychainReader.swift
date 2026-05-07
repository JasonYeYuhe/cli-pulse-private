import Foundation

/// Async wrapper over `security find-generic-password -s <service> -w`
/// for reading credentials from the macOS Keychain. Used by Slice 2c's
/// `ClaudeQuotaFetcher` to load `Claude Code-credentials` (the JSON
/// blob the Claude CLI persists with the OAuth access/refresh tokens
/// + plan info).
///
/// **Phase 4E v2.1 P1 — Chromium Safe Storage prompt resilience.**
/// The first time the new Swift binary signs differently than the
/// Python launcher and tries to read a generic-password item that the
/// Python helper had previously authorized, macOS surfaces a dialog
/// asking the user to "Always Allow" or "Deny". `security
/// find-generic-password` blocks indefinitely waiting for that click.
///
/// Mitigations baked in here:
///
///   1. **5-second watchdog timeout** via `SubprocessRunner`. If the
///      user is AFK, we fall through to the next provenance path
///      (web cookie / CLI legacy) rather than freezing the entire
///      `SystemCollector.collectAll` task group.
///
///   2. **24-hour denial cache** (`KeychainConsentCache`) — when the
///      `security` invocation returns a non-zero exit indicating the
///      user clicked "Deny" (or the watchdog tripped), the service
///      name is marked as denied for 24 h. Subsequent collection
///      cycles within that window skip the Keychain fetch entirely
///      so we don't re-prompt every minute.
///
///   3. **Explicit-refresh override.** When the macOS app's Settings
///      panel calls "Refresh quota" via UDS, the helper passes
///      `forceRetry: true` which clears the denial cache for the
///      requested service before invoking `security`. Gives the user
///      a path to flip their decision without restarting anything.
///
public actor KeychainReader {

    public static let watchdogTimeoutSeconds: TimeInterval = 5.0
    public static let denialCacheTTLSeconds: TimeInterval = 24 * 60 * 60

    public typealias Clock = @Sendable () -> TimeInterval

    /// Async hook: invokes `security find-generic-password -s <service> -w`
    /// (or a test fake) and returns the granular `RunResult` so the
    /// reader can distinguish "service not found" (exit 44 —
    /// `errSecItemNotFound`, the user simply hasn't paired with this
    /// service yet) from "user denied" (the prompt → Deny path) and
    /// from "watchdog tripped" (5 s timeout, prompt unanswered).
    /// (Phase 4E Slice 2b Gemini P0 — without this distinction,
    /// every user without Claude CLI installed got a 24 h denial
    /// cache for a perfectly normal absent-service case.)
    public typealias FetchHook = @Sendable (String) async -> SubprocessRunner.RunResult

    /// `errSecItemNotFound` from Security.framework — what `security`
    /// returns when the item simply doesn't exist. Distinct from
    /// `errSecAuthFailed` (user denied; exit code 51) and from a
    /// watchdog timeout.
    public static let errSecItemNotFound: Int32 = 44

    private let clock: Clock
    private let fetch: FetchHook

    /// service-name → epoch seconds when denial expires.
    private var deniedUntil: [String: TimeInterval] = [:]

    public init(
        clock: @escaping Clock = { Date().timeIntervalSince1970 },
        fetch: @escaping FetchHook = { service in
            await SubprocessRunner.runCapturingExit(
                executable: URL(fileURLWithPath: "/usr/bin/security"),
                arguments: ["find-generic-password", "-s", service, "-w"],
                timeoutSeconds: KeychainReader.watchdogTimeoutSeconds
            )
        }
    ) {
        self.clock = clock
        self.fetch = fetch
    }

    /// Result of a Keychain read.
    public enum Result: Sendable, Equatable {
        /// Successful read — `value` is whatever `security ... -w` printed
        /// to stdout, trimmed of trailing newline. Caller is responsible
        /// for parsing it (often as JSON).
        case success(value: String)
        /// User clicked Deny on the prompt, OR the watchdog tripped, OR
        /// the service simply doesn't exist. The reader caches this
        /// state for 24 h to avoid re-prompting every collection cycle.
        case unavailable(reason: Reason)
    }

    public enum Reason: String, Sendable, Equatable {
        case watchdogTimeout = "watchdog_timeout"
        case userDenied = "user_denied"
        case serviceNotFound = "service_not_found"
        case denialCached = "denial_cached"
    }

    /// Read the named generic password. `forceRetry: true` clears the
    /// denial cache for this service before attempting the read,
    /// giving the user a path to flip a previous denial.
    public func find(generic service: String, forceRetry: Bool = false) async -> Result {
        if forceRetry {
            deniedUntil.removeValue(forKey: service)
        }
        if let until = deniedUntil[service], clock() < until {
            return .unavailable(reason: .denialCached)
        }

        let runResult = await fetch(service)
        switch runResult {
        case .success(let stdout):
            let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .unavailable(reason: .serviceNotFound)
            }
            return .success(value: trimmed)

        case .nonZeroExit(let code, _):
            // `errSecItemNotFound` — the user simply hasn't paired
            // with this service yet. NOT a denial; do NOT cache, so
            // a future Claude CLI install is picked up immediately.
            if code == Self.errSecItemNotFound {
                return .unavailable(reason: .serviceNotFound)
            }
            // Any other non-zero exit (most commonly `errSecAuthFailed`
            // / `errSecMissingEntitlement` — user clicked Deny on the
            // prompt or the helper isn't entitled). Cache for 24 h.
            deniedUntil[service] = clock() + Self.denialCacheTTLSeconds
            return .unavailable(reason: .userDenied)

        case .timedOut:
            // The 5 s watchdog tripped — likely the user is AFK while
            // the prompt is up. Cache for 24 h to avoid spamming the
            // prompt every collection cycle.
            deniedUntil[service] = clock() + Self.denialCacheTTLSeconds
            return .unavailable(reason: .watchdogTimeout)

        case .spawnError, .cancelled:
            // `/usr/bin/security` can't spawn (sandbox blocking? SIP
            // weirdness?) OR our task got cancelled. Don't cache —
            // these are transient / environment issues, not user
            // intent.
            return .unavailable(reason: .userDenied)
        }
    }

    /// Test-only: drop all denial state.
    public func resetDenialCacheForTesting() {
        deniedUntil.removeAll()
    }
}
