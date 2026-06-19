#if os(macOS)
import Foundation

// MARK: - Strategy protocol

/// A single source strategy for fetching Claude usage data.
/// Each strategy represents one method of obtaining quota information
/// (OAuth API, Web session, CLI PTY probe).
public protocol ClaudeSourceStrategy: Sendable {
    /// Human-readable identifier for logging/diagnostics.
    var sourceLabel: String { get }

    /// The SourceType this strategy produces.
    var sourceType: SourceType { get }

    /// Quick check: can this strategy plausibly run with the given config?
    /// Must not perform network I/O.
    func isAvailable(config: ProviderConfig) -> Bool

    /// Fetch Claude usage data. Throws on failure.
    func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot
}

// MARK: - Unified snapshot from any source

/// Normalized Claude usage data that any strategy produces.
/// Maps directly to CollectorResult via `ClaudeResultBuilder`.
public struct ClaudeSnapshot: Sendable {
    public let sessionUsed: Int?        // 0-100 utilization %
    public let weeklyUsed: Int?
    public let opusUsed: Int?
    public let sonnetUsed: Int?
    public let designsUsed: Int?
    public let dailyRoutinesUsed: Int?
    public let sessionReset: String?    // ISO8601 or human-readable
    public let weeklyReset: String?
    public let designsReset: String?
    public let dailyRoutinesReset: String?
    public let extraUsage: ClaudeExtraUsage?
    public let rateLimitTier: String?
    public let accountEmail: String?
    public let sourceLabel: String

    public init(
        sessionUsed: Int? = nil, weeklyUsed: Int? = nil,
        opusUsed: Int? = nil, sonnetUsed: Int? = nil,
        designsUsed: Int? = nil, dailyRoutinesUsed: Int? = nil,
        sessionReset: String? = nil, weeklyReset: String? = nil,
        designsReset: String? = nil, dailyRoutinesReset: String? = nil,
        extraUsage: ClaudeExtraUsage? = nil,
        rateLimitTier: String? = nil,
        accountEmail: String? = nil,
        sourceLabel: String
    ) {
        self.sessionUsed = sessionUsed
        self.weeklyUsed = weeklyUsed
        self.opusUsed = opusUsed
        self.sonnetUsed = sonnetUsed
        self.designsUsed = designsUsed
        self.dailyRoutinesUsed = dailyRoutinesUsed
        self.sessionReset = sessionReset
        self.weeklyReset = weeklyReset
        self.designsReset = designsReset
        self.dailyRoutinesReset = dailyRoutinesReset
        self.extraUsage = extraUsage
        self.rateLimitTier = rateLimitTier
        self.accountEmail = accountEmail
        self.sourceLabel = sourceLabel
    }

    /// True when at least one of the quota windows has a parsed value.
    /// Used by `ClaudeResultBuilder` to decide whether to emit a real quota
    /// envelope or an "unavailable" placeholder.
    public var hasAnyUsage: Bool {
        sessionUsed != nil
            || weeklyUsed != nil
            || sonnetUsed != nil
            || opusUsed != nil
            || designsUsed != nil
            || dailyRoutinesUsed != nil
    }

    /// Return a copy with `accountEmail` / `rateLimitTier` / `weeklyReset`
    /// filled in from `info` only when this snapshot's corresponding field is
    /// nil. Usage fields are never touched — the account cache is metadata-only.
    /// Called by `ClaudeSourceResolver` after the strategy chain returns so the
    /// pure `ClaudeResultBuilder.build` transform stays untouched.
    public func mergingAccountInfo(_ info: ClaudeAccountInfo?) -> ClaudeSnapshot {
        guard let info else { return self }
        return ClaudeSnapshot(
            sessionUsed: sessionUsed,
            weeklyUsed: weeklyUsed,
            opusUsed: opusUsed,
            sonnetUsed: sonnetUsed,
            designsUsed: designsUsed,
            dailyRoutinesUsed: dailyRoutinesUsed,
            sessionReset: sessionReset,
            weeklyReset: weeklyReset ?? info.weeklyReset,
            designsReset: designsReset,
            dailyRoutinesReset: dailyRoutinesReset,
            extraUsage: extraUsage,
            rateLimitTier: rateLimitTier ?? info.rateLimitTier,
            accountEmail: accountEmail ?? info.accountEmail,
            sourceLabel: sourceLabel
        )
    }
}

