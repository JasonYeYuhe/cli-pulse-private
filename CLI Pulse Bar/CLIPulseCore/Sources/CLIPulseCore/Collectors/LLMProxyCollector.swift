// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/LLMProxy/LLMProxyUsageFetcher.swift
// (https://github.com/steipete/CodexBar). The quota-stats response model
// (incl. the array-or-keyed-object `quota_groups` dual decode), the
// multi-provider aggregation, and the v1-path dedup are ported; the fetch is
// reimplemented on URLSession and mapped to `.statusOnly`.
//
// CodexBar-parity Phase C-14 — add the (absent) LLM Proxy provider: a
// SELF-HOSTED LiteLLM-style gateway. The collector hits the user's own
// deployment's quota-stats endpoint (opt-in, env-configured base URL — low
// reach but sandbox-safe).
//
// Divergences from upstream:
//   * `URLSession`; no CodexBarLog. baseURL from env `LLM_PROXY_BASE_URL`.
//   * mapped to `.statusOnly` (NOT a synthetic 100-unit quota gauge): the
//     endpoint returns a min remaining-PERCENT across many providers, and a
//     count-style quota gauge would mislabel it (Gemini C-14 R1 Q1). The %,
//     key counts, requests/tokens, and approx cost go to status_text + cost.
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

