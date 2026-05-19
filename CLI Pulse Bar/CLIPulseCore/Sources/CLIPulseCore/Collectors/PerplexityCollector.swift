// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Perplexity/{PerplexityModels,
// PerplexityUsageFetcher,PerplexityUsageSnapshot}.swift
// (https://github.com/steipete/CodexBar). The Codable response model
// and the recurring→purchased→promotional waterfall attribution are
// vendored verbatim; the fetch is reimplemented on CLI Pulse's G1
// `CookieResolver` seam and the result mapped to `ProviderUsage`.
//
// CodexBar-parity Phase B-1 — promote the Perplexity stub to a real
// `.credits` collector (session-cookie auth, single billing endpoint).
//
// Divergences from upstream:
//   * fetch uses CLI Pulse's `CookieResolver` (manual / env /
//     macOS auto-import) instead of CodexBar's bespoke importer
//   * `UsageSnapshot`/`RateWindow`/`ProviderIdentitySnapshot` (CodexBar
//     types) are NOT vendored — only the cents attribution + plan
//     inference are ported; output is mapped to `ProviderUsage` with
//     `dataKind: .credits`, scaled with the OpenRouter convention
//     ($1 = 100_000 units) so the existing credits UI renders it.
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

/// Fetches Perplexity credit balance/usage via session-cookie auth.
///
/// Endpoint: `GET https://www.perplexity.ai/rest/billing/credits`
/// Auth: Cookie header — session cookie from browser auto-import
/// (G1) or manual `config.manualCookieHeader` / env var.
public struct PerplexityCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.perplexity

    private static let envVars = ["PERPLEXITY_SESSION_TOKEN", "PERPLEXITY_COOKIE"]
    private static let cookieDomains = ["www.perplexity.ai", "perplexity.ai"]
    // Gemini Phase-B R1 CRITICAL: pin the auth-cookie names so the
    // resolver doesn't hand back `__cf_bm`/analytics cookies ⇒ 401.
    private static let knownSessionNames: Set<String> = [
        "__Secure-next-auth.session-token", "next-auth.session-token",
    ]

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.knownSessionNames)
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("Perplexity: no session cookie (manual or auto-import)")
        }
        let data = try await fetchCredits(cookie: cookie)
        let parsed = try Self.parseCredits(data)
        return buildResult(PerplexitySnapshot(response: parsed, now: Date()))
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    private func fetchCredits(cookie: String) async throws -> Data {
        guard let url = URL(string:
            "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default") else {
            throw CollectorError.invalidURL("perplexity credits")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://www.perplexity.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://www.perplexity.ai/account/usage", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/124.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Perplexity")
        }
        return data
    }

    // MARK: - Response model (vendored verbatim, snake_case)

    struct PerplexityCreditsResponse: Codable, Sendable {
        let balanceCents: Double
        let renewalDateTs: TimeInterval
        let currentPeriodPurchasedCents: Double
        let creditGrants: [PerplexityCreditGrant]
        let totalUsageCents: Double

        enum CodingKeys: String, CodingKey {
            case balanceCents = "balance_cents"
            case renewalDateTs = "renewal_date_ts"
            case currentPeriodPurchasedCents = "current_period_purchased_cents"
            case creditGrants = "credit_grants"
            case totalUsageCents = "total_usage_cents"
        }
    }

    struct PerplexityCreditGrant: Codable, Sendable {
        let type: String
        let amountCents: Double
        let expiresAtTs: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case type
            case amountCents = "amount_cents"
            case expiresAtTs = "expires_at_ts"
        }
    }

    static func parseCredits(_ data: Data) throws -> PerplexityCreditsResponse {
        do {
            return try JSONDecoder().decode(PerplexityCreditsResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Perplexity: \(error.localizedDescription)")
        }
    }

    // MARK: - Attribution (vendored verbatim from PerplexityUsageSnapshot)

    struct PerplexitySnapshot: Sendable {
        let recurringTotal: Double
        let recurringUsed: Double
        let promoTotal: Double
        let promoUsed: Double
        let purchasedTotal: Double
        let purchasedUsed: Double
        let balanceCents: Double
        let totalUsageCents: Double
        let renewalDate: Date

        init(response: PerplexityCreditsResponse, now: Date) {
            let recurring = response.creditGrants.filter { $0.type == "recurring" }
            let promotional = response.creditGrants.filter {
                $0.type == "promotional" && ($0.expiresAtTs ?? .infinity) > now.timeIntervalSince1970
            }
            let purchased = response.creditGrants.filter { $0.type == "purchased" }

            let recurringSum = max(0, recurring.reduce(0.0) { $0 + $1.amountCents })
            let promoSum = max(0, promotional.reduce(0.0) { $0 + $1.amountCents })
            // Purchased may appear in the top-level field, in grants, or
            // both — take the larger to avoid double-counting.
            let purchasedFromGrants = max(0, purchased.reduce(0.0) { $0 + $1.amountCents })
            let purchasedFromField = max(0, response.currentPeriodPurchasedCents)
            let purchasedSum = max(purchasedFromGrants, purchasedFromField)

            // Waterfall attribution: recurring → purchased → promotional.
            var remaining = response.totalUsageCents
            let usedFromRecurring = min(remaining, recurringSum); remaining -= usedFromRecurring
            let usedFromPurchased = min(remaining, purchasedSum); remaining -= usedFromPurchased
            let usedFromPromo = min(remaining, promoSum)

            self.recurringTotal = recurringSum
            self.recurringUsed = usedFromRecurring
            self.promoTotal = promoSum
            self.promoUsed = usedFromPromo
            self.purchasedTotal = purchasedSum
            self.purchasedUsed = usedFromPurchased
            self.balanceCents = response.balanceCents
            self.totalUsageCents = response.totalUsageCents
            self.renewalDate = Date(timeIntervalSince1970: response.renewalDateTs)
        }

        /// Free = 0, Pro = small pool (<$50), Max = larger (verbatim).
        var planName: String? {
            if self.recurringTotal <= 0 { return nil }
            if self.recurringTotal < 5000 { return "Pro" }
            return "Max"
        }
    }

    // MARK: - Result building (.credits, OpenRouter unit convention)

    func buildResult(_ s: PerplexitySnapshot) -> CollectorResult {
        // $1.00 = 100_000 units (matches OpenRouterCollector so the
        // existing credits UI formats consistently). cents → units.
        let scale = 100_000.0
        func units(_ cents: Double) -> Int { Int((max(0, cents) / 100.0) * scale) }

        var tiers: [TierDTO] = []
        let resetISO = sharedISO8601Formatter.string(from: s.renewalDate)
        if s.recurringTotal > 0 {
            tiers.append(TierDTO(
                name: "Recurring", quota: units(s.recurringTotal),
                remaining: units(s.recurringTotal - s.recurringUsed), reset_time: resetISO))
        }
        if s.promoTotal > 0 {
            tiers.append(TierDTO(
                name: "Bonus", quota: units(s.promoTotal),
                remaining: units(s.promoTotal - s.promoUsed), reset_time: nil))
        }
        if s.purchasedTotal > 0 {
            tiers.append(TierDTO(
                name: "Purchased", quota: units(s.purchasedTotal),
                remaining: units(s.purchasedTotal - s.purchasedUsed), reset_time: nil))
        }

        let totalCents = s.recurringTotal + s.promoTotal + s.purchasedTotal
        let usageDollars = s.totalUsageCents / 100.0
        let usage = ProviderUsage(
            provider: ProviderKind.perplexity.rawValue,
            today_usage: units(s.totalUsageCents), week_usage: units(s.totalUsageCents),
            estimated_cost_today: usageDollars, estimated_cost_week: usageDollars,
            cost_status_today: "Exact", cost_status_week: "Exact",
            quota: totalCents > 0 ? units(totalCents) : nil,
            remaining: units(s.balanceCents),
            plan_type: s.planName ?? "Unknown",
            reset_time: resetISO,
            tiers: tiers,
            status_text: String(format: "$%.2f balance", s.balanceCents / 100.0),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Perplexity", category: "cloud",
                supports_exact_cost: true, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .credits)
    }
}
#endif
