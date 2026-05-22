// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Moonshot/{MoonshotUsageFetcher,
// MoonshotRegion}.swift (https://github.com/steipete/CodexBar). The balance
// response model, the `code==0 && status` gate, the region base URLs, and the
// deficit display are ported; the fetch is reimplemented on URLSession and
// mapped to `.credits`.
//
// CodexBar-parity Phase C-13 — add the (absent) Moonshot provider: the
// DEVELOPER API platform balance (api.moonshot.ai / .cn, api-key), DISTINCT
// from CLI Pulse's existing Kimi / Kimi K2 (the consumer chat app, cookie).
// Clean DeepSeek-style `.credits` uncapped balance.
//
// Divergences from upstream:
//   * `URLSession` instead of ProviderHTTPClient; no CodexBarLog.
//   * region selected via env `MOONSHOT_API_BASE` (default International)
//     rather than a settings enum (Groq `GROQ_API_URL` precedent).
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

/// Fetches the Moonshot developer-platform USD balance.
///
/// `GET {base}/v1/users/me/balance`, `Authorization: Bearer <key>`. Base from
/// env `MOONSHOT_API_BASE` (default `https://api.moonshot.ai`; China users set
/// `https://api.moonshot.cn`). Key: `config.apiKey` or env `MOONSHOT_API_KEY`.
public struct MoonshotCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.moonshot

    static let apiKeyEnv = "MOONSHOT_API_KEY"
    static let apiBaseEnv = "MOONSHOT_API_BASE"
    static let defaultBase = "https://api.moonshot.ai"
    static let usdUnitScale = 100_000.0   // $1 = 100_000 units (DeepSeek/Venice/Perplexity)

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveKey(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let key = resolveKey(config: config) else {
            throw CollectorError.missingCredentials("Moonshot: no API key (set MOONSHOT_API_KEY)")
        }
        let data = try await fetchBalance(key: key, base: Self.resolveBase())
        let balance = try Self.parseBalance(data)
        return Self.buildResult(balance)
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

    static func resolveBase() -> String {
        if let raw = ProcessInfo.processInfo.environment[apiBaseEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return defaultBase
    }

    // MARK: - Networking

    private func fetchBalance(key: String, base: String) async throws -> Data {
        guard let url = URL(string: base + "/v1/users/me/balance") else {
            throw CollectorError.invalidURL("moonshot balance")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("Moonshot: unauthorized")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "Moonshot")
        }
        return data
    }

    // MARK: - Parse

    struct MoonshotBalance: Sendable, Equatable {
        var available: Double
        var voucher: Double
        var cash: Double
    }

    static func parseBalance(_ data: Data) throws -> MoonshotBalance {
        let resp: BalanceResponse
        do {
            resp = try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Moonshot: \(error.localizedDescription)")
        }
        // Chinese-API success gate (code 0 + status true) — faithful to upstream.
        guard resp.code == 0, resp.status else {
            throw CollectorError.parseFailed("Moonshot: code \(resp.code), scode \(resp.scode ?? "?")")
        }
        return MoonshotBalance(
            available: resp.data.availableBalance,
            voucher: resp.data.voucherBalance,
            cash: resp.data.cashBalance)
    }

    private struct BalanceResponse: Decodable {
        let code: Int
        let data: BalanceData
        let scode: String?
        let status: Bool
    }

    private struct BalanceData: Decodable {
        let availableBalance: Double
        let voucherBalance: Double
        let cashBalance: Double
        private enum CodingKeys: String, CodingKey {
            case availableBalance = "available_balance"
            case voucherBalance = "voucher_balance"
            case cashBalance = "cash_balance"
        }
    }

    // MARK: - Result building (.credits uncapped USD balance)

    static func buildResult(_ b: MoonshotBalance) -> CollectorResult {
        var status = "Balance: \(usdString(b.available))"
        if b.cash < 0 {
            status += " · \(usdString(abs(b.cash))) in deficit"
        }
        // voucher / positive cash as informational tiers (skip negative cash —
        // a negative TierDTO breaks UI; the C-11 lesson).
        var tiers: [TierDTO] = []
        func addTier(_ name: String, _ usd: Double) {
            guard usd > 0 else { return }
            let u = units(usd)
            tiers.append(TierDTO(name: name, quota: u, remaining: u, reset_time: nil))
        }
        addTier("Voucher", b.voucher)
        addTier("Cash", b.cash)

        let usage = ProviderUsage(
            provider: ProviderKind.moonshot.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: units(b.available),   // uncapped balance ⇒ no gauge
            plan_type: "API key", reset_time: nil, tiers: tiers,
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Moonshot", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .credits)
    }

    static func units(_ usd: Double) -> Int {
        guard usd.isFinite, usd > 0 else { return 0 }
        return Int((usd * usdUnitScale).rounded())
    }

    static func usdString(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        let digits = abs(value) < 100 ? 2 : 0
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}
#endif