/// Fetches aggregate quota stats from a self-hosted LLM proxy.
///
/// `GET {base}/v1/quota-stats`, `Authorization: Bearer <key>`. Key from
/// `config.apiKey` or env `LLM_PROXY_API_KEY`; base from env
/// `LLM_PROXY_BASE_URL` (no default — the user's own host). Both required.
public struct LLMProxyCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.llmProxy

    static let apiKeyEnv = "LLM_PROXY_API_KEY"
    static let baseURLEnv = "LLM_PROXY_BASE_URL"

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveKey(config: config) != nil && Self.resolveBase() != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let key = resolveKey(config: config) else {
            throw CollectorError.missingCredentials("LLM Proxy: no API key (set LLM_PROXY_API_KEY)")
        }
        guard let base = Self.resolveBase(), let url = Self.quotaStatsURL(base: base) else {
            throw CollectorError.missingCredentials("LLM Proxy: no base URL (set LLM_PROXY_BASE_URL)")
        }
        let data = try await fetch(url: url, key: key)
        let stats = try Self.parseSnapshot(data)
        return Self.buildResult(stats)
    }

    private func resolveKey(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment[Self.apiKeyEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        return nil
    }

    static func resolveBase() -> String? {
        guard let raw = ProcessInfo.processInfo.environment[baseURLEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        return raw
    }

    /// `{base}/v1/quota-stats`, stripping trailing slashes and not doubling
    /// `v1` if the base already ends in it (Gemini C-14 R1 LOW).
    static func quotaStatsURL(base: String) -> URL? {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let baseURL = URL(string: trimmed) else { return nil }
        let versioned = baseURL.path.split(separator: "/").last == "v1"
            ? baseURL : baseURL.appendingPathComponent("v1")
        return versioned.appendingPathComponent("quota-stats")
    }

    private func fetch(url: URL, key: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("LLM Proxy: unauthorized")
        }
        guard (200..<300).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "LLM Proxy")
        }
        return data
    }

    // MARK: - Aggregate (testable seam)

    struct Stats: Sendable, Equatable {
        var providerCount: Int
        var totalKeys: Int
        var activeKeys: Int
        var totalRequests: Int
        var totalTokens: Int
        var approxCostUSD: Double?
        var minRemainingPercent: Double?
        var nextResetAt: Date?
    }

    static func parseSnapshot(_ data: Data) throws -> Stats {
        let resp: QuotaStatsResponse
        do {
            resp = try JSONDecoder().decode(QuotaStatsResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("LLM Proxy: \(error.localizedDescription)")
        }
        let providers = resp.providers
        let perProviderRequests = providers.values.reduce(0) { $0 + ($1.totalRequests ?? 0) }
        let perProviderTokens = providers.values.reduce(0) { $0 + $1.tokenTotal }
        let perProviderCost = providers.values.compactMap(\.approxCost).reduce(0, +)
        let groups = providers.values.flatMap { $0.quotaGroups ?? [] }

        return Stats(
            providerCount: providers.count,
            totalKeys: providers.values.reduce(0) { $0 + ($1.credentialCount ?? 0) },
            activeKeys: providers.values.reduce(0) { $0 + ($1.activeCount ?? 0) },
            // Root summary preferred (accounts for archived keys absent from
            // the providers map — Gemini C-14 R1 Q5).
            totalRequests: resp.summary?.totalRequests ?? perProviderRequests,
            totalTokens: resp.summary?.totalTokens ?? perProviderTokens,
            approxCostUSD: resp.summary?.approxCost ?? (perProviderCost > 0 ? perProviderCost : nil),
            minRemainingPercent: groups.compactMap(\.remainingPercent).min(),
            nextResetAt: groups.compactMap { parseDate($0.resetTime) }.min())
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - Result building (.statusOnly aggregate)

    static func buildResult(_ s: Stats) -> CollectorResult {
        var parts: [String] = []
        if let pct = s.minRemainingPercent {
            parts.append("\(Int(max(0, min(100, pct)).rounded()))% left")
        }
        parts.append("\(s.activeKeys)/\(s.totalKeys) keys")
        if s.totalRequests > 0 { parts.append("\(formatInt(s.totalRequests)) req") }
        if s.totalTokens > 0 { parts.append("\(formatInt(s.totalTokens)) tok") }
        let statusText = parts.joined(separator: " · ")

        let resetISO = s.nextResetAt.map { sharedISO8601Formatter.string(from: $0) }
        let cost = s.approxCostUSD
        let usage = ProviderUsage(
            provider: ProviderKind.llmProxy.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: cost ?? 0,
            cost_status_today: "Unavailable",
            cost_status_week: cost != nil ? "Estimated" : "Unavailable",
            quota: nil, remaining: nil,
            plan_type: "Self-hosted", reset_time: resetISO, tiers: [],
            status_text: statusText.isEmpty ? "Connected" : statusText,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "LLM Proxy", category: "aggregator",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    static func formatInt(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_US_POSIX")
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Vendored response model (fileprivate)

    private struct QuotaStatsResponse: Decodable {
        let providers: [String: ProviderStats]
        let summary: Summary?

        struct Summary: Decodable {
            let totalRequests: Int?
            let totalTokens: Int?
            let approxCost: Double?
            private enum CodingKeys: String, CodingKey {
                case totalRequests = "total_requests"
                case totalTokens = "total_tokens"
                case approxCost = "approx_cost"
            }
        }

        struct ProviderStats: Decodable {
            let credentialCount: Int?
            let activeCount: Int?
            let totalRequests: Int?
            let tokens: Tokens?
            let approxCost: Double?
            let quotaGroups: [QuotaGroup]?

            var tokenTotal: Int {
                (tokens?.inputCached ?? 0) + (tokens?.inputUncached ?? 0) + (tokens?.output ?? 0)
            }

            struct Tokens: Decodable {
                let inputCached: Int?
                let inputUncached: Int?
                let output: Int?
                private enum CodingKeys: String, CodingKey {
                    case inputCached = "input_cached"
                    case inputUncached = "input_uncached"
                    case output
                }
            }

            struct QuotaGroup: Decodable {
                let remainingPercent: Double?
                let resetTime: String?
                private enum CodingKeys: String, CodingKey {
                    case remainingPercent = "remaining_percent"
                    case resetTime = "reset_time"
                }
            }

            private enum CodingKeys: String, CodingKey {
                case credentialCount = "credential_count"
                case activeCount = "active_count"
                case totalRequests = "total_requests"
                case tokens
                case approxCost = "approx_cost"
                case quotaGroups = "quota_groups"
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.credentialCount = try c.decodeIfPresent(Int.self, forKey: .credentialCount)
                self.activeCount = try c.decodeIfPresent(Int.self, forKey: .activeCount)
                self.totalRequests = try c.decodeIfPresent(Int.self, forKey: .totalRequests)
                self.tokens = try c.decodeIfPresent(Tokens.self, forKey: .tokens)
                self.approxCost = try c.decodeIfPresent(Double.self, forKey: .approxCost)
                // quota_groups may be an array OR a keyed object (Gemini C-14 R1 MEDIUM).
                if let arr = try? c.decodeIfPresent([QuotaGroup].self, forKey: .quotaGroups) {
                    self.quotaGroups = arr
                } else if let keyed = try? c.decodeIfPresent([String: QuotaGroup].self, forKey: .quotaGroups) {
                    self.quotaGroups = Array(keyed.values)
                } else {
                    self.quotaGroups = nil
                }
            }
        }
    }
}
#endif
