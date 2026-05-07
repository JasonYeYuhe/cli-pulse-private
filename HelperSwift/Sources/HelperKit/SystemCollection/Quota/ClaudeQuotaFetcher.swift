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
    private let now: @Sendable () -> Date

    public init(
        keychain: KeychainReader,
        backoff: OAuthBackoff,
        http: @escaping HTTPHook = ClaudeQuotaFetcher.liveHTTP,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.backoff = backoff
        self.http = http
        self.now = now
    }

    // MARK: - Public entry

    public func fetch() async -> ProviderQuotaSnapshot {
        let formatter = SessionDetector.makeISOFormatter()
        let nowDate = now()
        let nowISO = formatter.string(from: nowDate)

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
