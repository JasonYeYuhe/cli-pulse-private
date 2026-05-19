// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Crof/{CrofUsageFetcher,
// CrofUsageSnapshot}.swift (https://github.com/steipete/CodexBar).
// The Codable response model and the used-percent + next-reset
// (America/Chicago midnight) logic are vendored; the fetch is
// reimplemented on CLI Pulse's api-key collector idiom.
//
// CodexBar-parity Phase C-1 — promote the (absent) Crof provider to a
// real `.quota` collector (api-key Bearer, single billing endpoint).
//
// Divergences from upstream:
//   * fetch via URLSession + CLI Pulse `ProviderConfig.apiKey` / env
//     (no CodexBar ProviderHTTPTransport)
//   * `now` is injectable into `buildResult` so the Chicago-midnight
//     reset is deterministically testable (Gemini Phase-C1 R1 MEDIUM)
//   * mapped to `ProviderUsage` `.quota` (requests are the real
//     quota; Crof's credit balance is uncapped ⇒ surfaced in
//     status_text, not as a synthetic %)
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

/// Fetches Crof request-quota + credit balance via api-key auth.
///
/// Endpoint: `GET https://crof.ai/usage_api/`
/// Auth: `Authorization: Bearer <apiKey>` (`config.apiKey` or env
/// `CROF_API_KEY`).
public struct CrofCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.crof

    private static let usageURL = "https://crof.ai/usage_api/"
    private static let resetTimeZoneID = "America/Chicago"

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("Crof: no API key found")
        }
        let data = try await fetchUsage(token: token)
        let parsed = try CrofCollector.parseResponse(data)
        return buildResult(parsed)
    }

    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = ProcessInfo.processInfo.environment["CROF_API_KEY"], !k.isEmpty {
            return k
        }
        return nil
    }

    private func fetchUsage(token: String) async throws -> Data {
        guard let url = URL(string: Self.usageURL) else {
            throw CollectorError.invalidURL("crof usage_api")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Crof")
        }
        return data
    }

    // MARK: - Response model (vendored verbatim, snake_case)

    struct CrofUsageResponse: Decodable, Sendable {
        let credits: Double
        let requestsPlan: Double
        let usableRequests: Double

        enum CodingKeys: String, CodingKey {
            case credits
            case requestsPlan = "requests_plan"
            case usableRequests = "usable_requests"
        }
    }

    static func parseResponse(_ data: Data) throws -> CrofUsageResponse {
        do {
            return try JSONDecoder().decode(CrofUsageResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Crof: \(error.localizedDescription)")
        }
    }

    /// Next local midnight in America/Chicago after `now`
    /// (DST-safe via Calendar). Vendored from CrofUsageSnapshot.
    static func nextRequestReset(after now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: Self.resetTimeZoneID)
            ?? TimeZone(secondsFromGMT: -5 * 3600)!
        let startOfToday = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
    }

    // MARK: - Result building (.quota; `now` injectable — Gemini R1 MEDIUM)

    func buildResult(_ r: CrofUsageResponse, now: Date = Date()) -> CollectorResult {
        // Crof exposes a request allocation + remaining; CLI Pulse's
        // ProviderUsage derives the bar from quota/remaining counts
        // (no synthetic percent needed — unlike CodexBar's RateWindow).
        let plan = max(0, r.requestsPlan)
        let usable = max(0, min(plan, r.usableRequests))
        let quotaInt = Int(plan.rounded())
        let remainingInt = Int(usable.rounded())
        let resetISO = sharedISO8601Formatter.string(from: Self.nextRequestReset(after: now))

        let usage = ProviderUsage(
            provider: ProviderKind.crof.rawValue,
            today_usage: quotaInt - remainingInt, week_usage: quotaInt - remainingInt,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: quotaInt > 0 ? quotaInt : nil,
            remaining: remainingInt,
            plan_type: "API key",
            reset_time: resetISO,
            tiers: quotaInt > 0
                ? [TierDTO(name: "Requests", quota: quotaInt,
                           remaining: remainingInt, reset_time: resetISO)]
                : [],
            status_text: String(
                format: "$%.2f credits · %d requests left", r.credits, remainingInt),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Crof", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
