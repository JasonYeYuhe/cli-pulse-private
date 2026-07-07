// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/CrossModel/{CrossModelUsageStats,
// CrossModelSettingsReader}.swift (https://github.com/steipete/CodexBar). The
// micro-unit wire DTOs (balance_micro / uncollected_micro / cost_micro,
// 1 major unit = 1_000_000 micro), the currency normalization, the
// currency-mismatch drop rule, and the HTTPS-or-loopback endpoint-override
// validation are ported; the fetch is reimplemented on CLI Pulse's api-key
// collector idiom and mapped to `.credits`.
//
// v1.40.0 — add the (absent) CrossModel provider: wallet balance (required
// `/credits`) plus best-effort daily/monthly spend (`/usage`). Bearer
// CROSSMODEL_API_KEY (or config apiKey); optional CROSSMODEL_API_URL.
//
// Divergences from upstream:
//   * `URLSession` instead of ProviderHTTPClient / BoundedTaskJoin — the
//     best-effort `/usage` call uses a short (3s) request timeout wrapped in
//     `try?` rather than a task-join race.
//   * `.credits` with `remaining` = balance at the shared 100_000 magnitude
//     scale (Moonshot precedent — an internal gauge magnitude, currency-
//     agnostic); the true currency-formatted value lives in `status_text`.
//   * spend windows surface in `status_text` (Today / Month) rather than as
//     TierDTOs — spend is not a quota/remaining pair.
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

