#if os(macOS)
import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
///
/// Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
/// Uses tokens from: env var, config apiKey, ~/.claude/.credentials.json, or Keychain.
///
/// Rate-limit backoff: after a 429 response, this strategy records a
/// 15-minute cooldown keyed by SHA256 token fingerprint via
/// `ClaudeOAuthBackoffState.shared`. During the cooldown window
/// `fetch()` short-circuits with `ClaudeStrategyError.rateLimitBackoff`
/// (which `shouldFallback == true`), so the resolver moves straight
/// to the web fallback without making the network call. On the
/// first successful response after the window clears, the entry is
/// dropped immediately so subsequent observations reflect live state.
public struct ClaudeOAuthStrategy: ClaudeSourceStrategy, Sendable {
    public let sourceLabel = "oauth"
    public let sourceType: SourceType = .oauth

    /// Backoff state. Defaults to the process singleton; tests inject
    /// a fresh actor with a controllable clock.
    private let backoff: ClaudeOAuthBackoffState

    public init(backoff: ClaudeOAuthBackoffState? = nil) {
        self.backoff = backoff ?? ClaudeOAuthBackoffState.shared
    }

    public func isAvailable(config: ProviderConfig) -> Bool {
        let (token, _) = ClaudeCredentials.resolveToken(config: config)
        return !token.isEmpty
    }

    public func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot {
        let (token, tier) = ClaudeCredentials.resolveToken(config: config)
        guard !token.isEmpty else { throw ClaudeStrategyError.noToken }

        // Pre-emptive backoff check. If we 429'd this token recently,
        // skip the network round-trip entirely and let the resolver
        // fall through to the web strategy. Avoids hammering Anthropic
        // with calls we already know will fail and risk extending the
        // cooldown window.
        let fingerprint = ClaudeOAuthBackoffState.fingerprint(forToken: token)
        if let remaining = await backoff.remainingBackoff(forFingerprint: fingerprint) {
            throw ClaudeStrategyError.rateLimitBackoff(remaining: remaining)
        }

        let usage: OAuthUsageResponse
        do {
            usage = try await fetchUsage(token: token)
        } catch ClaudeStrategyError.httpError(let status, _) where status == 401 || status == 403 {
            // Token may have rotated — clear the keychain cache so the next
            // attempt re-reads from Claude Code's real keychain item.
            // Persist the tier we DID read from keychain before throwing so
            // the account-info cache keeps feeding the diagnostic copy
            // ("Signed in as X — Connect Claude Code"). Gemini 3.1 Pro review.
            //
            // Note: 401/403 do NOT trigger backoff. Auth failures aren't
            // rate-limit failures — they call for a token refresh, not a
            // cooldown. Recording them in the 429 backoff path would
            // incorrectly suppress retries after the user re-authenticates.
            if let tier, !tier.isEmpty {
                try? ClaudeHelperContract.writeAccountInfo(
                    ClaudeAccountInfo(accountEmail: nil, rateLimitTier: tier, weeklyReset: nil)
                )
            }
            ClaudeCredentials.clearCachedKeychainCredentials()
            // v1.30.x: arm the cross-app keychain-read cooldown so a token that
            // keeps 401ing can't re-trigger the macOS keychain dialog on every
            // ~3-4 min refresh. Only here (auth failure) — NOT on a user
            // Disconnect; a user-initiated Connect bypasses the cooldown.
            ClaudeCredentials.installKeychainReadCooldown()
            throw ClaudeStrategyError.httpError(status: status, provider: "Claude")
        } catch ClaudeStrategyError.httpError(let status, _) where status == 429 {
            // Genuine rate-limit response. Record the failure so the
            // next refresh cycle skips OAuth pre-emptively. Re-throw
            // so the resolver still logs "[oauth] failed: HTTP 429"
            // for this cycle (the next cycle will log the distinct
            // "rate-limit backoff active" line instead).
            await backoff.recordFailure(forFingerprint: fingerprint)
            throw ClaudeStrategyError.httpError(status: status, provider: "Claude")
        }

        // Success path — clear any backoff entry for this fingerprint
        // so a transient 429 that has just cleared doesn't keep
        // suppressing OAuth until the natural 15-min expiry.
        await backoff.reset(forFingerprint: fingerprint)

        return ClaudeSnapshot(
            sessionUsed: usage.fiveHour?.utilization,
            weeklyUsed: usage.sevenDay?.utilization,
            opusUsed: usage.sevenDayOpus?.utilization,
            sonnetUsed: usage.sevenDaySonnet?.utilization,
            designsUsed: usage.iguanaNecktie?.utilization,
            dailyRoutinesUsed: usage.sevenDayOmelette?.utilization,
            sessionReset: usage.fiveHour?.resetsAt,
            weeklyReset: usage.sevenDay?.resetsAt,
            designsReset: usage.iguanaNecktie?.resetsAt,
            dailyRoutinesReset: usage.sevenDayOmelette?.resetsAt,
            extraUsage: usage.extraUsage.flatMap { e in
                e.isEnabled ? ClaudeExtraUsage(
                    isEnabled: true,
                    monthlyLimit: e.monthlyLimit,
                    usedCredits: e.usedCredits,
                    currency: e.currency
                ) : nil
            },
            rateLimitTier: tier
                ?? ClaudeCredentials.readCredentialsFile()?.rateLimitTier
                ?? (PrivacySettings.shared.skipClaudeKeychain
                    ? nil
                    : ClaudeCredentials.readKeychainCredentials()?.rateLimitTier),
            sourceLabel: sourceLabel
        )
    }

