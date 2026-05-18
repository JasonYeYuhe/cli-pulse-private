#if os(macOS)
import Foundation

/// Fetches usage/quota from Kimi via Connect RPC billing endpoint.
///
/// Endpoint: `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages`
/// Auth: JWT token from `KIMI_AUTH_TOKEN` env var or `config.apiKey`.
///
/// NOTE: The token is typically the `kimi-auth` browser cookie JWT. This collector
/// does not import cookies from browsers — it requires the token to be provided
/// via env var or config.
public struct KimiCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.kimi

    private static let cookieDomains = ["kimi.com", "www.kimi.com", "kimi.moonshot.cn"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = await resolveTokenAsync(config: config) else {
            throw CollectorError.missingCredentials("Kimi: no auth token (manual or auto-import)")
        }
        let data = try await fetchUsages(token: token)
        let parsed = try KimiCollector.parseResponse(data)
        return buildResult(parsed)
    }

    /// Synchronous token resolution (apiKey / manual cookie / env). Does not
    /// attempt browser auto-import — used by `isAvailable`.
    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey, !k.isEmpty { return k }
        if let k = config.manualCookieHeader, !k.isEmpty {
            // Extract kimi-auth value from cookie header
            return extractCookieValue(k, name: "kimi-auth") ?? k
        }
        if let k = ProcessInfo.processInfo.environment["KIMI_AUTH_TOKEN"], !k.isEmpty { return k }
        return nil
    }

    /// Full resolution including opt-in browser auto-import. Kimi uses the
    /// `kimi-auth` cookie value as a JWT bearer token, so we extract it from
    /// whatever cookie header the resolver returns.
    private func resolveTokenAsync(config: ProviderConfig) async -> String? {
        if let token = resolveToken(config: config) { return token }
        guard config.cookieSource == .automatic else { return nil }
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: [],
            domains: Self.cookieDomains,
            knownSessionCookieNames: ["kimi-auth"]
        )
        guard let header = resolution.headerValue else { return nil }
        return extractCookieValue(header, name: "kimi-auth") ?? header
    }

    private func extractCookieValue(_ header: String, name: String) -> String? {
        for part in header.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(name)=") {
                return String(trimmed.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    private func fetchUsages(token: String) async throws -> Data {
        guard let url = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages") else {
            throw CollectorError.invalidURL("kimi GetUsages")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("kimi-auth=\(token)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/code/console", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "connect-protocol-version")
        request.setValue("en-US", forHTTPHeaderField: "x-language")
        request.setValue("web", forHTTPHeaderField: "x-msh-platform")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: ["scope": ["FEATURE_CODING"]])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Kimi")
        }
        return data
    }

    // MARK: - Parsing

    struct KimiUsageData: Sendable {
        let weeklyLimit: Int?
        let weeklyUsed: Int?
        let weeklyRemaining: Int?
        let weeklyReset: String?
        let rateLimitUsed: Int?
        let rateLimitTotal: Int?
        let rateLimitReset: String?
    }

    static func parseResponse(_ data: Data) throws -> KimiUsageData {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usages = json["usages"] as? [[String: Any]],
              let first = usages.first else {
            throw CollectorError.parseFailed("Kimi: no usages array")
        }

        // Top-level detail (weekly quota)
        let detail = first["detail"] as? [String: Any]
        let weeklyLimit = (detail?["limit"] as? String).flatMap { Int($0) }
        let weeklyUsed = (detail?["used"] as? String).flatMap { Int($0) }
        let weeklyRemaining = (detail?["remaining"] as? String).flatMap { Int($0) }
        let weeklyReset = detail?["resetTime"] as? String

        // Per-window limits (e.g., 5-hour rate limit)
        var rlUsed: Int? = nil, rlTotal: Int? = nil, rlReset: String? = nil
        if let limits = first["limits"] as? [[String: Any]], let firstLimit = limits.first {
            let ld = firstLimit["detail"] as? [String: Any]
            rlTotal = (ld?["limit"] as? String).flatMap { Int($0) }
            rlUsed = (ld?["used"] as? String).flatMap { Int($0) }
            rlReset = ld?["resetTime"] as? String
        }

        return KimiUsageData(weeklyLimit: weeklyLimit, weeklyUsed: weeklyUsed,
                             weeklyRemaining: weeklyRemaining, weeklyReset: weeklyReset,
                             rateLimitUsed: rlUsed, rateLimitTotal: rlTotal, rateLimitReset: rlReset)
    }

    func buildResult(_ k: KimiUsageData) -> CollectorResult {
        var tiers: [TierDTO] = []

        if let limit = k.weeklyLimit, limit > 0 {
            tiers.append(TierDTO(name: "Weekly", quota: limit,
                                 remaining: k.weeklyRemaining ?? max(0, limit - (k.weeklyUsed ?? 0)),
                                 reset_time: k.weeklyReset))
        }
        if let total = k.rateLimitTotal, total > 0 {
            tiers.append(TierDTO(name: "5h Rate Limit", quota: total,
                                 remaining: max(0, total - (k.rateLimitUsed ?? 0)),
                                 reset_time: k.rateLimitReset))
        }

        let overallQuota = k.weeklyLimit
        let overallRemaining = k.weeklyRemaining
        let statusText: String
        if let used = k.weeklyUsed, let limit = k.weeklyLimit, limit > 0 {
            statusText = "\(used)/\(limit) used"
        } else {
            statusText = "Operational"
        }

        let usage = ProviderUsage(
            provider: ProviderKind.kimi.rawValue,
            today_usage: k.rateLimitUsed ?? 0, week_usage: k.weeklyUsed ?? 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: overallQuota, remaining: overallRemaining,
            plan_type: nil, reset_time: k.weeklyReset, tiers: tiers,
            status_text: statusText, trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Kimi", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