/// Account-level metadata Claude provides that can be cached independently
/// of the strict quota snapshot. Written by any strategy that gets this data
/// even when the quota fetch itself failed.
public struct ClaudeAccountInfo: Sendable {
    public let accountEmail: String?
    public let rateLimitTier: String?
    public let weeklyReset: String?

    public init(accountEmail: String? = nil, rateLimitTier: String? = nil, weeklyReset: String? = nil) {
        self.accountEmail = accountEmail
        self.rateLimitTier = rateLimitTier
        self.weeklyReset = weeklyReset
    }

    public var isEmpty: Bool {
        accountEmail == nil && rateLimitTier == nil && weeklyReset == nil
    }
}

/// Extra usage / credit info from Claude.
public struct ClaudeExtraUsage: Sendable {
    public let isEnabled: Bool
    public let monthlyLimit: Double?
    public let usedCredits: Double?
    public let currency: String?

    public init(isEnabled: Bool, monthlyLimit: Double? = nil,
                usedCredits: Double? = nil, currency: String? = nil) {
        self.isEnabled = isEnabled
        self.monthlyLimit = monthlyLimit
        self.usedCredits = usedCredits
        self.currency = currency
    }
}

// MARK: - Result builder

/// Converts a `ClaudeSnapshot` into a `CollectorResult`.
public enum ClaudeResultBuilder {
    public static func build(from snapshot: ClaudeSnapshot) -> CollectorResult {
        var tiers: [TierDTO] = []
        if let u = snapshot.sessionUsed {
            tiers.append(TierDTO(name: "5h Window", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.sessionReset))
        }
        if let u = snapshot.weeklyUsed {
            tiers.append(TierDTO(name: "Weekly", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.weeklyReset))
        }
        if let u = snapshot.sonnetUsed ?? snapshot.opusUsed {
            tiers.append(TierDTO(name: "Sonnet only", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.weeklyReset))
        }
        if let u = snapshot.designsUsed {
            tiers.append(TierDTO(name: "Designs", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.designsReset))
        }
        if let u = snapshot.dailyRoutinesUsed {
            tiers.append(TierDTO(name: "Daily Routines", quota: 100, remaining: max(0, 100 - u), reset_time: snapshot.dailyRoutinesReset))
        }

        let planType: String
        let tierLower = (snapshot.rateLimitTier ?? "").lowercased()
        // Match specific Max tiers first (20x before generic max)
        if tierLower.contains("max_20x") || tierLower.contains("max 20x") { planType = "Max 20x" }
        else if tierLower.contains("max_5x") || tierLower.contains("max 5x") { planType = "Max 5x" }
        else if tierLower.contains("max") { planType = "Max 5x" }  // default Max → 5x
        else if tierLower.contains("ultra") { planType = "Ultra" }
        else if tierLower.contains("pro") { planType = "Pro" }
        else if tierLower.contains("team") { planType = "Team" }
        else if tierLower.contains("enterprise") { planType = "Enterprise" }
        else if tierLower.contains("free") { planType = "Free" }
        else if tierLower.isEmpty { planType = "Unknown" }
        else { planType = "Unknown" }

        // Be honest: if no strategy populated any of the three quota windows
        // we used to emit `quota=100, remaining=100, tiers=[]`, which AppState
        // turned into a misleading "Default 100% left" bar. Now we report
        // `quota=nil` so the UI can render an "unavailable" placeholder.
        let hasUsage = snapshot.hasAnyUsage
        let overallQuota: Int? = hasUsage ? 100 : nil
        let overallRemaining: Int? = hasUsage ? (snapshot.sessionUsed.map { max(0, 100 - $0) } ?? 100) : nil
        let statusText: String
        if let used = snapshot.sessionUsed {
            statusText = "\(used)% used"
        } else if hasUsage {
            statusText = "Operational"
        } else if let email = snapshot.accountEmail {
            // Signed in but quota not reaching us (OAuth keychain not granted,
            // or Cloudflare challenge / schema drift on the web endpoint).
            // Point the user at the Connect action rather than the obsolete
            // `/usage` CLI command — that command was removed in Claude v2.x.
            statusText = "Signed in as \(email) — Connect Claude Code in Settings"
        } else {
            // No signal at all: no account email, no usage. Direct the user
            // to Settings → Claude where the Connect button lives.
            statusText = "Claude quota unavailable — Connect in Settings → Claude"
        }

        #if DEBUG
        if !hasUsage {
            print("[ClaudeResultBuilder] WARN no usage windows captured (source=\(snapshot.sourceLabel)) — emitting unavailable placeholder")
        }
        #endif

        let providerUsage = ProviderUsage(
            provider: ProviderKind.claude.rawValue,
            today_usage: snapshot.sessionUsed ?? 0,
            week_usage: snapshot.weeklyUsed ?? 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: overallQuota, remaining: overallRemaining, plan_type: planType,
            reset_time: snapshot.sessionReset, tiers: tiers, status_text: statusText,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Claude", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: providerUsage, dataKind: .quota)
    }
}

// MARK: - Shared credential helpers

/// Shared helpers for Claude credential resolution, used by multiple strategies.
public enum ClaudeCredentials {
    /// Real home directory (not sandbox-remapped).
    public static var realHomeDir: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return String(cString: dir)
        }
        let nsHome = NSHomeDirectory()
        if let range = nsHome.range(of: "/Library/Containers/") {
            return String(nsHome[nsHome.startIndex..<range.lowerBound])
        }
        return nsHome
    }

    public struct Creds: Sendable {
        public let accessToken: String
        public let rateLimitTier: String?
    }

    /// Parse credentials from JSON data (supports both snake_case and camelCase).
    public static func parseCredentialsJSON(_ data: Data) -> Creds? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let oauth = json["claude_ai_oauth"] as? [String: Any],
           let token = oauth["access_token"] as? String, !token.isEmpty {
            return Creds(accessToken: token, rateLimitTier: oauth["rate_limit_tier"] as? String)
        }
        if let oauth = json["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String, !token.isEmpty {
            return Creds(accessToken: token, rateLimitTier: oauth["rateLimitTier"] as? String)
        }
        return nil
    }

    /// Read credentials from ~/.claude/.credentials.json file.
    public static func readCredentialsFile() -> Creds? {
        let path = (realHomeDir as NSString).appendingPathComponent(".claude/.credentials.json")
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return parseCredentialsJSON(data)
    }

    /// Read credentials from macOS Keychain (Claude Code's keychain item).
    ///
    /// The sandboxed app cannot access cross-app keychain items without
    /// triggering a macOS authorization dialog. To avoid prompting the
    /// user on every launch, we cache the credentials in the app's own
    /// keychain after the first successful read.
    /// - Parameter bypassCooldown: pass `true` for USER-initiated reads
    ///   (the Settings "Connect Claude Code" button) so a cooldown armed by a
    ///   background 401 never blocks an explicit reconnect/re-auth. Background
    ///   refreshers leave it `false`.
    public static func readKeychainCredentials(bypassCooldown: Bool = false) -> Creds? {
        // 1. Try the app's own keychain cache (never triggers a prompt)
        if let cached = KeychainHelper.load(key: keychainCacheKey),
           let data = cached.data(using: .utf8),
           let creds = parseCredentialsJSON(data) {
            return creds
        }

        // 1b. Cross-app read cooldown (v1.30.x — keychain prompt-spam fix).
        // The cross-app read below shows a macOS authorization dialog
        // ("CLIPulseHelper wants to use Claude Code-credentials"). The cache
        // above normally means we prompt once and never again — BUT a recurring
        // OAuth 401 calls clearCachedKeychainCredentials() every refresh, wiping
        // the cache and forcing a re-read here on every ~3-4 min cycle, so the
        // user is prompted forever (and "Always Allow" doesn't stick on macOS 26
        // / when `claude` rewrites the item). When the cache was cleared due to
        // a bad token we install a cooldown: skip the cross-app read (return nil
        // → the resolver falls back to cli-pty/JSONL/web, no prompt) until it
        // expires, capping prompts to ≤1 per cooldown window. See
        // feedback_claude_oauth_keychain_prompt_spam.
        if !bypassCooldown, isKeychainReadOnCooldown() {
            return nil
        }

        // 2. Read from Claude Code's keychain (may trigger one-time prompt)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        guard let creds = parseCredentialsJSON(data) else { return nil }

        // 3. Cache in the app's own keychain so the prompt never recurs, and
        //    clear any cooldown — a successful read means we're back to normal.
        if let jsonStr = String(data: data, encoding: .utf8) {
            KeychainHelper.save(key: keychainCacheKey, value: jsonStr)
        }
        clearKeychainReadCooldown()
        return creds
    }

    /// Clear the cached Claude Code credentials (cache-only — does NOT arm the
    /// cooldown). Used by both the OAuth-401 path and the Settings "Disconnect"
    /// button; only the 401 path arms the cooldown (it calls
    /// `installKeychainReadCooldown()` itself), so a user Disconnect followed by
    /// Connect is never blocked by the cooldown (codex review 2026-06-19).
    public static func clearCachedKeychainCredentials() {
        KeychainHelper.delete(key: keychainCacheKey)
    }

    // MARK: - Cross-app keychain read cooldown (prompt-spam guard)

    /// How long to suppress cross-app `Claude Code-credentials` reads after a
    /// bad-token cache clear. 30 min: long enough to stop per-cycle prompts
    /// (~3-4 min refresh), short enough that a genuine re-auth recovers soon.
    static var keychainReadCooldownInterval: TimeInterval = 30 * 60

    /// Injectable clock for tests.
    static var nowProvider: () -> Date = { Date() }

    private static let keychainReadCooldownKey = "claudeCodeKeychainReadCooldownUntil"

    /// Cooldown state lives in the app-group defaults (NOT the per-app
    /// keychain) so it is SHARED between the main app and the CLIPulseHelper
    /// LoginItem — both read the cross-app item, so a 401 observed in either
    /// process must suppress the read in both. Defaults to the app group;
    /// tests inject a throwaway suite.
    static var cooldownDefaults: UserDefaults =
        UserDefaults(suiteName: "group.yyh.CLI-Pulse") ?? .standard

    static func installKeychainReadCooldown() {
        let until = nowProvider().addingTimeInterval(keychainReadCooldownInterval)
        cooldownDefaults.set(until.timeIntervalSince1970, forKey: keychainReadCooldownKey)
    }

    static func clearKeychainReadCooldown() {
        cooldownDefaults.removeObject(forKey: keychainReadCooldownKey)
    }

    /// True while a cooldown installed by a bad-token clear is still active.
    static func isKeychainReadOnCooldown() -> Bool {
        let epoch = cooldownDefaults.double(forKey: keychainReadCooldownKey)
        guard epoch > 0 else { return false }
        if nowProvider().timeIntervalSince1970 >= epoch {
            // Expired — clean it up so the next read attempts the cross-app
            // keychain once more.
            cooldownDefaults.removeObject(forKey: keychainReadCooldownKey)
            return false
        }
        return true
    }

    /// Peek at the app's own keychain cache without ever triggering a
    /// cross-app prompt. Used by UI to show "Connected" status without
    /// side effects. Returns nil if no cached credentials exist.
    public static func readCachedKeychainCredentials() -> Creds? {
        guard let cached = KeychainHelper.load(key: keychainCacheKey),
              let data = cached.data(using: .utf8),
              let creds = parseCredentialsJSON(data) else { return nil }
        return creds
    }

    private static let keychainCacheKey = "claude-code-creds-cache"

    /// Resolve an OAuth token from all available sources.
    public static func resolveToken(config: ProviderConfig) -> (token: String, tier: String?) {
        // Check environment variables: app-specific first, then Claude Code's own
        for envKey in ["CODEXBAR_CLAUDE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"] {
            if let envToken = ProcessInfo.processInfo.environment[envKey],
               !envToken.isEmpty, envToken.hasPrefix("sk-ant-oat") {
                return (envToken, nil)
            }
        }
        if let configKey = config.apiKey, configKey.hasPrefix("sk-ant-oat") {
            return (configKey, nil)
        }
        if let fileCreds = readCredentialsFile() {
            return (fileCreds.accessToken, fileCreds.rateLimitTier)
        }
        if !PrivacySettings.shared.skipClaudeKeychain,
           let keychainCreds = readKeychainCredentials()
        {
            return (keychainCreds.accessToken, keychainCreds.rateLimitTier)
        }
        return ("", nil)
    }

    /// Strip ANSI escape codes from text.
    /// Cursor-movement sequences (like ESC[1C used by TUI between words) become spaces
    /// so that "Quick[1Csafety[1Ccheck" → "Quick safety check" instead of "Quicksafetycheck".
    public static func stripANSI(_ text: String) -> String {
        // First replace cursor-movement sequences with spaces (ESC[nC = cursor forward)
        var result = text
        if let cursorFwd = try? NSRegularExpression(pattern: "\\x1B\\[\\d*C") {
            result = cursorFwd.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: " ")
        }
        // Then strip remaining ANSI escape sequences
        if let ansi = try? NSRegularExpression(pattern: "\\x1B\\[[0-?]*[ -/]*[@-~]") {
            result = ansi.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        // Also strip OSC sequences (ESC]...BEL)
        if let osc = try? NSRegularExpression(pattern: "\\x1B\\][^\\x07]*\\x07") {
            result = osc.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "")
        }
        return result
    }
}

