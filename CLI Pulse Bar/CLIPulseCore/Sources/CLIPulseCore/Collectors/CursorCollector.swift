#if os(macOS)
import Foundation

/// Fetches usage summary from Cursor via cookie-based session auth.
///
/// Endpoint: `GET https://cursor.com/api/usage-summary`
/// Auth: Cookie header — session cookies from browser import or manual `config.manualCookieHeader`.
///
/// NOTE: This collector requires browser session cookies. It does not support
/// API key auth. The cookies must contain a valid Cursor session token.
public struct CursorCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.cursor

    private static let envVars = ["CURSOR_COOKIE"]
    // `.contains` domain matching (BrowserCookieQuery) means "cursor.sh" also
    // covers ".cursor.sh" and "authenticator.cursor.sh" — where Cursor's
    // WorkOS SSO session cookie frequently lands — so listing those explicitly
    // would be redundant. CodexBar parity: CursorStatusProbe imports the same
    // cursor.com / cursor.sh family. (internal, not private, for test access.)
    static let cookieDomains = ["cursor.com", "www.cursor.com", "cursor.sh"]
    private static let knownSessionNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token", "next-auth.session-token",
        "wos-session", "__Secure-wos-session",
        "authjs.session-token", "__Secure-authjs.session-token"
    ]

    /// Cursor auto-imports its browser session cookie by DEFAULT. A user who
    /// is logged into cursor.com in any browser is detected without first
    /// digging into settings to flip a toggle. `nil` (never configured) and an
    /// explicit `.automatic` both opt in; an explicit *other* source
    /// (`.manual`/`.safari`/`.chrome`/`.firefox`) is the user turning
    /// auto-import OFF and is honored. This default-ON behavior is scoped to
    /// Cursor — every other cookie provider keeps the byte-for-byte opt-in gate
    /// in `CookieResolver`.
    static func autoImportEligible(_ source: CookieSource?) -> Bool {
        source == nil || source == .automatic
    }

    public func isAvailable(config: ProviderConfig) -> Bool {
        if hasManualOrEnv(config: config) { return true }
        return Self.autoImportEligible(config.cookieSource)
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        // Mirror the default-ON gate at resolution time: CookieResolver only
        // attempts the browser importer when `cookieSource == .automatic`, so
        // for an eligible Cursor config with no manual cookie we normalize a
        // `nil` source to `.automatic` *locally* (the shared resolver — and
        // thus every other provider's opt-in gate — is left untouched). We
        // never override an explicit `.manual`/`.safari`/etc. choice.
        var resolveConfig = config
        if Self.autoImportEligible(config.cookieSource),
           config.manualCookieHeader?.isEmpty ?? true {
            resolveConfig.cookieSource = .automatic
        }
        let resolution = await CookieResolver.resolve(
            config: resolveConfig,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.knownSessionNames
        )
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("Cursor: no session cookie (manual or auto-import)")
        }
        let data = try await fetchUsageSummary(cookie: cookie)
        let parsed = try CursorCollector.parseResponse(data)
        return buildResult(parsed)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        if let c = ProcessInfo.processInfo.environment["CURSOR_COOKIE"], !c.isEmpty { return true }
        return false
    }

    private func fetchUsageSummary(cookie: String) async throws -> Data {
        guard let url = URL(string: "https://cursor.com/api/usage-summary") else {
            throw CollectorError.invalidURL("cursor usage-summary")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A stale/expired session cookie comes back as 401/403. Surface a
        // clear "not signed in" state instead of a generic HTTP error so the
        // user knows to re-open cursor.com (or paste a cookie) rather than
        // wondering why Cursor shows no data.
        if status == 401 || status == 403 {
            throw CollectorError.notSignedIn(
                "Cursor: not signed in — open cursor.com in your browser, or paste a session cookie")
        }
        guard (200...299).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "Cursor")
        }
        return data
    }

    // MARK: - Parsing

    struct CursorUsage: Sendable {
        let membershipType: String?
        let planUsedCents: Int
        let planLimitCents: Int
        let planRemainingCents: Int
        let onDemandUsedCents: Int
        let onDemandLimitCents: Int?
        let billingCycleEnd: String?
        let totalPercentUsed: Double?
    }

    static func parseResponse(_ data: Data) throws -> CursorUsage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Cursor: invalid JSON")
        }

        let membership = json["membershipType"] as? String
        let cycleEnd = json["billingCycleEnd"] as? String

        let indiv = json["individualUsage"] as? [String: Any] ?? [:]
        let plan = indiv["plan"] as? [String: Any] ?? [:]
        let onDemand = indiv["onDemand"] as? [String: Any] ?? [:]

        let planUsed = plan["used"] as? Int ?? 0
        let planLimit = plan["limit"] as? Int ?? 0
        let planRemaining = plan["remaining"] as? Int ?? planLimit - planUsed
        let odUsed = onDemand["used"] as? Int ?? 0
        let odLimit = onDemand["limit"] as? Int
        let totalPct = (plan["totalPercentUsed"] as? NSNumber)?.doubleValue

        return CursorUsage(membershipType: membership, planUsedCents: planUsed,
                           planLimitCents: planLimit, planRemainingCents: planRemaining,
                           onDemandUsedCents: odUsed, onDemandLimitCents: odLimit,
                           billingCycleEnd: cycleEnd, totalPercentUsed: totalPct)
    }

    func buildResult(_ c: CursorUsage) -> CollectorResult {
        var tiers: [TierDTO] = []
        if c.planLimitCents > 0 {
            tiers.append(TierDTO(name: "Plan", quota: c.planLimitCents,
                                 remaining: c.planRemainingCents, reset_time: c.billingCycleEnd))
        }
        if let odLimit = c.onDemandLimitCents, odLimit > 0 {
            tiers.append(TierDTO(name: "On-Demand", quota: odLimit,
                                 remaining: max(0, odLimit - c.onDemandUsedCents),
                                 reset_time: c.billingCycleEnd))
        }

        let pctUsed = c.totalPercentUsed ?? (c.planLimitCents > 0
            ? Double(c.planUsedCents) / Double(c.planLimitCents) * 100.0 : 0)

        let usage = ProviderUsage(
            provider: ProviderKind.cursor.rawValue,
            today_usage: c.planUsedCents, week_usage: c.planUsedCents,
            estimated_cost_today: Double(c.onDemandUsedCents) / 100.0,
            estimated_cost_week: Double(c.onDemandUsedCents) / 100.0,
            cost_status_today: c.onDemandUsedCents > 0 ? "Exact" : "Unavailable",
            cost_status_week: c.onDemandUsedCents > 0 ? "Exact" : "Unavailable",
            quota: c.planLimitCents > 0 ? c.planLimitCents : nil,
            remaining: c.planRemainingCents,
            plan_type: c.membershipType?.capitalized ?? "Unknown",
            reset_time: c.billingCycleEnd, tiers: tiers,
            status_text: String(format: "%.0f%% used", pctUsed),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Cursor", category: "ide",
                                       supports_exact_cost: true, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
