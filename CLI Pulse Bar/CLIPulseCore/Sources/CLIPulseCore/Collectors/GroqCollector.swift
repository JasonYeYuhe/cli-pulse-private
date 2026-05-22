// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Groq/{GroqUsageFetcher,GroqSettingsReader}.swift
// (https://github.com/steipete/CodexBar). The Prometheus query set, the
// mixed-array value decode, the scalar aggregation, and the per-minute rate
// formatting are ported; the fetch is reimplemented on URLSession and mapped
// to `.statusOnly`.
//
// CodexBar-parity Phase C-12 — add the (absent) Groq provider (the inference
// company; NOT xAI's Grok, which is deferred/not-sandbox-safe). Groq exposes a
// Prometheus metrics endpoint with throughput RATES (req/sec, tok/sec) — no
// quota/cost/balance ⇒ `.statusOnly` "X req/min · Y tok/min".
//
// Divergences from upstream:
//   * `URLSession` instead of ProviderHTTPClient; no CodexBarLog.
//   * `formatDecimal` returns "0" for exactly zero (Gemini C-12 R1 MEDIUM).
//   * 4 PromQL queries run concurrently via `async let`, each 10s timeout ⇒
//     bounded ~10s wall-clock, safe in the shared collector TaskGroup.
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

/// Reports Groq throughput rates via the Prometheus metrics endpoint.
///
/// `GET {base}/metrics/prometheus/api/v1/query?query=<PromQL>` (base from env
/// `GROQ_API_URL`, default `https://api.groq.com/v1`). Auth: `Authorization:
/// Bearer <key>` (`config.apiKey` or env `GROQ_API_KEY`). 4 rate queries →
/// `.statusOnly` "req/min · tok/min".
public struct GroqCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.groq

    static let apiKeyEnv = "GROQ_API_KEY"
    static let apiURLEnv = "GROQ_API_URL"
    static let defaultBaseURL = "https://api.groq.com/v1"
    static let requestTimeout: TimeInterval = 10

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveKey(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let key = resolveKey(config: config) else {
            throw CollectorError.missingCredentials("Groq: no API key (set GROQ_API_KEY)")
        }
        let base = Self.resolveBaseURL()
        // 4 concurrent rate queries, each 10s-bounded ⇒ total ~10s wall-clock.
        async let requests = Self.queryScalar(
            "sum(model_project_id_status_code:requests:rate5m)", key: key, base: base)
        async let tokensIn = Self.queryScalar(
            "sum(model_project_id:tokens_in:rate5m)", key: key, base: base)
        async let tokensOut = Self.queryScalar(
            "sum(model_project_id:tokens_out:rate5m)", key: key, base: base)
        async let cacheHits = Self.queryScalar(
            "sum(model_project_id:prompt_cache_hits:rate5m)", key: key, base: base)
        let r = try await requests
        let ti = try await tokensIn
        let to = try await tokensOut
        let ch = try await cacheHits
        return Self.buildResult(
            requestsPerSec: r, inputTokPerSec: ti, outputTokPerSec: to, cacheHitsPerSec: ch)
    }

    private func resolveKey(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = ProcessInfo.processInfo.environment[Self.apiKeyEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        return nil
    }

    static func resolveBaseURL() -> String {
        if let raw = ProcessInfo.processInfo.environment[apiURLEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return defaultBaseURL
    }

    // MARK: - Networking

    private static func queryScalar(_ query: String, key: String, base: String) async throws -> Double {
        guard var components = URLComponents(string: base + "/metrics/prometheus/api/v1/query") else {
            throw CollectorError.invalidURL("groq metrics")
        }
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        guard let url = components.url else { throw CollectorError.invalidURL("groq metrics query") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("Groq: unauthorized")
        }
        guard (200..<300).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "Groq")
        }
        return try parseScalar(data)
    }

    // MARK: - Parse (Prometheus instant-query envelope; mixed-array value)

    static func parseScalar(_ data: Data) throws -> Double {
        let decoded: GroqPrometheusResponse
        do {
            decoded = try JSONDecoder().decode(GroqPrometheusResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Groq: \(error.localizedDescription)")
        }
        guard decoded.status == "success" else {
            throw CollectorError.parseFailed("Groq: \(decoded.error ?? "query failed")")
        }
        // Sum the last value of each series; empty result ⇒ 0 (graceful).
        return decoded.data?.result.compactMap { $0.value?.last?.doubleValue }.reduce(0, +) ?? 0
    }

    struct GroqPrometheusResponse: Decodable {
        struct Payload: Decodable { let result: [Series] }
        struct Series: Decodable { let value: [PrometheusValue]? }

        // Prometheus `value` is a mixed array `[<unix ts: Double>, "<value: String>"]`
        // ⇒ decode each element number-or-string (Gemini C-12 R1 HIGH).
        enum PrometheusValue: Decodable {
            case number(Double)
            case string(String)
            init(from decoder: Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let n = try? c.decode(Double.self) { self = .number(n); return }
                self = try .string(c.decode(String.self))
            }
            var doubleValue: Double? {
                switch self {
                case let .number(n): return n
                case let .string(s): return Double(s)
                }
            }
        }

        let status: String
        let data: Payload?
        let error: String?
    }

    // MARK: - Result building (.statusOnly throughput rates)

    static func buildResult(
        requestsPerSec: Double, inputTokPerSec: Double,
        outputTokPerSec: Double, cacheHitsPerSec: Double) -> CollectorResult
    {
        let reqPerMin = max(0, requestsPerSec) * 60
        let tokPerMin = max(0, inputTokPerSec + outputTokPerSec) * 60
        let cachePerMin = max(0, cacheHitsPerSec) * 60

        var status = "\(formatDecimal(reqPerMin)) req/min · \(formatDecimal(tokPerMin)) tok/min"
        if cacheHitsPerSec > 0 {
            status += " · \(formatDecimal(cachePerMin)) cache/min"
        }
        let usage = ProviderUsage(
            provider: ProviderKind.groq.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            plan_type: "API key", reset_time: nil, tiers: [],
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Groq", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    /// ≥100 → 0dp, ≥10 → 1dp, else 2dp; exactly 0 → "0" (Gemini C-12 R1 MEDIUM).
    static func formatDecimal(_ value: Double) -> String {
        guard value.isFinite, value != 0 else { return "0" }
        if value >= 100 { return String(format: "%.0f", value) }
        if value >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }
}
#endif
