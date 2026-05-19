// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/VertexAI/VertexAIOAuth/
// {VertexAIOAuthCredentials,VertexAITokenRefresher,VertexAIUsageFetcher}.swift
// (https://github.com/steipete/CodexBar). The credential parse, token
// refresh, and Cloud-Monitoring quota aggregation are ported; the
// fetch path is reimplemented on URLSession and made App-Sandbox-safe.
//
// CodexBar-parity Phase B-2 — promote the Vertex AI stub to a real
// `.quota` collector (gcloud Application Default Credentials, user-
// credential path only).
//
// Divergences from upstream (sandbox + app-fit):
//   * `realUserHome()` + `SandboxFileAccess.read` instead of
//     `FileManager.homeDirectoryForCurrentUser` / `Data(contentsOf:)`
//     — a sandboxed GUI app's home is the container, and its
//     `ProcessInfo.environment` does NOT inherit the shell, so the
//     real `~/.config/gcloud/...` path is the one actually used.
//   * Service-account credentials (private_key) are NOT supported:
//     they require a `gcloud … print-access-token` subprocess which
//     the App Sandbox blocks — we throw a clear message instead.
//   * `URLSession` instead of CodexBar's `ProviderHTTPClient`; no
//     CodexBarLog; no DEBUG TaskLocal.
//   * Gemini Phase-B2 R1 CRITICAL: an `actor` token cache survives
//     across collector ticks so we don't hit the OAuth token endpoint
//     every ~30s.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import Foundation

/// In-memory cache of the last refreshed Vertex AI credentials so a
/// ~30s collector tick doesn't re-read an expired on-disk token and
/// re-hit oauth2.googleapis.com every time (Gemini Phase-B2 R1
/// CRITICAL). Single ADC account ⇒ one slot.
actor VertexAITokenCache {
    static let shared = VertexAITokenCache()
    private var creds: VertexAICollector.Creds?

    func current() -> VertexAICollector.Creds? { creds }
    func store(_ c: VertexAICollector.Creds) { creds = c }
}

