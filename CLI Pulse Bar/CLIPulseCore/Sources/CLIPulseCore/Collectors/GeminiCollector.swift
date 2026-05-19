#if os(macOS)
import Foundation

/// v1.16 §2.2: 15-minute backoff for repeated refresh failures so we
/// don't spam the log on every collector tick when the user's
/// refresh_token is also expired ("Gemini failed: token expired" used
/// to fire every ~30s).
///
/// First failure: logged normally + starts the backoff window.
/// Subsequent failures within the window: thrown silently (suppressed
/// by the collector dispatcher).
/// User-side recovery: when the user reconnects via the macOS OAuth
/// UI, the next collect() call sees fresh non-expired creds, skips the
/// refresh path entirely, and `recordSuccess` clears the backoff. So
/// fixing the credentials self-heals within one collector tick (~30s)
/// without any explicit reset hook.
///
/// Why 15min and not 1h: per Gemini slice review — 1h was too punitive
/// when transient network errors caused a refresh failure on
/// already-valid tokens. 15min still suppresses ~30 ticks of per-tick
/// spam while letting users see the error again if they're actively
/// debugging.
actor GeminiRefreshBackoff {
    static let shared = GeminiRefreshBackoff()
    private var lastFailureAt: [GeminiCollector.TokenSource: Date] = [:]
    private let backoffWindow: TimeInterval = 900  // 15 minutes

    func shouldSuppressFailure(source: GeminiCollector.TokenSource) -> Bool {
        guard let last = lastFailureAt[source] else { return false }
        return Date().timeIntervalSince(last) < backoffWindow
    }

    func recordFailure(source: GeminiCollector.TokenSource) {
        lastFailureAt[source] = Date()
    }

    func recordSuccess(source: GeminiCollector.TokenSource) {
        lastFailureAt.removeValue(forKey: source)
    }
}

