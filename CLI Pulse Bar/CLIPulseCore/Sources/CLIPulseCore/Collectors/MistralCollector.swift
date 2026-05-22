// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Mistral/{MistralUsageFetcher,MistralModels,
// MistralCookieImporter}.swift (https://github.com/steipete/CodexBar). The
// Codable billing tree, the price index (`metric::group → price`), the
// `tokens × price` cost aggregation, and the `ory_session_*` / `csrftoken`
// cookie handling are ported; the fetch is reimplemented on CLI Pulse's G1
// `CookieResolver` seam + URLSession and mapped to `.statusOnly` spend.
//
// CodexBar-parity Phase C-10 — add the (absent) Mistral provider. Cookie
// batch #3. Mistral is pay-as-you-go: no quota cap, no credit balance, only
// month-to-date SPEND computed from token×price ⇒ `.statusOnly` carrying an
// EXACT monthly cost (the value-add), NOT `.quota`/`.credits`.
//
// Divergences from upstream:
//   * `URLSession` + `CookieResolver` instead of CodexBar's SweetCookieKit
//     importer + ProviderHTTPClient; no CodexBarLog.
//   * DROPS CodexBar's ~150-LOC daily-bucket / per-model-breakdown machinery
//     (CLI Pulse has no per-provider daily UI) — keeps only totalCost +
//     totalTokens. Gemini C-10 R1 confirmed no value lost.
//   * price-index key defaults a nil `billing_group` to "" (so a flat-priced
//     category still matches) rather than skipping it (Gemini C-10 R1 LOW).
//   * single bounded GET ⇒ no shared-TaskGroup hazard.
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