    // MARK: - API

    private func fetchUsage(token: String) async throws -> OAuthUsageResponse {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw ClaudeStrategyError.parseFailed("invalid URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("CLIPulseBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeStrategyError.parseFailed("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClaudeStrategyError.httpError(status: http.statusCode, provider: "Claude")
        }
        return try Self.parseUsage(data)
    }

    // MARK: - Response types (internal for testing)

    struct UsageWindow: Sendable {
        let utilization: Int
        let resetsAt: String?
    }

    struct ExtraUsage: Sendable {
        let isEnabled: Bool
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Int?
        let currency: String?
    }

    struct OAuthUsageResponse: Sendable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        let sevenDayOAuthApps: UsageWindow?
        /// Designs (raw key `iguana_necktie`). Launch-window null semantics:
        /// a present-but-null value parses as `UsageWindow(utilization: 0,
        /// resetsAt: nil)` (enabled-but-unused bucket). An absent key still
        /// yields `nil` so accounts where the rollout hasn't reached them
        /// don't see a phantom row.
        let iguanaNecktie: UsageWindow?
        /// Daily Routines (raw key `seven_day_omelette`). Same launch-window
        /// null semantics as `iguanaNecktie`.
        let sevenDayOmelette: UsageWindow?
        let extraUsage: ExtraUsage?
    }

    /// Coerce a JSON value that may be `Int` or `Double` into `Int`.
    ///
    /// Anthropic's OAuth /usage API returns `utilization` as a JSON number that
    /// Foundation decodes as `Double` (e.g. `9.0`). A bare `as? Int` cast on
    /// `NSNumber(Double)` returns `nil`, which previously collapsed every
    /// window's utilization to the `?? 0` fallback — the bug behind
    /// "Quota data unavailable" on macOS. Coercing via `NSNumber` first,
    /// then rounding, handles both `Int` and `Double` shapes.
    static func intFromJSON(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
        return nil
    }

    static func parseUsage(_ data: Data) throws -> OAuthUsageResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStrategyError.parseFailed("invalid JSON")
        }
        func parseWindow(_ key: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any] else { return nil }
            return UsageWindow(
                utilization: intFromJSON(w["utilization"]) ?? 0,
                resetsAt: w["resets_at"] as? String
            )
        }
        // Launch-window probe: distinguishes "key absent" (skip) from
        // "key present-but-null" (emit a 0/nil bucket). Mirrors the
        // helper's `_add_launch_window` semantics. Existing optional
        // model windows (Opus, OAuth Apps) keep `parseWindow`'s
        // present-but-null → nil behavior.
        func parseLaunchWindow(_ key: String) -> UsageWindow? {
            guard let value = json[key] else { return nil }            // absent
            if value is NSNull {
                return UsageWindow(utilization: 0, resetsAt: nil)      // present-but-null
            }
            if let w = value as? [String: Any] {
                return UsageWindow(
                    utilization: intFromJSON(w["utilization"]) ?? 0,
                    resetsAt: w["resets_at"] as? String
                )
            }
            return nil
        }
        var extra: ExtraUsage? = nil
        if let e = json["extra_usage"] as? [String: Any] {
            // v1.24 Phase 1 Item #7 (CodexBar 11f92065): Anthropic's
            // `/api/oauth/usage` returns `monthly_limit` and `used_credits`
            // in MINOR units (cents) — the same convention as the Web API
            // (`/api/organizations/{orgId}/overage_spend_limit`, where
            // ClaudeWebStrategy.fetchOverageSpendLimit already divides by 100).
            // Convert here so downstream display (which expects dollars)
            // doesn't show 100× values. Upstream lesson: the SpendLimit-vs-OAuth
            // distinction is irrelevant — both endpoints emit cents.
            extra = ExtraUsage(
                isEnabled: e["is_enabled"] as? Bool ?? false,
                monthlyLimit: (e["monthly_limit"] as? NSNumber).map { $0.doubleValue / 100.0 },
                usedCredits: (e["used_credits"] as? NSNumber).map { $0.doubleValue / 100.0 },
                utilization: intFromJSON(e["utilization"]),
                currency: e["currency"] as? String
            )
        }
        return OAuthUsageResponse(
            fiveHour: parseWindow("five_hour"),
            sevenDay: parseWindow("seven_day"),
            sevenDayOpus: parseWindow("seven_day_opus"),
            sevenDaySonnet: parseWindow("seven_day_sonnet"),
            sevenDayOAuthApps: parseWindow("seven_day_oauth_apps"),
            iguanaNecktie: parseLaunchWindow("iguana_necktie"),
            sevenDayOmelette: parseLaunchWindow("seven_day_omelette"),
            extraUsage: extra
        )
    }
}
#endif
