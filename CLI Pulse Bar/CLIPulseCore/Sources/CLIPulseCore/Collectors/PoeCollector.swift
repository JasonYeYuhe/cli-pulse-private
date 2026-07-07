// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Poe/{PoeUsageFetcher,PoeUsageSnapshot,
// PoeSettingsReader}.swift (https://github.com/steipete/CodexBar). The
// `current_point_balance` parse, the flexible numeric coercion, the 401/403
// unauthorized gate, and the "Balance: N points" compact label are ported;
// the fetch is reimplemented on CLI Pulse's api-key collector idiom
// (Venice/Moonshot precedent) and mapped to `.credits`.
//
// v1.40.0 — add the (absent) Poe provider: the developer-API points balance
// (api.poe.com, Bearer api-key). Balance-only port: upstream's optional
// paginated `points_history` feeds a per-provider usage chart we do not render,
// so it is intentionally skipped (history failure never blocked the balance
// upstream either).
//
// Divergences from upstream:
//   * `URLSession` instead of ProviderHTTPClient; no CodexBarLog.
//   * `.credits` with the raw POINTS count as `remaining` (points are the unit
//     — NOT USD, so the shared $1=100_000 scale is deliberately NOT applied).
//   * Missing/absent balance degrades to a graceful status (no throw) — the
//     auth succeeded, only the number is absent.
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

/// Fetches the Poe developer-API compute-points balance via Bearer api-key.
///
/// `GET https://api.poe.com/usage/current_balance`,
/// `Authorization: Bearer <apiKey>`. Key: `config.apiKey` or env
/// `POE_API_KEY` / `POE_KEY`.
public struct PoeCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.poe

    private static let balanceURL = "https://api.poe.com/usage/current_balance"
    private static let envVars = ["POE_API_KEY", "POE_KEY"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("Poe: no API key (set POE_API_KEY)")
        }
        let data = try await fetchBalance(token: token)
        let balance = try Self.parseBalance(data)
        return Self.buildResult(balance)
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

    // MARK: - Networking

    private func fetchBalance(token: String) async throws -> Data {
        guard let url = URL(string: Self.balanceURL) else {
            throw CollectorError.invalidURL("poe current_balance")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.notSignedIn("Poe: API key rejected (401/403)")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "Poe")
        }
        return data
    }

    // MARK: - Parse

    /// Returns the current point balance, or nil if the field is absent/blank.
    /// Throws `parseFailed` only when the body is not JSON at all.
    static func parseBalance(_ data: Data) throws -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Poe: invalid JSON")
        }
        return double(from: root["current_point_balance"])
    }

    static func double(from value: Any?) -> Double? {
        // JSON booleans bridge to NSNumber; a `true`/`false` balance is not a
        // number (mirror ChutesCollector.double's guard — keep parsers uniform).
        if value is Bool { return nil }
        switch value {
        case let n as NSNumber:
            let raw = n.doubleValue
            return raw.isFinite ? raw : nil
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, let raw = Double(t), raw.isFinite else { return nil }
            return raw
        default:
            return nil
        }
    }

    // MARK: - Result building (.credits — raw points balance, uncapped)

    static func buildResult(_ balance: Double?) -> CollectorResult {
        let status: String
        let remaining: Int?
        if let balance, balance.isFinite {
            status = "Balance: \(compactNumber(balance)) points"
            remaining = points(balance)
        } else {
            status = "Poe balance unavailable"
            remaining = nil
        }

        let usage = ProviderUsage(
            provider: ProviderKind.poe.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: remaining,   // uncapped balance ⇒ no gauge
            plan_type: "API key", reset_time: nil, tiers: [],
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Poe", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .credits)
    }

    /// Points are whole compute units — clamp to a non-negative Int magnitude.
    /// A finite-but-huge balance (≥ Int.max, e.g. an adversarial/malformed
    /// response) would trap `Int(Double)`, so saturate instead of crashing.
    static func points(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(Int.max) ? Int.max : Int(value.rounded())
    }

    /// Upstream `PoeUsageSnapshot.compactNumber` — en-US grouped, ≤1 fractional
    /// digit below 1000.
    static func compactNumber(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = value >= 1000 ? 0 : 1
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
#endif
