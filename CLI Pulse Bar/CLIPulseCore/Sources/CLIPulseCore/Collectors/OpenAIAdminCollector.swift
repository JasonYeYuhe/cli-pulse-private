// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/OpenAI/{OpenAIAPIUsageFetcher,
// OpenAIAPISettingsReader}.swift (https://github.com/steipete/CodexBar). The
// `/organization/costs` query shape, the flexible amount decode, and the env
// key order are ported; the fetch is reimplemented on URLSession and reduced
// to a single month-to-date total mapped to `.statusOnly`.
//
// CodexBar-parity Phase C-15 — add the (absent) OpenAI Admin provider: the
// ORGANIZATION cost/usage admin API (DISTINCT from CLI Pulse's existing Codex =
// the OpenAI Codex CLI). Needs an org admin key (`sk-admin-`); a regular key
// 401s.
//
// Divergences from upstream:
//   * DROPS the `/usage/completions` endpoint + daily-bucket / per-model
//     machinery (~280 LOC) — CLI Pulse has no per-provider daily UI. Keeps
//     only the `/organization/costs` total, summed month-to-date (the C-10
//     Mistral simplification). Gemini C-15 R1 confirmed scope.
//   * `URLSession`; single bounded GET ⇒ no shared-TaskGroup hazard.
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

/// Fetches OpenAI organization month-to-date spend via the admin cost API.
///
/// `GET api.openai.com/v1/organization/costs?start_time&end_time&
/// bucket_width=1d&limit=31`, `Authorization: Bearer <admin key>`. Key from
/// `config.apiKey` or env `OPENAI_ADMIN_KEY` / `OPENAI_API_KEY`.
public struct OpenAIAdminCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.openaiAdmin

    static let envVars = ["OPENAI_ADMIN_KEY", "OPENAI_API_KEY"]
    static let costsURL = "https://api.openai.com/v1/organization/costs"

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveKey(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let key = resolveKey(config: config) else {
            throw CollectorError.missingCredentials("OpenAI Admin: no API key (set OPENAI_ADMIN_KEY)")
        }
        let data = try await fetchCosts(key: key)
        let (total, currency) = try Self.parseCosts(data)
        return Self.buildResult(total: total, currency: currency)
    }

    private func resolveKey(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        for v in Self.envVars {
            if let k = ProcessInfo.processInfo.environment[v]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        }
        return nil
    }

    // MARK: - Networking (single bounded GET, current UTC month)

    private func fetchCosts(key: String, now: Date = Date()) async throws -> Data {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now

        guard var components = URLComponents(string: Self.costsURL) else {
            throw CollectorError.invalidURL("openai costs")
        }
        components.queryItems = [
            URLQueryItem(name: "start_time", value: String(Int(monthStart.timeIntervalSince1970))),
            URLQueryItem(name: "end_time", value: String(Int(now.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        guard let url = components.url else { throw CollectorError.invalidURL("openai costs query") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            // A regular `sk-` key lacks org-cost scope ⇒ be explicit (Gemini C-15 R1 Q2).
            throw CollectorError.missingCredentials("OpenAI Admin: org admin key (sk-admin-) required")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "OpenAI Admin")
        }
        return data
    }

    // MARK: - Parse (sum amount.value across all buckets; empty → 0)

    static func parseCosts(_ data: Data) throws -> (total: Double, currency: String) {
        let resp: CostsResponse
        do {
            resp = try JSONDecoder().decode(CostsResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("OpenAI Admin: \(error.localizedDescription)")
        }
        var total = 0.0
        var currency: String?
        for bucket in resp.data {
            for result in bucket.results {
                total += result.amount?.value ?? 0
                if currency == nil, let c = result.amount?.currency, !c.isEmpty {
                    currency = c
                }
            }
        }
        return (max(0, total), currency ?? "USD")
    }

    private struct CostsResponse: Decodable {
        let data: [Bucket]
        struct Bucket: Decodable { let results: [Result] }
        struct Result: Decodable { let amount: Amount? }
        struct Amount: Decodable {
            let value: Double?
            let currency: String?
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                self.value = c.flexibleDouble(.value)
                self.currency = try? c.decodeIfPresent(String.self, forKey: .currency)
            }
            private enum CodingKeys: String, CodingKey { case value, currency }
        }
    }

    // MARK: - Result building (.statusOnly month-to-date spend)

    static func buildResult(total: Double, currency: String) -> CollectorResult {
        let cost = max(0, total)
        let symbol = currency.uppercased() == "USD" ? "$" : "\(currency) "
        let usage = ProviderUsage(
            provider: ProviderKind.openaiAdmin.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: cost,
            cost_status_today: "Unavailable", cost_status_week: "Exact",
            quota: nil, remaining: nil,
            plan_type: "Admin API", reset_time: nil, tiers: [],
            status_text: "\(symbol)\(String(format: "%.2f", cost)) this month",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "OpenAI Admin", category: "cloud",
                supports_exact_cost: true, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }
}

// MARK: - Flexible amount decode (vendored, fileprivate)

extension KeyedDecodingContainer {
    fileprivate func flexibleDouble(_ key: K) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}
#endif