// MARK: - Error types

public enum ClaudeStrategyError: LocalizedError, Sendable {
    case noToken
    case httpError(status: Int, provider: String)
    case parseFailed(String)
    case noBinary
    case noSessionKey
    case unauthorized
    case timedOut
    case processExited
    /// OAuth strategy was skipped because a recent 429 is still in
    /// the cooldown window. `remaining` is the seconds left in the
    /// current backoff window. Always `shouldFallback == true` so
    /// the resolver immediately moves to the next strategy without
    /// hitting the network. Distinct from `httpError(429, _)` so the
    /// resolver log clearly shows "skipped pre-emptively" vs "hit
    /// 429 just now".
    case rateLimitBackoff(remaining: TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .noToken: return "No Claude OAuth token available"
        case .httpError(let s, _): return "Claude API HTTP \(s)"
        case .parseFailed(let m): return "Claude parse failed: \(m)"
        case .noBinary: return "Claude CLI binary not found"
        case .noSessionKey: return "No Claude session key available"
        case .unauthorized: return "Claude session expired or unauthorized"
        case .timedOut: return "Claude probe timed out"
        case .processExited: return "Claude CLI process exited unexpectedly"
        case .rateLimitBackoff(let remaining):
            // Round to whole minutes for the user-visible log line —
            // sub-minute precision adds nothing for "we're sitting out
            // a rate-limit window" diagnostics.
            let mins = Int(ceil(remaining / 60))
            return "Claude OAuth rate-limit backoff active (~\(mins)m remaining)"
        }
    }

    /// Whether this error should trigger fallback to the next strategy.
    public var shouldFallback: Bool {
        switch self {
        case .httpError(let status, _):
            return status == 429 || status == 401 || status == 403
        case .noToken, .noBinary, .noSessionKey, .unauthorized, .timedOut, .processExited:
            return true
        case .parseFailed:
            return true
        case .rateLimitBackoff:
            // The whole point: skip OAuth pre-emptively, fall through
            // to the next strategy.
            return true
        }
    }
}
#endif