/// Fetches Vertex AI quota usage via gcloud Application Default
/// Credentials (`gcloud auth application-default login`).
///
/// Creds: `~/.config/gcloud/application_default_credentials.json`
/// Quota: 2× `GET monitoring.googleapis.com/v3/projects/{p}/timeSeries`
public struct VertexAICollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.vertexAI

    public struct Creds: Sendable {
        let accessToken: String
        let refreshToken: String
        let clientId: String
        let clientSecret: String
        let projectId: String?
        let email: String?
        let expiryDate: Date?

        /// Refresh 5 minutes before expiry (verbatim).
        var needsRefresh: Bool {
            guard let expiryDate else { return true }
            return Date().addingTimeInterval(300) > expiryDate
        }
    }

    // MARK: - File path resolution (real home; env is nil under sandbox GUI)

    private static func credentialsPath(_ env: [String: String]) -> String {
        if let p = env["GOOGLE_APPLICATION_CREDENTIALS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            return p
        }
        if let dir = env["CLOUDSDK_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
            return (dir as NSString).appendingPathComponent("application_default_credentials.json")
        }
        return (realUserHome() as NSString)
            .appendingPathComponent(".config/gcloud/application_default_credentials.json")
    }

    private static func projectConfigPath(_ env: [String: String]) -> String {
        if let dir = env["CLOUDSDK_CONFIG"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !dir.isEmpty {
            return (dir as NSString).appendingPathComponent("configurations/config_default")
        }
        return (realUserHome() as NSString)
            .appendingPathComponent(".config/gcloud/configurations/config_default")
    }

    // MARK: - Availability (lightweight — no full JSON decode)

    public func isAvailable(config: ProviderConfig) -> Bool {
        let env = ProcessInfo.processInfo.environment
        return FileManager.default.fileExists(atPath: Self.credentialsPath(env))
    }

    // MARK: - Collect

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let env = ProcessInfo.processInfo.environment

        var creds: Creds
        if let cached = await VertexAITokenCache.shared.current(), !cached.needsRefresh {
            creds = cached
        } else {
            guard let data = SandboxFileAccess.read(path: Self.credentialsPath(env)) else {
                throw CollectorError.missingCredentials(
                    "Vertex AI: gcloud ADC not found — run `gcloud auth application-default login`")
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CollectorError.parseFailed("Vertex AI: invalid ADC JSON")
            }
            if Self.isServiceAccount(json) {
                throw CollectorError.missingCredentials(
                    "Vertex AI: service-account credentials require the gcloud CLI "
                    + "(not available in sandbox) — run `gcloud auth application-default login`")
            }
            creds = try Self.parseUserCredentials(json: json, env: env)
            if creds.needsRefresh {
                creds = try await Self.refresh(creds)
            }
            await VertexAITokenCache.shared.store(creds)
        }

        guard let projectId = creds.projectId, !projectId.isEmpty else {
            throw CollectorError.missingCredentials(
                "Vertex AI: no GCP project — run `gcloud config set project PROJECT_ID`")
        }

        let pct = try await Self.fetchUsedPercent(accessToken: creds.accessToken, projectId: projectId)
        return buildResult(usedPercent: pct, email: creds.email)
    }

    // MARK: - Credential parsing (vendored, adjusted)

    static func isServiceAccount(_ json: [String: Any]) -> Bool {
        let email = (json["client_email"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let key = (json["private_key"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !email.isEmpty && !key.isEmpty
    }

    static func parseUserCredentials(json: [String: Any], env: [String: String]) throws -> Creds {
        guard let clientId = json["client_id"] as? String,
              let clientSecret = json["client_secret"] as? String else {
            throw CollectorError.missingCredentials("Vertex AI: ADC missing client_id/secret")
        }
        guard let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CollectorError.missingCredentials("Vertex AI: ADC has no refresh_token")
        }
        let accessToken = json["access_token"] as? String ?? ""
        var expiry: Date?
        if let expiryStr = json["token_expiry"] as? String {
            expiry = ISO8601DateFormatter().date(from: expiryStr)
        }
        return Creds(
            accessToken: accessToken,
            refreshToken: refreshToken,
            clientId: clientId,
            clientSecret: clientSecret,
            projectId: Self.resolveProjectId(env: env),
            email: Self.extractEmailFromIdToken(json["id_token"] as? String),
            expiryDate: expiry)
    }

    static func resolveProjectId(env: [String: String]) -> String? {
        if let content = SandboxFileAccess.read(path: Self.projectConfigPath(env))
            .flatMap({ String(data: $0, encoding: .utf8) }),
            let fromINI = Self.parseProjectIdINI(content) {
            return fromINI
        }
        return env["GOOGLE_CLOUD_PROJECT"]
            ?? env["GCLOUD_PROJECT"]
            ?? env["CLOUDSDK_CORE_PROJECT"]
    }

    /// Pure INI scan for the gcloud `project = …` line (testable).
    static func parseProjectIdINI(_ content: String) -> String? {
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("project") {
                let parts = trimmed.components(separatedBy: "=")
                if parts.count >= 2 {
                    let p = parts[1].trimmingCharacters(in: .whitespaces)
                    if !p.isEmpty { return p }
                }
            }
        }
        return nil
    }

    static func extractEmailFromIdToken(_ token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    // MARK: - Token refresh (vendored, URLSession)

    static func refresh(_ c: Creds) async throws -> Creds {
        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw CollectorError.invalidURL("oauth2 token")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "client_id": c.clientId, "client_secret": c.clientSecret,
            "refresh_token": c.refreshToken, "grant_type": "refresh_token",
        ].map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400 || status == 401 {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CollectorError.missingCredentials(
                "Vertex AI: token refresh failed (\(code ?? "expired")) — "
                + "run `gcloud auth application-default login` again")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "Vertex AI")
        }
        return try Self.parseRefreshResponse(data, fallback: c)
    }

    static func parseRefreshResponse(_ data: Data, fallback c: Creds) throws -> Creds {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Vertex AI: invalid refresh JSON")
        }
        let newToken = json["access_token"] as? String ?? c.accessToken
        let expiresIn = json["expires_in"] as? Double ?? 3600
        let email = Self.extractEmailFromIdToken(json["id_token"] as? String) ?? c.email
        return Creds(
            accessToken: newToken, refreshToken: c.refreshToken,
            clientId: c.clientId, clientSecret: c.clientSecret,
            projectId: c.projectId, email: email,
            expiryDate: Date().addingTimeInterval(expiresIn))
    }

    // MARK: - Cloud Monitoring quota fetch (vendored, URLSession)

    struct TimeSeriesResponse: Decodable {
        let timeSeries: [Series]?
        let nextPageToken: String?
        struct Series: Decodable {
            let metric: Labels
            let resource: Labels
            let points: [Point]
        }
        struct Labels: Decodable { let labels: [String: String]? }
        struct Point: Decodable { let value: Value }
        struct Value: Decodable { let doubleValue: Double?; let int64Value: String? }
    }

    /// Decode a Cloud-Monitoring timeSeries page (testable).
    static func parseTimeSeries(_ data: Data) throws -> [TimeSeriesResponse.Series] {
        do {
            return try JSONDecoder().decode(TimeSeriesResponse.self, from: data).timeSeries ?? []
        } catch {
            throw CollectorError.parseFailed("Vertex AI: \(error.localizedDescription)")
        }
    }

    /// max(usage/limit*100) over matched quota keys (testable).
    static func maxPercent(usage: [QuotaKey: Double], limit: [QuotaKey: Double]) -> Double? {
        var maxPercent: Double?
        for (key, lim) in limit where lim > 0 {
            guard let u = usage[key] else { continue }
            let p = (u / lim) * 100.0
            maxPercent = max(maxPercent ?? p, p)
        }
        return maxPercent
    }

    struct QuotaKey: Hashable { let metric: String; let limit: String; let location: String }

    private static let monitoringBase = "https://monitoring.googleapis.com/v3/projects"
    private static let windowSeconds: TimeInterval = 24 * 60 * 60

    static func fetchUsedPercent(accessToken: String, projectId: String) async throws -> Double {
        let usageFilter = "metric.type=\"serviceruntime.googleapis.com/quota/allocation/usage\" "
            + "AND resource.type=\"consumer_quota\" "
            + "AND resource.label.service=\"aiplatform.googleapis.com\""
        let limitFilter = "metric.type=\"serviceruntime.googleapis.com/quota/limit\" "
            + "AND resource.type=\"consumer_quota\" "
            + "AND resource.label.service=\"aiplatform.googleapis.com\""

        let usage = Self.aggregate(try await Self.fetchSeries(
            accessToken: accessToken, projectId: projectId, filter: usageFilter))
        let limit = Self.aggregate(try await Self.fetchSeries(
            accessToken: accessToken, projectId: projectId, filter: limitFilter))

        guard !usage.isEmpty, !limit.isEmpty else {
            throw CollectorError.parseFailed("Vertex AI: no quota data for this project")
        }
        guard let pct = Self.maxPercent(usage: usage, limit: limit) else {
            throw CollectorError.parseFailed("Vertex AI: no matched quota series")
        }
        return pct
    }

    private static func fetchSeries(
        accessToken: String, projectId: String, filter: String) async throws -> [TimeSeriesResponse.Series] {
        let now = Date()
        let start = now.addingTimeInterval(-Self.windowSeconds)
        let iso = ISO8601DateFormatter()
        var pageToken: String?
        var all: [TimeSeriesResponse.Series] = []
        repeat {
            guard var comps = URLComponents(string: "\(Self.monitoringBase)/\(projectId)/timeSeries") else {
                throw CollectorError.invalidURL("monitoring timeSeries")
            }
            var items = [
                URLQueryItem(name: "filter", value: filter),
                URLQueryItem(name: "interval.startTime", value: iso.string(from: start)),
                URLQueryItem(name: "interval.endTime", value: iso.string(from: now)),
                URLQueryItem(name: "aggregation.alignmentPeriod", value: "3600s"),
                URLQueryItem(name: "aggregation.perSeriesAligner", value: "ALIGN_MAX"),
                URLQueryItem(name: "view", value: "FULL"),
            ]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            guard let url = comps.url else {
                throw CollectorError.invalidURL("monitoring timeSeries")
            }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else {
                throw CollectorError.httpError(status: status, provider: "Vertex AI")
            }
            let decoded = try JSONDecoder().decode(TimeSeriesResponse.self, from: data)
            if let s = decoded.timeSeries { all.append(contentsOf: s) }
            pageToken = (decoded.nextPageToken?.isEmpty == false) ? decoded.nextPageToken : nil
        } while pageToken != nil
        return all
    }

    static func aggregate(_ series: [TimeSeriesResponse.Series]) -> [QuotaKey: Double] {
        var buckets: [QuotaKey: Double] = [:]
        for s in series {
            let m = s.metric.labels ?? [:]
            let r = s.resource.labels ?? [:]
            guard let metric = (m["quota_metric"] ?? r["quota_id"]), !metric.isEmpty else { continue }
            let key = QuotaKey(
                metric: metric, limit: m["limit_name"] ?? "", location: r["location"] ?? "global")
            let maxVal = s.points.compactMap { p -> Double? in
                if let d = p.value.doubleValue { return d }
                if let i = p.value.int64Value { return Double(i) }
                return nil
            }.max()
            guard let v = maxVal else { continue }
            buckets[key] = max(buckets[key] ?? 0, v)
        }
        return buckets
    }

    // MARK: - Result building

    func buildResult(usedPercent: Double, email: String?) -> CollectorResult {
        let pct = max(0, min(100, Int(usedPercent.rounded())))
        let usage = ProviderUsage(
            provider: ProviderKind.vertexAI.rawValue,
            today_usage: pct, week_usage: pct,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: 100 - pct,
            plan_type: email ?? "Vertex AI",
            reset_time: nil,
            tiers: [TierDTO(name: "Requests", quota: 100, remaining: 100 - pct, reset_time: nil)],
            status_text: "\(pct)% used",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Vertex AI", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
