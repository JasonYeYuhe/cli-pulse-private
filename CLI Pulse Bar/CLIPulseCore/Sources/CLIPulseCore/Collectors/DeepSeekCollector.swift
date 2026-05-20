// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/DeepSeek/{DeepSeekUsageFetcher,
// DeepSeekSettingsReader}.swift (https://github.com/steipete/CodexBar).
// The Codable response model and the multi-balance selection logic
// are vendored verbatim; fetch + mapping reimplemented on CLI Pulse's
// api-key collector idiom (`ZaiCollector`/`CrofCollector` precedent).
//
// CodexBar-parity Phase C-2 — promote the (absent) DeepSeek provider
// to a real `.credits` collector (api-key Bearer, single balance
// endpoint; uncapped pure-balance ⇒ nil quota/remaining gauge).
//
// Divergences from upstream:
//   * fetch via URLSession; no CodexBar HTTP transport / log.
//   * Pure-balance mapping (Gemini Phase-C2 R1 HIGH): top-level
//     `ProviderUsage.quota`/`remaining` are `nil`,
//     `today_usage`/`week_usage` = 0 — signals "no quantitative
//     gauge" rather than synthesizing a 100k-unit scale that would
//     collide between USD and CNY.
//   * Multi-currency preservation (Gemini R1 MEDIUM): every positive-
//     balance currency becomes its own `TierDTO` (cents as Int);
//     CodexBar's selection logic stays for primary `status_text`.
//   * Env-var quote-stripping NOT ported (YAGNI per Gemini R1 LOW —
//     match Zai/Crof; central helper if ever needed across the board).
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

/// Fetches DeepSeek $ balance via api-key auth.
///
/// Endpoint: `GET https://api.deepseek.com/user/balance`
/// Auth: `Authorization: Bearer <apiKey>` (`config.apiKey` or env
/// `DEEPSEEK_API_KEY` / `DEEPSEEK_KEY`).
public struct DeepSeekCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.deepseek

    private static let balanceURL = "https://api.deepseek.com/user/balance"
    private static let envVars = ["DEEPSEEK_API_KEY", "DEEPSEEK_KEY"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("DeepSeek: no API key found")
        }
        let data = try await fetchBalance(token: token)
        let parsed = try Self.parseResponse(data)
        let balances = try Self.parseBalances(parsed)
        return buildResult(isAvailable: parsed.isAvailable, balances: balances)
    }

    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        for v in Self.envVars {
            if let k = ProcessInfo.processInfo.environment[v]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty
            {
                return k
            }
        }
        return nil
    }

    private func fetchBalance(token: String) async throws -> Data {
        guard let url = URL(string: Self.balanceURL) else {
            throw CollectorError.invalidURL("deepseek user/balance")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "DeepSeek")
        }
        return data
    }

    // MARK: - Response model (vendored verbatim, snake_case)

    struct BalanceResponse: Decodable, Sendable {
        let isAvailable: Bool
        let balanceInfos: [BalanceInfo]
        enum CodingKeys: String, CodingKey {
            case isAvailable = "is_available"
            case balanceInfos = "balance_infos"
        }
    }

    struct BalanceInfo: Decodable, Sendable {
        let currency: String
        let totalBalance: String
        let grantedBalance: String
        let toppedUpBalance: String
        enum CodingKeys: String, CodingKey {
            case currency
            case totalBalance = "total_balance"
            case grantedBalance = "granted_balance"
            case toppedUpBalance = "topped_up_balance"
        }
    }

    /// Parsed numeric balance for one currency.
    struct Balance: Sendable, Equatable {
        let currency: String
        let totalBalance: Double
        let grantedBalance: Double
        let toppedUpBalance: Double
    }

    static func parseResponse(_ data: Data) throws -> BalanceResponse {
        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("DeepSeek: \(error.localizedDescription)")
        }
    }

    /// Convert the snake_case Codable response's string-encoded
    /// balances into typed `Double`s (Gemini R1 — port-gotcha).
    static func parseBalances(_ r: BalanceResponse) throws -> [Balance] {
        try r.balanceInfos.map { info in
            guard let total = Double(info.totalBalance),
                  let granted = Double(info.grantedBalance),
                  let toppedUp = Double(info.toppedUpBalance) else {
                throw CollectorError.parseFailed(
                    "DeepSeek: non-numeric balance value in response")
            }
            return Balance(
                currency: info.currency, totalBalance: total,
                grantedBalance: granted, toppedUpBalance: toppedUp)
        }
    }

    /// Pick the primary balance for `status_text` (verbatim from
    /// CodexBar): USD-positive → any-positive → USD → first.
    static func selectPrimary(_ balances: [Balance]) -> Balance? {
        if balances.isEmpty { return nil }
        return balances.first { $0.currency == "USD" && $0.totalBalance > 0 }
            ?? balances.first { $0.totalBalance > 0 }
            ?? balances.first { $0.currency == "USD" }
            ?? balances.first
    }

    // MARK: - Result building (.credits, nil-gauge + per-currency tiers)

    static func currencySymbol(_ currency: String) -> String {
        currency == "CNY" ? "¥" : "$"
    }

    static func formatStatusText(isAvailable: Bool, primary: Balance?) -> String {
        guard let p = primary else {
            return "Balance unavailable for API calls"
        }
        let symbol = currencySymbol(p.currency)
        if p.totalBalance <= 0 {
            return "\(symbol)0.00 — add credits at platform.deepseek.com"
        }
        if !isAvailable {
            return "Balance unavailable for API calls"
        }
        let total = String(format: "\(symbol)%.2f", p.totalBalance)
        let paid = String(format: "\(symbol)%.2f", p.toppedUpBalance)
        let granted = String(format: "\(symbol)%.2f", p.grantedBalance)
        return "\(total) (Paid: \(paid) / Granted: \(granted))"
    }

    func buildResult(isAvailable: Bool, balances: [Balance]) -> CollectorResult {
        let primary = Self.selectPrimary(balances)
        // Per-currency TierDTOs (Gemini R1 MEDIUM: don't discard
        // non-selected balances). cents as Int; quota == remaining
        // (no usage tracked for an uncapped balance).
        let tiers: [TierDTO] = balances
            .filter { $0.totalBalance > 0 }
            .map { b in
                let cents = Int((b.totalBalance * 100).rounded())
                return TierDTO(
                    name: "\(b.currency) Balance",
                    quota: cents, remaining: cents, reset_time: nil)
            }
        let usage = ProviderUsage(
            provider: ProviderKind.deepseek.rawValue,
            // No-gauge pure-balance (Gemini R1 HIGH): 0 usage on
            // uncapped; primary/status carries the $ figure.
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            plan_type: "API key",
            reset_time: nil,
            tiers: tiers,
            status_text: Self.formatStatusText(isAvailable: isAvailable, primary: primary),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "DeepSeek", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .credits)
    }
}
#endif
