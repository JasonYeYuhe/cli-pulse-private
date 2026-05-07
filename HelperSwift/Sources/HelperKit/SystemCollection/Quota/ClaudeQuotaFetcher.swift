import Foundation

/// Fetches Claude usage via the Anthropic OAuth API. Reads the OAuth
/// access token from the macOS Keychain (where Claude CLI persists
/// it under service name `Claude Code-credentials`), checks expiry,
/// optionally refreshes via the OAuth token endpoint, then calls
/// `https://api.anthropic.com/api/oauth/usage` and parses the
/// response into a `ProviderQuotaSnapshot`.
///
/// Phase 4E Slice 2c — port of `helper/system_collector.py`'s OAuth
/// fetch path. Web-cookie fallback is **deferred to Slice 2c.5**:
/// without `ChromiumCookieReader`, this fetcher returns
/// `.unavailable(reason: "oauth_unauthorized")` when OAuth fails.
/// Production daemon during the transition continues to invoke
/// Python for the cookie path (Phase 4E hasn't shipped Slice 4 yet,
/// so the Python helper is still the live runtime).
public actor ClaudeQuotaFetcher {

    public static let keychainServiceName = "Claude Code-credentials"

    public typealias HTTPHook = @Sendable (URLRequest) async -> (Data, HTTPURLResponse)?

    private let keychain: KeychainReader
    private let backoff: OAuthBackoff
    private let http: HTTPHook
    private let cookieReader: ChromiumCookieReader?
    private let now: @Sendable () -> Date

    public init(
        keychain: KeychainReader,
        backoff: OAuthBackoff,
        http: @escaping HTTPHook = ClaudeQuotaFetcher.liveHTTP,
        cookieReader: ChromiumCookieReader? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.backoff = backoff
        self.http = http
        self.cookieReader = cookieReader
        self.now = now
    }

    // MARK: - Public entry

    public func fetch() async -> ProviderQuotaSnapshot {
        let formatter = SessionDetector.makeISOFormatter()
        let nowDate = now()
        let nowISO = formatter.string(from: nowDate)

        // Step 1 — try OAuth (Keychain → API). Returns the snapshot
        // on success OR a tagged failure reason for the fallback to
        // pivot on.
        let oauthSnapshot = await fetchViaOAuth(planTypeOverride: nil, nowISO: nowISO)
        if case .anthropicOAuth = oauthSnapshot.provenance {
            return oauthSnapshot
        }

        // Step 2 — fall through to web-cookie path (Slice 2c.5
        // follow-up). Skip if no cookieReader was injected (callers
        // who don't want the fallback can pass `nil`).
        if let cookieReader {
            if let webSnapshot = await fetchViaWebCookie(
                cookieReader: cookieReader,
                nowISO: nowISO
            ) {
                return webSnapshot
            }
        }

        // Both paths failed. Return the most informative failure
        // reason — the OAuth one carries more diagnostic info than
        // a generic "web_failed".
        return oauthSnapshot
    }

    // MARK: - OAuth path

    private func fetchViaOAuth(
        planTypeOverride: String?,
        nowISO: String
    ) async -> ProviderQuotaSnapshot {
        let nowDate = now()

        // Step 1: Read keychain blob.
        let kr = await keychain.find(generic: Self.keychainServiceName)
        guard case .success(let raw) = kr else {
            let reason: String
            if case .unavailable(let r) = kr {
                reason = "keychain_\(r.rawValue)"
            } else {
                reason = "keychain_unknown"
            }
            return Self.unavailable(reason: reason, fetchedAt: nowISO)
        }

        // Step 2: Parse the JSON blob, extract access token + tier
        // strings + expiry. Both camelCase and snake_case shapes are
        // valid (Python supports both for forward-compat).
        guard
            let data = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return Self.unavailable(reason: "keychain_parse_error", fetchedAt: nowISO)
        }
        let oauth = (parsed["claudeAiOauth"] as? [String: Any])
            ?? (parsed["claude_ai_oauth"] as? [String: Any])
            ?? [:]
        let token = (oauth["accessToken"] as? String) ?? (oauth["access_token"] as? String) ?? ""
        let tier = (oauth["rateLimitTier"] as? String)
            ?? (oauth["rate_limit_tier"] as? String)
            ?? ""
        let subType = (oauth["subscriptionType"] as? String) ?? ""
        let planType = ClaudePlanInferrer.plan(
            rateLimitTier: tier,
            subscriptionType: subType
        )

        guard token.hasPrefix("sk-ant-oat") else {
            return Self.unavailable(reason: "oauth_token_missing", fetchedAt: nowISO)
        }

        // Step 3: Check expiry. We don't refresh in Slice 2c — that
        // requires a separate OAuth refresh call which we'll add in
        // 2c.5. For now, expired tokens fall through to .unavailable.
        if let expiry = Self.normalizedExpiry(from: oauth),
           nowDate.timeIntervalSince1970 > expiry {
            return Self.unavailable(reason: "oauth_expired", fetchedAt: nowISO)
        }

        // Step 4: Check 429 backoff before the call.
        let fingerprint = OAuthBackoff.fingerprint(forToken: token)
        if await backoff.remaining(fingerprint) != nil {
            return Self.unavailable(reason: "oauth_429_backoff", fetchedAt: nowISO)
        }

        // Step 5: HTTP call.
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            return Self.unavailable(reason: "url_construction", fetchedAt: nowISO)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("CLI-Pulse-Helper/Swift", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (body, response) = await http(req) else {
            return Self.unavailable(reason: "network_error", fetchedAt: nowISO)
        }
        switch response.statusCode {
        case 200...299:
            // Success — clear any stale backoff entry.
            await backoff.reset(fingerprint)
            return Self.parseAPIResponse(body, planType: planType, fetchedAt: nowISO)
        case 429:
            await backoff.register(fingerprint)
            return Self.unavailable(reason: "oauth_429", fetchedAt: nowISO)
        case 401, 403:
            return Self.unavailable(reason: "oauth_unauthorized", fetchedAt: nowISO)
        default:
            return Self.unavailable(reason: "http_\(response.statusCode)", fetchedAt: nowISO)
        }
    }

    // MARK: - Web cookie path (Slice 2c.5)

    /// Fall through path when OAuth fails. Resolves a `sessionKey`
    /// from the user's browser via `ChromiumCookieReader`, then
    /// calls `claude.ai/api/organizations` (to learn the org_id)
    /// followed by `/api/organizations/{org_id}/usage`. Mirrors
    /// Python `_fetch_claude_web_usage`.
    ///
    /// Returns `nil` (NOT a `.unavailable` snapshot) on any failure
    /// so the caller can decide whether to surface the OAuth-side
    /// failure reason or this one. The caller currently picks the
    /// OAuth one because it's typically more diagnostic.
    private func fetchViaWebCookie(
        cookieReader: ChromiumCookieReader,
        nowISO: String
    ) async -> ProviderQuotaSnapshot? {
        guard let resolved = await cookieReader.resolveClaudeSessionKey() else {
            return nil
        }
        let sessionKey = resolved.key

        // Step 1: Get org_id.
        guard let orgsURL = URL(string: "https://claude.ai/api/organizations") else {
            return nil
        }
        var orgReq = URLRequest(url: orgsURL)
        orgReq.timeoutInterval = 15
        orgReq.httpMethod = "GET"
        orgReq.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        orgReq.setValue("application/json", forHTTPHeaderField: "Accept")
        orgReq.setValue("CLI-Pulse-Helper/Swift", forHTTPHeaderField: "User-Agent")

        guard let (orgsBody, orgsResp) = await http(orgReq),
              (200...299).contains(orgsResp.statusCode) else {
            return nil
        }
        guard let orgs = try? JSONSerialization.jsonObject(with: orgsBody) as? [[String: Any]],
              let firstOrg = orgs.first,
              let orgID = (firstOrg["uuid"] as? String) ?? (firstOrg["id"] as? String)
        else {
            return nil
        }

        // Step 2: Get usage.
        guard let usageURL = URL(string: "https://claude.ai/api/organizations/\(orgID)/usage") else {
            return nil
        }
        var usageReq = URLRequest(url: usageURL)
        usageReq.timeoutInterval = 15
        usageReq.httpMethod = "GET"
        usageReq.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        usageReq.setValue("application/json", forHTTPHeaderField: "Accept")
        usageReq.setValue("CLI-Pulse-Helper/Swift", forHTTPHeaderField: "User-Agent")

        guard let (usageBody, usageResp) = await http(usageReq),
              (200...299).contains(usageResp.statusCode) else {
            return nil
        }

        // Same response shape as OAuth — three tiers, same parser.
        // Provenance pivots from .anthropicOAuth to .anthropicWebCookie
        // so the diagnostic surface shows which path produced the data.
        let snap = Self.parseAPIResponse(
            usageBody,
            planType: "Max",   // web path doesn't have a plan-type signal; default Max
            fetchedAt: nowISO
        )
        if case .anthropicOAuth = snap.provenance {
            // Re-tag provenance to web — `parseAPIResponse` always
            // returns .anthropicOAuth on success because it can't
            // tell which path called it.
            return ProviderQuotaSnapshot(
                quota: snap.quota,
                remaining: snap.remaining,
                planType: snap.planType,
                resetTime: snap.resetTime,
                tiers: snap.tiers,
                provenance: .anthropicWebCookie,
                fetchedAt: snap.fetchedAt
            )
        }
        // Parse error — fall through.
        return nil
    }

    // MARK: - Parsing

    /// Parse the Anthropic OAuth usage JSON. The response shape is
    /// `{"five_hour": {"used_percentage": N, "resets_at_iso": "..."}, "weekly_*": ..., "weekly_opus": ...}`.
    /// We translate to our percentage-based tier model.
    static func parseAPIResponse(
        _ body: Data,
        planType: String,
        fetchedAt: String
    ) -> ProviderQuotaSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return unavailable(reason: "parse_error", fetchedAt: fetchedAt)
        }
        var tiers: [ProviderQuotaTier] = []
        for (key, label) in [
            ("five_hour", "5h Window"),
            ("weekly_all", "Weekly"),
            ("weekly_opus", "Opus only"),
        ] {
            if let block = dict[key] as? [String: Any],
               let usedAny = block["used_percentage"] {
                let used: Double
                if let d = usedAny as? Double { used = d }
                else if let i = usedAny as? Int { used = Double(i) }
                else { continue }
                let remaining = max(0, 100 - Int(used))
                let resetIso = block["resets_at_iso"] as? String
                tiers.append(ProviderQuotaTier(
                    name: label,
                    quota: 100,
                    remaining: remaining,
                    resetTime: resetIso
                ))
            }
        }
        guard let primary = tiers.first else {
            return unavailable(reason: "no_tiers", fetchedAt: fetchedAt)
        }
        return ProviderQuotaSnapshot(
            quota: primary.quota,
            remaining: primary.remaining,
            planType: planType,
            resetTime: primary.resetTime,
            tiers: tiers,
            provenance: .anthropicOAuth,
            fetchedAt: fetchedAt
        )
    }

    static func unavailable(reason: String, fetchedAt: String) -> ProviderQuotaSnapshot {
        return ProviderQuotaSnapshot(
            quota: 0,
            remaining: 0,
            planType: nil,
            resetTime: nil,
            tiers: [],
            provenance: .unavailable(reason: reason),
            fetchedAt: fetchedAt
        )
    }

    /// `expiresAt` / `expires_at` may be epoch seconds OR epoch
    /// milliseconds depending on which Claude CLI version persisted
    /// it. Heuristic: > 1e12 → ms, else seconds.
    static func normalizedExpiry(from oauth: [String: Any]) -> TimeInterval? {
        let raw = oauth["expiresAt"] ?? oauth["expires_at"]
        let value: Double
        if let d = raw as? Double { value = d }
        else if let i = raw as? Int { value = Double(i) }
        else { return nil }
        if value <= 0 { return nil }
        return value > 1e12 ? value / 1000.0 : value
    }

    // MARK: - Live HTTP

    /// Default HTTP hook using `URLSession.shared`. Tests inject a
    /// closure that returns canned `(Data, HTTPURLResponse)` tuples.
    @Sendable
    public static func liveHTTP(_ request: URLRequest) async -> (Data, HTTPURLResponse)? {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            return (data, http)
        } catch {
            return nil
        }
    }
}