/// Fetches the CrossModel wallet balance (+ best-effort spend) via Bearer api-key.
///
/// `GET {base}/credits` (required) → `{currency, balance_micro, uncollected_micro}`.
/// `GET {base}/usage` (best-effort) → `{currency, daily, weekly, monthly}`.
/// Base defaults to `https://api.crossmodel.ai/v1`; override via env
/// `CROSSMODEL_API_URL` (HTTPS anywhere, or HTTP loopback only). Key:
/// `config.apiKey` or env `CROSSMODEL_API_KEY`.
public struct CrossModelCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.crossModel

    static let apiKeyEnv = "CROSSMODEL_API_KEY"
    static let apiURLEnv = "CROSSMODEL_API_URL"
    static let defaultBase = "https://api.crossmodel.ai/v1"
    static let usdUnitScale = 100_000.0   // shared magnitude scale (DeepSeek/Venice/Moonshot)

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("CrossModel: no API key (set CROSSMODEL_API_KEY)")
        }
        let base = try Self.resolveBase()
        let credits = try await fetchCredits(token: token, base: base)
        // Usage windows are best-effort: a slow or failing /usage call must not
        // block the balance the user came to see. Dropped on currency mismatch.
        let usage = await fetchUsageWindows(token: token, base: base)
        let matchedUsage = (usage?.currency == credits.currency) ? usage : nil
        return Self.buildResult(credits: credits, usage: matchedUsage)
    }

    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = ProcessInfo.processInfo.environment[Self.apiKeyEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        return nil
    }

    /// Resolves the API base, validating any `CROSSMODEL_API_URL` override as
    /// HTTPS (any host) or loopback HTTP. Throws on an invalid override rather
    /// than silently hitting production with a misconfigured value.
    static func resolveBase() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment[apiURLEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return URL(string: defaultBase)!
        }
        guard let url = validatedOverride(raw) else {
            throw CollectorError.invalidURL("CrossModel: CROSSMODEL_API_URL must be https or loopback http")
        }
        return url
    }

    /// Accepts `https://…` for any host, or `http://…` only for a loopback host.
    static func validatedOverride(_ raw: String) -> URL? {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        switch scheme {
        case "https":
            return url
        case "http":
            let loopback: Set<String> = ["localhost", "127.0.0.1", "::1", "[::1]"]
            return loopback.contains(host) ? url : nil
        default:
            return nil
        }
    }

    // MARK: - Networking

    private func fetchCredits(token: String, base: URL) async throws -> Credits {
        let url = base.appendingPathComponent("credits")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.notSignedIn("CrossModel: API key rejected (401/403)")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "CrossModel")
        }
        // Reject a cross-origin redirect that could have leaked the bearer.
        guard Self.sameOrigin(requestURL: url, responseURL: http?.url) else {
            throw CollectorError.parseFailed("CrossModel: /credits redirected to a different origin")
        }
        return try Self.parseCredits(data)
    }

    private func fetchUsageWindows(token: String, base: URL) async -> Usage? {
        let url = base.appendingPathComponent("usage")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return nil }
        let http = response as? HTTPURLResponse
        guard http?.statusCode == 200,
              Self.sameOrigin(requestURL: url, responseURL: http?.url) else { return nil }
        return try? Self.parseUsage(data)
    }

    static func sameOrigin(requestURL: URL, responseURL: URL?) -> Bool {
        guard let responseURL else { return true }   // no redirect recorded
        func port(_ u: URL) -> Int? {
            if let p = u.port { return p }
            switch u.scheme?.lowercased() { case "https": return 443; case "http": return 80; default: return nil }
        }
        return requestURL.scheme?.lowercased() == responseURL.scheme?.lowercased()
            && requestURL.host?.lowercased() == responseURL.host?.lowercased()
            && port(requestURL) == port(responseURL)
    }

    // MARK: - Parse (pure)

    struct Credits: Sendable, Equatable {
        var currency: String
        var balance: Double     // major units
        var uncollected: Double
    }

    struct Usage: Sendable, Equatable {
        var currency: String
        var dailyCost: Double
        var weeklyCost: Double
        var monthlyCost: Double
    }

    private struct CreditsDTO: Decodable {
        let currency: String
        let balanceMicro: Int64
        let uncollectedMicro: Int64
        enum CodingKeys: String, CodingKey {
            case currency
            case balanceMicro = "balance_micro"
            case uncollectedMicro = "uncollected_micro"
        }
    }

    private struct WindowDTO: Decodable {
        let costMicro: Int64
        enum CodingKeys: String, CodingKey { case costMicro = "cost_micro" }
    }

    private struct UsageDTO: Decodable {
        let currency: String
        let daily: WindowDTO
        let weekly: WindowDTO
        let monthly: WindowDTO
    }

    static func majorUnits(_ micro: Int64) -> Double { Double(micro) / 1_000_000.0 }

    static func normalizedCurrency(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    static func parseCredits(_ data: Data) throws -> Credits {
        let dto: CreditsDTO
        do {
            dto = try JSONDecoder().decode(CreditsDTO.self, from: data)
        } catch {
            throw CollectorError.parseFailed("CrossModel: \(error.localizedDescription)")
        }
        let currency = normalizedCurrency(dto.currency)
        guard !currency.isEmpty else {
            throw CollectorError.parseFailed("CrossModel: missing /credits currency")
        }
        return Credits(
            currency: currency,
            balance: majorUnits(dto.balanceMicro),
            uncollected: majorUnits(dto.uncollectedMicro))
    }

    static func parseUsage(_ data: Data) throws -> Usage {
        let dto = try JSONDecoder().decode(UsageDTO.self, from: data)
        let currency = normalizedCurrency(dto.currency)
        guard !currency.isEmpty else {
            throw CollectorError.parseFailed("CrossModel: missing /usage currency")
        }
        return Usage(
            currency: currency,
            dailyCost: majorUnits(dto.daily.costMicro),
            weeklyCost: majorUnits(dto.weekly.costMicro),
            monthlyCost: majorUnits(dto.monthly.costMicro))
    }

    // MARK: - Result building (.credits — wallet balance, uncapped)

    static func buildResult(credits c: Credits, usage: Usage?) -> CollectorResult {
        var status = "Balance: \(currencyString(c.balance, code: c.currency))"
        if c.uncollected > 0 {
            status += " · \(currencyString(c.uncollected, code: c.currency)) uncollected"
        }
        if let usage {
            status += " · Today \(currencyString(usage.dailyCost, code: usage.currency))"
            status += " · Month \(currencyString(usage.monthlyCost, code: usage.currency))"
        }

        let usageDTO = ProviderUsage(
            provider: ProviderKind.crossModel.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: units(c.balance),   // uncapped balance ⇒ no gauge
            plan_type: "API key", reset_time: nil, tiers: [],
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "CrossModel", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usageDTO, dataKind: .credits)
    }

    static func units(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        let scaled = (value * usdUnitScale).rounded()
        return scaled >= Double(Int.max) ? Int.max : Int(scaled)   // saturate, never trap
    }

    static func currencyString(_ value: Double, code: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = code
        f.locale = Locale(identifier: "en_US")
        let digits = abs(value) < 100 ? 2 : 0
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.2f %@", value, code)
    }
}
#endif
