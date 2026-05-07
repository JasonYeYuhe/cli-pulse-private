import Foundation

/// Fetches Gemini usage via Google Cloud Code's `retrieveUserQuota`
/// endpoint. Reads OAuth token from CLI Pulse's own creds path
/// (preferred) or Gemini CLI's compat path (fallback).
///
/// Phase 4E Slice 2c — port of `_fetch_gemini_usage` +
/// `_load_gemini_token`. Token refresh path is **deferred to Slice
/// 2c.5**: an expired token returns `.unavailable(reason:
/// "gemini_expired")` rather than auto-refreshing. Most users keep a
/// fresh token from the macOS app's OAuth flow, so the no-refresh
/// path covers the happy case.
public actor GeminiQuotaFetcher {

    public typealias HTTPHook = @Sendable (URLRequest) async -> (Data, HTTPURLResponse)?
    public typealias FileLoader = @Sendable (URL) async -> Data?

    private let primaryCredsPath: URL
    private let fallbackCredsPath: URL
    private let http: HTTPHook
    private let fileLoader: FileLoader
    private let now: @Sendable () -> Date

    public init(
        primaryCredsPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/clipulse/gemini_tokens.json"),
        fallbackCredsPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini/oauth_creds.json"),
        http: @escaping HTTPHook = ClaudeQuotaFetcher.liveHTTP,
        fileLoader: @escaping FileLoader = { url in
            try? Data(contentsOf: url)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.primaryCredsPath = primaryCredsPath
        self.fallbackCredsPath = fallbackCredsPath
        self.http = http
        self.fileLoader = fileLoader
        self.now = now
    }

    public func fetch() async -> ProviderQuotaSnapshot {
        let formatter = SessionDetector.makeISOFormatter()
        let nowDate = now()
        let nowISO = formatter.string(from: nowDate)

        // Step 1: Load token (primary then fallback path).
        var token: String? = nil
        if let data = await fileLoader(primaryCredsPath) {
            token = Self.readTokenIfFresh(data, now: nowDate)
        }
        if token == nil, let data = await fileLoader(fallbackCredsPath) {
            token = Self.readTokenIfFresh(data, now: nowDate)
        }
        guard let token = token else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "gemini_token_missing_or_expired", fetchedAt: nowISO
            )
        }

        // Step 2: Resolve project ID via loadCodeAssist.
        let projectID = await loadCodeAssistProject(token: token)
        // (project ID is allowed to be nil — retrieveUserQuota tolerates.)

        // Step 3: HTTP retrieveUserQuota.
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            return ClaudeQuotaFetcher.unavailable(reason: "url_construction", fetchedAt: nowISO)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CLI-Pulse-Helper/Swift", forHTTPHeaderField: "User-Agent")
        let payload: [String: Any] = projectID.map { ["projectId": $0] } ?? [:]
        req.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        guard let (body, response) = await http(req) else {
            return ClaudeQuotaFetcher.unavailable(reason: "network_error", fetchedAt: nowISO)
        }
        guard (200...299).contains(response.statusCode) else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "http_\(response.statusCode)", fetchedAt: nowISO
            )
        }
        return Self.parseQuotaResponse(body, fetchedAt: nowISO)
    }

    // MARK: - Token loading

    /// Read the OAuth creds JSON; if the access token isn't expired,
    /// return it. If expired, return nil (no refresh in this slice).
    static func readTokenIfFresh(_ data: Data, now: Date) -> String? {
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let access = (dict["access_token"] as? String) ?? ""
        if access.isEmpty { return nil }
        let expiryRaw = dict["expiry_date"] ?? dict["expires_at"]
        let expiry: TimeInterval
        if let d = expiryRaw as? Double { expiry = d }
        else if let i = expiryRaw as? Int { expiry = Double(i) }
        else {
            // No expiry recorded — assume fresh and let the API decide.
            return access
        }
        // expiry may be ms or s.
        let expirySec = expiry > 1e12 ? expiry / 1000.0 : expiry
        if now.timeIntervalSince1970 >= expirySec {
            return nil
        }
        return access
    }

    // MARK: - loadCodeAssist

    /// Resolve the project ID for retrieveUserQuota. Best-effort —
    /// returns nil if loadCodeAssist fails for any reason.
    private func loadCodeAssistProject(token: String) async -> String? {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [:] as [String: Any])
        guard let (body, response) = await http(req),
              (200...299).contains(response.statusCode),
              let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return (dict["cloudaicompanionProject"] as? String)
            ?? (dict["projectId"] as? String)
    }

    // MARK: - Parsing

    /// Parse Cloud Code retrieveUserQuota response.
    static func parseQuotaResponse(_ body: Data, fetchedAt: String) -> ProviderQuotaSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ClaudeQuotaFetcher.unavailable(reason: "parse_error", fetchedAt: fetchedAt)
        }
        // Format varies; key fields we look for: `dailyLimit`, `dailyUsed`,
        // `nextResetTimestamp`. Field names taken from observed responses
        // by the Python helper. Some quota APIs nest under `quotas.[]`.
        var dailyLimit: Int? = nil
        var dailyUsed: Int? = nil
        var resetISO: String? = nil

        if let limit = dict["dailyLimit"] as? Int { dailyLimit = limit }
        if let used = dict["dailyUsed"] as? Int { dailyUsed = used }
        if let resetTs = dict["nextResetTimestamp"] as? Double {
            resetISO = SessionDetector.makeISOFormatter().string(
                from: Date(timeIntervalSince1970: resetTs / 1000.0)
            )
        }

        if let limit = dailyLimit, limit > 0, let used = dailyUsed {
            let remainingPct = max(0, 100 - Int(Double(used) / Double(limit) * 100.0))
            let tier = ProviderQuotaTier(
                name: "Daily", quota: 100, remaining: remainingPct, resetTime: resetISO
            )
            return ProviderQuotaSnapshot(
                quota: 100,
                remaining: remainingPct,
                planType: "Pro",
                resetTime: resetISO,
                tiers: [tier],
                provenance: .googleCloudCode,
                fetchedAt: fetchedAt
            )
        }
        return ClaudeQuotaFetcher.unavailable(reason: "parse_no_quota_fields", fetchedAt: fetchedAt)
    }
}