/// Fetches Mistral month-to-date API spend via session-cookie auth.
///
/// Endpoint: `GET admin.mistral.ai/api/billing/v2/usage?month&year`. Auth:
/// `Cookie:` header (must contain an `ory_session_*` cookie) + optional
/// `X-CSRFTOKEN` from the `csrftoken` cookie — from browser auto-import (G1),
/// manual paste, or `MISTRAL_COOKIE` / `MISTRAL_SESSION_TOKEN`.
public struct MistralCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.mistral

    private static let envVars = ["MISTRAL_COOKIE", "MISTRAL_SESSION_TOKEN"]
    private static let cookieDomains = ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai"]
    // EMPTY on purpose: the session cookie is `ory_session_<dynamic>` (Ory
    // Kratos) — the importer guards by EXACT name, which can't match a dynamic
    // suffix. Empty ⇒ all domain cookies returned; we validate the
    // `ory_session_` prefix ourselves below.
    private static let knownSessionNames: Set<String> = []

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.knownSessionNames)
        guard let header = resolution.headerValue else {
            throw CollectorError.missingCredentials("Mistral: no session cookie (manual or auto-import)")
        }
        let (hasSession, csrf) = Self.sessionAndCSRF(fromHeader: header)
        guard hasSession else {
            throw CollectorError.missingCredentials("Mistral: cookie has no ory_session_* (not signed in)")
        }
        let data = try await fetchUsage(cookie: header, csrf: csrf)
        let usage = try Self.parseUsage(data)
        return Self.buildResult(usage)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Cookie parsing (ory_session_ presence + csrftoken extraction)

    /// `(hasSession: an ory_session_* cookie is present, csrf: the csrftoken
    /// cookie value if any)`.
    static func sessionAndCSRF(fromHeader raw: String) -> (hasSession: Bool, csrf: String?) {
        var hasSession = false
        var csrf: String?
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.hasPrefix("ory_session_") { hasSession = true }
            if name.caseInsensitiveCompare("csrftoken") == .orderedSame {
                let v = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !v.isEmpty { csrf = v }
            }
        }
        return (hasSession, csrf)
    }

    // MARK: - Networking (single bounded GET)

    private func fetchUsage(cookie: String, csrf: String?) async throws -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date()
        let month = calendar.component(.month, from: now)
        let year = calendar.component(.year, from: now)

        var components = URLComponents(string: "https://admin.mistral.ai/api/billing/v2/usage")
        components?.queryItems = [
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "year", value: "\(year)"),
        ]
        guard let url = components?.url else {
            throw CollectorError.invalidURL("mistral usage")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://admin.mistral.ai/organization/usage", forHTTPHeaderField: "Referer")
        request.setValue("https://admin.mistral.ai", forHTTPHeaderField: "Origin")
        if let csrf { request.setValue(csrf, forHTTPHeaderField: "X-CSRFTOKEN") }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("Mistral: session expired or unauthorized")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "Mistral")
        }
        return data
    }

    // MARK: - Parse + aggregate

    /// Month-to-date spend summary (the testable seam; the raw Codable tree
    /// stays fileprivate).
    struct MistralUsage: Sendable, Equatable {
        var totalCost: Double
        var currency: String
        var currencySymbol: String
        var totalTokens: Int
        var startDate: Date?
        var endDate: Date?
    }

    static func parseUsage(_ data: Data) throws -> MistralUsage {
        let resp: MistralBillingResponse
        do {
            resp = try JSONDecoder().decode(MistralBillingResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Mistral: \(error.localizedDescription)")
        }
        let prices = buildPriceIndex(resp.prices ?? [])
        var cost = 0.0
        var tokens = 0

        func accumulate(_ models: [String: MistralModelUsageData]?, countsTokens: Bool) {
            guard let models else { return }
            for (_, model) in models {
                for entry in (model.input ?? []) + (model.output ?? []) + (model.cached ?? []) {
                    let units = entry.valuePaid ?? entry.value ?? 0
                    cost += Double(units) * priceFor(entry, in: prices)
                    if countsTokens { tokens += units }
                }
            }
        }

        accumulate(resp.completion?.models, countsTokens: true)
        accumulate(resp.ocr?.models, countsTokens: false)
        accumulate(resp.connectors?.models, countsTokens: false)
        accumulate(resp.audio?.models, countsTokens: false)
        accumulate(resp.librariesApi?.pages?.models, countsTokens: false)
        accumulate(resp.librariesApi?.tokens?.models, countsTokens: true)
        accumulate(resp.fineTuning?.training, countsTokens: false)
        accumulate(resp.fineTuning?.storage, countsTokens: false)

        return MistralUsage(
            totalCost: max(0, cost),                 // clamp refund/credit adjustments
            currency: resp.currency ?? "EUR",
            currencySymbol: resp.currencySymbol ?? "€",
            totalTokens: tokens,
            startDate: parseDate(resp.startDate),
            endDate: parseDate(resp.endDate))
    }

    /// `metric::group → price`; nil `group` defaults to "" so a flat-priced
    /// category still matches (Gemini C-10 R1 LOW). Requires `metric`.
    static func buildPriceIndex(_ prices: [MistralPrice]) -> [String: Double] {
        var index: [String: Double] = [:]
        for p in prices {
            guard let metric = p.billingMetric, let priceStr = p.price, let value = Double(priceStr) else {
                continue
            }
            index["\(metric)::\(p.billingGroup ?? "")"] = value
        }
        return index
    }

    private static func priceFor(_ entry: MistralUsageEntry, in prices: [String: Double]) -> Double {
        guard let metric = entry.billingMetric else { return 0 }
        return prices["\(metric)::\(entry.billingGroup ?? "")"] ?? 0
    }

    static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: string) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    // MARK: - Result building (.statusOnly with exact month-to-date cost)

    static func buildResult(_ u: MistralUsage) -> CollectorResult {
        let cost = max(0, u.totalCost)
        var status = "\(u.currencySymbol)\(String(format: "%.4f", cost)) this month"
        if u.totalTokens > 0 {
            status += " · \(creditCountString(Double(u.totalTokens))) tokens"
        }
        let resetISO = u.endDate.map { sharedISO8601Formatter.string(from: $0) }
        let usage = ProviderUsage(
            provider: ProviderKind.mistral.rawValue,
            today_usage: 0, week_usage: max(0, u.totalTokens),
            estimated_cost_today: 0, estimated_cost_week: cost,
            cost_status_today: "Unavailable", cost_status_week: "Exact",
            quota: nil, remaining: nil,
            plan_type: "Pay-as-you-go", reset_time: resetISO, tiers: [],
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Mistral", category: "cloud",
                supports_exact_cost: true, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    static func creditCountString(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US_POSIX")
        let rounded = value.isFinite ? value.rounded() : 0
        return f.string(from: NSNumber(value: rounded)) ?? String(Int(rounded))
    }
}

// MARK: - Vendored Codable billing tree (fileprivate; only the fields used
// for cost + token aggregation are kept — the rest of CodexBar's model is
// intentionally dropped).

private struct MistralBillingResponse: Decodable {
    let completion: MistralModelUsageCategory?
    let ocr: MistralModelUsageCategory?
    let connectors: MistralModelUsageCategory?
    let audio: MistralModelUsageCategory?
    let librariesApi: MistralLibrariesUsageCategory?
    let fineTuning: MistralFineTuningCategory?
    let startDate: String?
    let endDate: String?
    let currency: String?
    let currencySymbol: String?
    let prices: [MistralPrice]?

    enum CodingKeys: String, CodingKey {
        case completion, ocr, connectors, audio, currency, prices
        case librariesApi = "libraries_api"
        case fineTuning = "fine_tuning"
        case startDate = "start_date"
        case endDate = "end_date"
        case currencySymbol = "currency_symbol"
    }
}

private struct MistralModelUsageCategory: Decodable {
    let models: [String: MistralModelUsageData]?
}

private struct MistralLibrariesUsageCategory: Decodable {
    let pages: MistralModelUsageCategory?
    let tokens: MistralModelUsageCategory?
}

private struct MistralFineTuningCategory: Decodable {
    let training: [String: MistralModelUsageData]?
    let storage: [String: MistralModelUsageData]?
}

private struct MistralModelUsageData: Decodable {
    let input: [MistralUsageEntry]?
    let output: [MistralUsageEntry]?
    let cached: [MistralUsageEntry]?
}

private struct MistralUsageEntry: Decodable {
    let billingMetric: String?
    let billingGroup: String?
    let value: Int?
    let valuePaid: Int?

    enum CodingKeys: String, CodingKey {
        case value
        case billingMetric = "billing_metric"
        case billingGroup = "billing_group"
        case valuePaid = "value_paid"
    }
}

// `MistralPrice` is referenced by the internal `buildPriceIndex` signature, so
// it is internal (not fileprivate) — its fields stay minimal.
struct MistralPrice: Decodable {
    let billingMetric: String?
    let billingGroup: String?
    let price: String?

    enum CodingKeys: String, CodingKey {
        case price
        case billingMetric = "billing_metric"
        case billingGroup = "billing_group"
    }
}
#endif
