// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Venice/{VeniceUsageFetcher,
// VeniceSettingsReader}.swift (https://github.com/steipete/CodexBar).
// The Codable response model, the flexible-Double decoder, and the
// 6-branch status-text logic are vendored; fetch reimplemented on
// CLI Pulse's api-key collector idiom (DeepSeek precedent).
//
// CodexBar-parity Phase C-4 — promote the (absent) Venice provider
// to a real `.credits` collector (Bearer api-key, USD + DIEM dual-
// currency with optional DIEM epoch allocation cap).
//
// Divergences from upstream:
//   * fetch via URLSession; no CodexBar HTTP transport / log.
//   * Pure-balance mapping (DeepSeek C-2 precedent): top-level
//     `quota`/`remaining` are nil, `today/week_usage` = 0 (no
//     quantitative gauge); per-currency `TierDTO`s carry the data.
//     DIEM tier is cap-aware (`quota = allocation*100`,
//     `remaining = diem*100`) when `diemEpochAllocation > 0`; else
//     no-cap (`quota == remaining`, like DeepSeek/USD).
//   * `status_text` ports CodexBar's 6-branch `balanceDetail` verbatim
//     (active-currency aware; Gemini C-4 R1 MEDIUM).
//   * Env-var quote-stripping NOT ported (YAGNI per Gemini C-2 LOW —
//     match Zai/Crof/DeepSeek/ElevenLabs).
//   * `decodeFlexibleDoubleIfPresent` is fileprivate to this file
//     (Gemini C-4 R1 LOW — isolated quirk; promote later if a 2nd
//     provider needs it).
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

/// Fetches Venice USD + DIEM balances via Bearer api-key auth.
///
/// Endpoint: `GET https://api.venice.ai/api/v1/billing/balance`
/// Auth: `Authorization: Bearer <apiKey>` (`config.apiKey` or env
/// `VENICE_API_KEY` / `VENICE_KEY`).
public struct VeniceCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.venice

    private static let balanceURL = "https://api.venice.ai/api/v1/billing/balance"
    private static let envVars = ["VENICE_API_KEY", "VENICE_KEY"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("Venice: no API key found")
        }
        let data = try await fetchBalance(token: token)
        let parsed = try Self.parseResponse(data)
        return buildResult(parsed)
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
            throw CollectorError.invalidURL("venice billing/balance")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "Venice")
        }
        return data
    }

    // MARK: - Response model (vendored verbatim with flexible-Double)

    struct BalanceResponse: Decodable, Sendable {
        let canConsume: Bool
        let consumptionCurrency: String?
        let balances: Balances
        let diemEpochAllocation: Double?

        enum CodingKeys: String, CodingKey {
            case canConsume, consumptionCurrency, balances, diemEpochAllocation
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.canConsume = try c.decode(Bool.self, forKey: .canConsume)
            self.consumptionCurrency = try c.decodeIfPresent(String.self, forKey: .consumptionCurrency)
            self.balances = try c.decode(Balances.self, forKey: .balances)
            self.diemEpochAllocation = try c.decodeFlexibleDoubleIfPresent(forKey: .diemEpochAllocation)
        }
    }

    struct Balances: Decodable, Sendable {
        let diem: Double?
        let usd: Double?

        enum CodingKeys: String, CodingKey { case diem, usd }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.diem = try c.decodeFlexibleDoubleIfPresent(forKey: .diem)
            self.usd = try c.decodeFlexibleDoubleIfPresent(forKey: .usd)
        }
    }

    static func parseResponse(_ data: Data) throws -> BalanceResponse {
        do {
            return try JSONDecoder().decode(BalanceResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Venice: \(error.localizedDescription)")
        }
    }

    // MARK: - Status text (vendored 6-branch verbatim — Gemini R1 MEDIUM)

    static func statusText(_ r: BalanceResponse) -> String {
        let active = r.consumptionCurrency?.uppercased()
        if !r.canConsume {
            return "Balance unavailable for API calls"
        }
        if active == "USD", let usd = r.balances.usd, usd > 0 {
            return String(format: "$%.2f USD remaining", usd)
        }
        if active != "USD",
           let diem = r.balances.diem,
           let allocation = r.diemEpochAllocation, allocation > 0 {
            return String(format: "DIEM %.2f / %.2f epoch allocation", diem, allocation)
        }
        if active == "DIEM", let diem = r.balances.diem, diem > 0 {
            return String(format: "DIEM %.2f remaining", diem)
        }
        if let diem = r.balances.diem, diem > 0 {
            return String(format: "DIEM %.2f remaining", diem)
        }
        if let usd = r.balances.usd, usd > 0 {
            return String(format: "$%.2f USD remaining", usd)
        }
        return "No Venice API balance available"
    }

    // MARK: - Result building (.credits, nil-gauge + cap-aware per-currency tiers)

    func buildResult(_ r: BalanceResponse) -> CollectorResult {
        // Per-currency tiers (DeepSeek precedent + cap-aware DIEM per
        // Gemini C-4 R1 HIGH/MEDIUM). Cents as Int.
        var tiers: [TierDTO] = []
        if let diem = r.balances.diem {
            let cents = Int((max(0, diem) * 100).rounded())
            if let allocation = r.diemEpochAllocation, allocation > 0 {
                // Cap-aware: real quota at the tier level.
                let capCents = Int((allocation * 100).rounded())
                tiers.append(TierDTO(
                    name: "DIEM Balance",
                    quota: capCents,
                    remaining: min(capCents, cents),
                    reset_time: nil))
            } else if cents > 0 {
                // No-cap: quota == remaining (DeepSeek form).
                tiers.append(TierDTO(
                    name: "DIEM Balance", quota: cents, remaining: cents, reset_time: nil))
            }
        }
        if let usd = r.balances.usd, usd > 0 {
            let cents = Int((usd * 100).rounded())
            tiers.append(TierDTO(
                name: "USD Balance", quota: cents, remaining: cents, reset_time: nil))
        }

        let usage = ProviderUsage(
            provider: ProviderKind.venice.rawValue,
            // Nil-gauge (DeepSeek precedent — Gemini C-4 R1 HIGH).
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            plan_type: "API key",
            reset_time: nil,
            tiers: tiers,
            status_text: Self.statusText(r),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Venice", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .credits)
    }
}

// MARK: - Flexible-Double decoder (vendored verbatim, fileprivate)

extension KeyedDecodingContainer {
    fileprivate func decodeFlexibleDoubleIfPresent(forKey key: K) throws -> Double? {
        if try self.decodeNil(forKey: key) { return nil }
        if let v = try? self.decode(Double.self, forKey: key) { return v }
        if let s = try? self.decode(String.self, forKey: key) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let parsed = Double(trimmed) { return parsed }
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription: "Expected a numeric string for \(key.stringValue), got '\(s)'")
        }
        throw DecodingError.dataCorruptedError(
            forKey: key, in: self,
            debugDescription: "Expected a number or numeric string for \(key.stringValue)")
    }
}
#endif
