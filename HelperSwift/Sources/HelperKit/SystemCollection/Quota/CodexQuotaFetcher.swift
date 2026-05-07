import Foundation

/// Fetches Codex (OpenAI) usage via the WHAM rate-limit API. Reads
/// the access token from `~/.codex/auth.json` (Codex CLI's standard
/// persistence location), then GETs
/// `https://chatgpt.com/backend-api/wham/usage`.
///
/// Phase 4E Slice 2c — port of `_fetch_codex_usage` +
/// `_parse_codex_usage_response`. Token-loading is the only path
/// (no Keychain involvement; no OAuth refresh).
public actor CodexQuotaFetcher {

    public typealias HTTPHook = @Sendable (URLRequest) async -> (Data, HTTPURLResponse)?
    public typealias FileLoader = @Sendable (URL) async -> Data?

    private let authFilePath: URL
    private let http: HTTPHook
    private let fileLoader: FileLoader
    private let now: @Sendable () -> Date

    public init(
        authFilePath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"),
        http: @escaping HTTPHook = ClaudeQuotaFetcher.liveHTTP,
        fileLoader: @escaping FileLoader = { url in
            try? Data(contentsOf: url)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authFilePath = authFilePath
        self.http = http
        self.fileLoader = fileLoader
        self.now = now
    }

    public func fetch() async -> ProviderQuotaSnapshot {
        let formatter = SessionDetector.makeISOFormatter()
        let nowISO = formatter.string(from: now())

        // Step 1: Load auth.json
        guard let raw = await fileLoader(authFilePath) else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "auth_file_missing", fetchedAt: nowISO
            )
        }
        guard let outer = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "auth_parse_error", fetchedAt: nowISO
            )
        }
        let token = Self.extractAccessToken(from: outer)
        guard let token = token, !token.isEmpty else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "auth_token_missing", fetchedAt: nowISO
            )
        }

        // Step 2: HTTP
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return ClaudeQuotaFetcher.unavailable(reason: "url_construction", fetchedAt: nowISO)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("CLI-Pulse-Helper/Swift", forHTTPHeaderField: "User-Agent")

        guard let (body, response) = await http(req) else {
            return ClaudeQuotaFetcher.unavailable(reason: "network_error", fetchedAt: nowISO)
        }
        guard (200...299).contains(response.statusCode) else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "http_\(response.statusCode)", fetchedAt: nowISO
            )
        }
        return Self.parseUsageResponse(body, fetchedAt: nowISO)
    }

    /// Extract the access token from the auth.json structure. Two
    /// shapes supported: flat `tokens.access_token` or nested
    /// `tokens.<key>.access_token` (Codex versions vary).
    static func extractAccessToken(from outer: [String: Any]) -> String? {
        guard let tokens = outer["tokens"] as? [String: Any] else { return nil }
        if let flat = tokens["access_token"] as? String, !flat.isEmpty {
            return flat
        }
        for (_, value) in tokens {
            if let nested = value as? [String: Any],
               let access = nested["access_token"] as? String,
               !access.isEmpty {
                return access
            }
        }
        return nil
    }

    /// Mirrors Python `_parse_codex_usage_response`. Format:
    /// `{"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": N, ...}}}`.
    static func parseUsageResponse(_ body: Data, fetchedAt: String) -> ProviderQuotaSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ClaudeQuotaFetcher.unavailable(reason: "parse_error", fetchedAt: fetchedAt)
        }
        let planRaw = (dict["plan_type"] as? String) ?? "Plus"
        let plan = planRaw.prefix(1).uppercased() + planRaw.dropFirst().lowercased()

        var tiers: [ProviderQuotaTier] = []
        let formatter = SessionDetector.makeISOFormatter()

        if let rl = dict["rate_limit"] as? [String: Any] {
            for (key, label) in [("primary_window", "Session"), ("secondary_window", "Weekly")] {
                guard let win = rl[key] as? [String: Any] else { continue }
                let usedAny = win["used_percent"]
                let used: Double
                if let d = usedAny as? Double { used = d }
                else if let i = usedAny as? Int { used = Double(i) }
                else { continue }
                let remaining = max(0, 100 - Int(used))

                var resetISO: String? = nil
                if let resetTs = win["reset_at"] as? Double {
                    resetISO = formatter.string(from: Date(timeIntervalSince1970: resetTs))
                } else if let resetTs = win["reset_at"] as? Int {
                    resetISO = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(resetTs)))
                }
                tiers.append(ProviderQuotaTier(
                    name: label, quota: 100, remaining: remaining, resetTime: resetISO
                ))
            }
        }
        guard let primary = tiers.first else {
            return ClaudeQuotaFetcher.unavailable(reason: "no_tiers", fetchedAt: fetchedAt)
        }
        return ProviderQuotaSnapshot(
            quota: primary.quota,
            remaining: primary.remaining,
            planType: plan,
            resetTime: primary.resetTime,
            tiers: tiers,
            provenance: .openAIWham,
            fetchedAt: fetchedAt
        )
    }
}
