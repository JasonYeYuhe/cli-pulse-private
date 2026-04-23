#if os(macOS)
import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
///
/// Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
/// Uses tokens from: env var, config apiKey, ~/.claude/.credentials.json, or Keychain.
public struct ClaudeOAuthStrategy: ClaudeSourceStrategy, Sendable {
    public let sourceLabel = "oauth"
    public let sourceType: SourceType = .oauth

    public func isAvailable(config: ProviderConfig) -> Bool {
        let (token, _) = ClaudeCredentials.resolveToken(config: config)
        return !token.isEmpty
    }

    public func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot {
        let (token, tier) = ClaudeCredentials.resolveToken(config: config)
        guard !token.isEmpty else { throw ClaudeStrategyError.noToken }

        let usage: OAuthUsageResponse
        do {
            usage = try await fetchUsage(token: token)
        } catch ClaudeStrategyError.httpError(let status, _) where status == 401 || status == 403 {
            // Token may have rotated — clear the keychain cache so the next
            // attempt re-reads from Claude Code's real keychain item.
            // Persist the tier we DID read from keychain before throwing so
            // the account-info cache keeps feeding the diagnostic copy
            // ("Signed in as X — Connect Claude Code"). Gemini 3.1 Pro review.
            if let tier, !tier.isEmpty {
                try? ClaudeHelperContract.writeAccountInfo(
                    ClaudeAccountInfo(accountEmail: nil, rateLimitTier: tier, weeklyReset: nil)
                )
            }
            ClaudeCredentials.clearCachedKeychainCredentials()
            throw ClaudeStrategyError.httpError(status: status, provider: "Claude")
        }
        return ClaudeSnapshot(
            sessionUsed: usage.fiveHour?.utilization,
            weeklyUsed: usage.sevenDay?.utilization,
            opusUsed: usage.sevenDayOpus?.utilization,
            sonnetUsed: usage.sevenDaySonnet?.utilization,
            sessionReset: usage.fiveHour?.resetsAt,
            weeklyReset: usage.sevenDay?.resetsAt,
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
                ?? ClaudeCredentials.readKeychainCredentials()?.rateLimitTier,
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
        var extra: ExtraUsage? = nil
        if let e = json["extra_usage"] as? [String: Any] {
            extra = ExtraUsage(
                isEnabled: e["is_enabled"] as? Bool ?? false,
                monthlyLimit: (e["monthly_limit"] as? NSNumber)?.doubleValue,
                usedCredits: (e["used_credits"] as? NSNumber)?.doubleValue,
                utilization: intFromJSON(e["utilization"]),
                currency: e["currency"] as? String
            )
        }
        return OAuthUsageResponse(
            fiveHour: parseWindow("five_hour"), sevenDay: parseWindow("seven_day"),
            sevenDayOpus: parseWindow("seven_day_opus"), sevenDaySonnet: parseWindow("seven_day_sonnet"),
            sevenDayOAuthApps: parseWindow("seven_day_oauth_apps"), extraUsage: extra
        )
    }
}
#endif