/// Fetches real per-model quota data from Google Gemini via OAuth credentials.
///
/// Auth priority:
///   1. Keychain — CLI Pulse's own OAuth tokens (via GeminiOAuthManager)
///   2. File — `~/.gemini/oauth_creds.json` (Gemini CLI compatibility fallback)
///
/// Quota: `POST https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota`
/// Tier:  `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist`
public struct GeminiCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.gemini

    public func isAvailable(config: ProviderConfig) -> Bool {
        let creds = readCredentials()
        return creds?.accessToken != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard var creds = readCredentials(), creds.accessToken != nil else {
            // v1.23.0 G3: dark/opt-in CLI-probe fallback for the
            // no-credentials gap. Returns nil instantly (probe never
            // constructed) unless explicitly opted in; any probe error
            // is swallowed so this throw path stays byte-identical.
            if let probed = await probeFallbackResult(config: config) { return probed }
            throw CollectorError.missingCredentials("Gemini: no credentials found")
        }

        // Refresh if expired
        if creds.isExpired {
            if let refreshed = try? await refreshToken(creds: creds) {
                creds = refreshed
                // Only persist back to file for file-sourced credentials
                if creds.source == .file { persistCredentials(creds) }
                await GeminiRefreshBackoff.shared.recordSuccess(source: creds.source)
            } else if creds.source == .keychain {
                // Keychain refresh failed — fall back to file credentials
                if let fileCreds = readFileCredentials(), !fileCreds.isExpired {
                    creds = fileCreds
                    await GeminiRefreshBackoff.shared.recordSuccess(source: .file)
                }
            }
        }

        guard let token = creds.accessToken, !creds.isExpired else {
            // v1.23.0 G3: try the dark/opt-in CLI-probe fallback BEFORE
            // recording a failure — a probe rescue is not a failure.
            // nil when opted-out (dark) or on any probe error, so the
            // backoff state machine below stays byte-identical.
            if let probed = await probeFallbackResult(config: config) { return probed }
            // v1.16 §2.2: backoff to avoid log spam every collector tick.
            // First failure for this source emits the normal error;
            // subsequent failures within 1h are silently suppressed
            // (rendered as a CollectorError.silent that the collector
            // dispatcher treats as "skip this tick, no log").
            let suppressed = await GeminiRefreshBackoff.shared.shouldSuppressFailure(source: creds.source)
            if !suppressed {
                await GeminiRefreshBackoff.shared.recordFailure(source: creds.source)
                throw CollectorError.missingCredentials("Gemini: token expired — reconnect via CLI Pulse OAuth")
            } else {
                throw CollectorError.silentBackoff("Gemini: token expired (silenced for 1h after first error)")
            }
        }
        // Reset backoff on successful token use.
        await GeminiRefreshBackoff.shared.recordSuccess(source: creds.source)

        // Fetch tier info for plan detection
        let tierInfo = try? await fetchTierInfo(token: token)

        // Discover project ID
        let projectId = tierInfo?.projectId

        // Fetch quota buckets
        let buckets = try await fetchQuota(token: token, projectId: projectId)

        return buildResult(buckets: buckets, tierInfo: tierInfo)
    }

    // MARK: - Credentials

    enum TokenSource: Sendable, Hashable { case keychain, file }

    struct GeminiCreds {
        var accessToken: String?
        var refreshToken: String?
        var idToken: String?
        var expiryDate: Date?
        var source: TokenSource = .file

        var isExpired: Bool {
            guard let exp = expiryDate else { return true }
            return exp < Date()
        }
    }

    private func credsPath() -> String {
        (realUserHome() as NSString).appendingPathComponent(".gemini/oauth_creds.json")
    }

    func readCredentials() -> GeminiCreds? {
        // Priority 1: Keychain tokens (CLI Pulse's own OAuth flow)
        if let stored = GeminiOAuthManager.shared.loadTokens() {
            return GeminiCreds(
                accessToken: stored.accessToken,
                refreshToken: stored.refreshToken,
                expiryDate: stored.expiry,
                source: .keychain
            )
        }

        // Priority 2: Gemini CLI's credential file (compatibility fallback)
        return readFileCredentials()
    }

    /// Read credentials from `~/.gemini/oauth_creds.json` only.
    private func readFileCredentials() -> GeminiCreds? {
        let path = credsPath()
        guard let data = SandboxFileAccess.read(path: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var creds = GeminiCreds(source: .file)
        creds.accessToken = json["access_token"] as? String
        creds.refreshToken = json["refresh_token"] as? String
        creds.idToken = json["id_token"] as? String
        if let expMs = (json["expiry_date"] as? NSNumber)?.doubleValue {
            creds.expiryDate = Date(timeIntervalSince1970: expMs / 1000.0)
        }
        return creds
    }

    private func persistCredentials(_ creds: GeminiCreds) {
        let path = credsPath()
        guard let existingData = FileManager.default.contents(atPath: path),
              var json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] else { return }
        if let at = creds.accessToken { json["access_token"] = at }
        if let it = creds.idToken { json["id_token"] = it }
        if let exp = creds.expiryDate { json["expiry_date"] = Int64(exp.timeIntervalSince1970 * 1000) }
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Token refresh

    private func refreshToken(creds: GeminiCreds) async throws -> GeminiCreds {
        switch creds.source {
        case .keychain:
            // Refresh via CLI Pulse's own OAuth client (PKCE, no secret needed)
            let newToken = try await GeminiOAuthManager.shared.refreshAccessToken()
            var updated = creds
            updated.accessToken = newToken
            // Reload expiry from Keychain after refresh
            if let stored = GeminiOAuthManager.shared.loadTokens() {
                updated.expiryDate = stored.expiry
            }
            return updated

        case .file:
            // File-based tokens from Gemini CLI cannot be refreshed without the CLI's
            // client credentials. User should connect via CLI Pulse OAuth instead.
            throw CollectorError.missingCredentials(
                "Gemini: file-based token expired — connect via CLI Pulse OAuth to enable auto-refresh"
            )
        }
    }

    // MARK: - Tier info

    struct TierInfo {
        let tierId: String?  // "free-tier", "standard-tier", "legacy-tier"
        let projectId: String?
    }

    private func fetchTierInfo(token: String) async throws -> TierInfo {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist") else {
            throw CollectorError.invalidURL("loadCodeAssist")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": ["ideType": "GEMINI_CLI", "pluginType": "GEMINI"]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Gemini")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Gemini loadCodeAssist: invalid JSON")
        }

        let tier = (json["currentTier"] as? [String: Any])?["id"] as? String
        var projectId: String? = nil
        if let proj = json["cloudaicompanionProject"] as? String {
            projectId = proj
        } else if let projObj = json["cloudaicompanionProject"] as? [String: Any] {
            projectId = projObj["projectId"] as? String ?? projObj["id"] as? String
        }

        return TierInfo(tierId: tier, projectId: projectId)
    }

    // MARK: - Quota API

    struct QuotaBucket: Sendable {
        let modelId: String
        let remainingFraction: Double  // 0.0 to 1.0
        let resetTime: String?
    }

    private func fetchQuota(token: String, projectId: String?) async throws -> [QuotaBucket] {
        guard let url = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota") else {
            throw CollectorError.invalidURL("retrieveUserQuota")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        var body: [String: Any] = [:]
        if let pid = projectId { body["project"] = pid }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Gemini")
        }

        return try GeminiCollector.parseQuota(data)
    }

    // MARK: - Parsing (internal for testing)

    static func parseQuota(_ data: Data) throws -> [QuotaBucket] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buckets = json["buckets"] as? [[String: Any]] else {
            throw CollectorError.parseFailed("Gemini quota: no buckets array")
        }

        // Global resetTime fallback (some responses put it at root level)
        let globalResetTime = json["resetTime"] as? String
            ?? json["reset_time"] as? String
            ?? json["quotaResetTime"] as? String

        return buckets.compactMap { b in
            guard let modelId = b["modelId"] as? String else { return nil }
            let fraction = (b["remainingFraction"] as? NSNumber)?.doubleValue ?? 1.0
            // Google API may use different key names for reset time
            let resetTime = b["resetTime"] as? String
                ?? b["reset_time"] as? String
                ?? b["resetAt"] as? String
                ?? b["quotaResetTime"] as? String
                ?? globalResetTime
            return QuotaBucket(modelId: modelId, remainingFraction: fraction, resetTime: resetTime)
        }
    }

    // MARK: - Result building

    func buildResult(buckets: [QuotaBucket], tierInfo: TierInfo?) -> CollectorResult {
        // Group by model family, keep lowest remaining fraction per family
        var familyBest: [String: (fraction: Double, resetTime: String?)] = [:]

        for bucket in buckets {
            let family = classifyModel(bucket.modelId)
            if let existing = familyBest[family] {
                if bucket.remainingFraction < existing.fraction {
                    familyBest[family] = (bucket.remainingFraction, bucket.resetTime)
                }
            } else {
                familyBest[family] = (bucket.remainingFraction, bucket.resetTime)
            }
        }

        let preferredOrder = ["Pro", "Flash", "Flash Lite"]
        var tiers: [TierDTO] = []
        for family in preferredOrder {
            guard let info = familyBest[family] else { continue }
            let percentLeft = Int(info.fraction * 100)
            tiers.append(TierDTO(
                name: family,
                quota: 100,
                remaining: max(0, percentLeft),
                reset_time: info.resetTime
            ))
        }
        for family in familyBest.keys.sorted() where !preferredOrder.contains(family) {
            guard let info = familyBest[family] else { continue }
            let percentLeft = Int(info.fraction * 100)
            tiers.append(TierDTO(
                name: family,
                quota: 100,
                remaining: max(0, percentLeft),
                reset_time: info.resetTime
            ))
        }

        // Plan type from tier ID
        let planType: String
        switch tierInfo?.tierId {
        case "standard-tier": planType = "Paid"
        case "free-tier": planType = "Free"
        case "legacy-tier": planType = "Legacy"
        default: planType = "Unknown"
        }

        // Overall: match CodexBar semantics by treating Pro as the primary Gemini window,
        // then Flash, then Flash Lite as fallback when Pro is unavailable.
        let primaryFamily = preferredOrder.first(where: { familyBest[$0] != nil })
        let primary = primaryFamily.flatMap { familyBest[$0] }
        let overallRemaining = primary.map { Int($0.fraction * 100) }
            ?? familyBest.values.map { Int($0.fraction * 100) }.min()
            ?? 100
        let overallReset = primary?.resetTime
            ?? familyBest.values.compactMap(\.resetTime).first

        let usage = ProviderUsage(
            provider: ProviderKind.gemini.rawValue,
            today_usage: 100 - overallRemaining,
            week_usage: 100 - overallRemaining,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: 100,
            remaining: overallRemaining,
            plan_type: planType,
            reset_time: overallReset,
            tiers: tiers,
            status_text: "\(100 - overallRemaining)% used",
            trend: [],
            recent_sessions: [],
            recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Gemini",
                category: "cloud",
                supports_exact_cost: false,
                supports_quota: true
            )
        )

        return CollectorResult(usage: usage, dataKind: .quota)
    }

    // MARK: - G3 dark/opt-in CLI-probe fallback (v1.23.0 CodexBar parity)

    /// Returns nil instantly (the probe is never even constructed)
    /// unless this Gemini config explicitly opted into the fallback.
    /// ANY probe error — App-Sandbox/POSIX failures from its
    /// subprocess+filesystem OAuth-client discovery, network, or
    /// `.unsupportedAuthType` — is swallowed and nil returned, so the
    /// caller's pre-existing failure/backoff path runs byte-identically
    /// (Gemini 3.1 Pro R1 CRITICAL). The probe only ever upgrades a
    /// credential-gap failure into a success; it never alters the
    /// failure path. Triggered solely at the no-creds / unrefreshable-
    /// token gaps — never on transient network errors of the primary
    /// path (so we don't double-hit Google or mask outages).
    private func probeFallbackResult(config: ProviderConfig) async -> CollectorResult? {
        guard config.geminiCliProbeFallback == true else { return nil }
        do {
            let probe = GeminiStatusProbe(homeDirectory: realUserHome())
            let snapshot = try await probe.fetch()
            return mapSnapshot(snapshot)
        } catch {
            return nil
        }
    }

    /// Maps a `GeminiStatusProbe` snapshot onto the SAME ProviderUsage
    /// shape `buildResult` produces from the primary path, so toggling
    /// the dark fallback never visibly jumps the displayed numbers
    /// (Gemini R1 Q3). NOTE: `GeminiModelQuota.percentLeft` is already
    /// 0–100 — it is NOT ×100 again here, unlike the fraction-based
    /// primary `QuotaBucket` path (Gemini R1 HIGH scale trap).
    func mapSnapshot(_ snap: GeminiStatusSnapshot) -> CollectorResult {
        var familyBest: [String: (percent: Int, reset: String?)] = [:]
        for q in snap.modelQuotas {
            let family = classifyModel(q.modelId)
            let percent = max(0, min(100, Int(q.percentLeft.rounded())))
            // Prefer the canonical ISO form (round-trips through
            // sharedISO8601Parse — matches the primary path and the G4
            // pace engine); fall back to the probe's textual reset.
            let reset = q.resetTime.map { sharedISO8601Formatter.string(from: $0) } ?? q.resetDescription
            if let existing = familyBest[family] {
                if percent < existing.percent { familyBest[family] = (percent, reset) }
            } else {
                familyBest[family] = (percent, reset)
            }
        }

        let preferredOrder = ["Pro", "Flash", "Flash Lite"]
        var tiers: [TierDTO] = []
        for family in preferredOrder {
            guard let info = familyBest[family] else { continue }
            tiers.append(TierDTO(name: family, quota: 100, remaining: info.percent, reset_time: info.reset))
        }
        for family in familyBest.keys.sorted() where !preferredOrder.contains(family) {
            guard let info = familyBest[family] else { continue }
            tiers.append(TierDTO(name: family, quota: 100, remaining: info.percent, reset_time: info.reset))
        }

        let primaryFamily = preferredOrder.first(where: { familyBest[$0] != nil })
        let primary = primaryFamily.flatMap { familyBest[$0] }
        let overallRemaining = primary?.percent
            ?? familyBest.values.map(\.percent).min()
            ?? 100
        let overallReset = primary?.reset ?? familyBest.values.compactMap(\.reset).first

        let usage = ProviderUsage(
            provider: ProviderKind.gemini.rawValue,
            today_usage: 100 - overallRemaining,
            week_usage: 100 - overallRemaining,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: 100,
            remaining: overallRemaining,
            plan_type: normalizePlan(snap.accountPlan),
            reset_time: overallReset,
            tiers: tiers,
            status_text: "\(100 - overallRemaining)% used",
            trend: [],
            recent_sessions: [],
            recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Gemini",
                category: "cloud",
                supports_exact_cost: false,
                supports_quota: true
            )
        )
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    /// Normalizes the probe's free-form account plan onto the same
    /// vocabulary `buildResult` derives from the tier id (Paid / Free /
    /// Legacy / Unknown) so the plan badge is consistent across both
    /// paths (Gemini R1 Q3). No tier info ⇒ "Unknown" (acceptable;
    /// only ever reached in the opt-in fallback).
    func normalizePlan(_ raw: String?) -> String {
        guard let p = raw?.lowercased(), !p.isEmpty else { return "Unknown" }
        if p.contains("standard") || p.contains("paid") { return "Paid" }
        if p.contains("free") { return "Free" }
        if p.contains("legacy") { return "Legacy" }
        return "Unknown"
    }

    private func classifyModel(_ modelId: String) -> String {
        let lower = modelId.lowercased()
        if lower.contains("flash-lite") || lower.contains("flash_lite") { return "Flash Lite" }
        if lower.contains("flash") { return "Flash" }
        if lower.contains("pro") { return "Pro" }
        return modelId  // Unknown model, use raw ID
    }
}
#endif
