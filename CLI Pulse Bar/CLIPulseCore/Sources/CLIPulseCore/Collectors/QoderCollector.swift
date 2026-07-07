// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Qoder/{QoderUsageFetcher,QoderUsageSnapshot,
// QoderUsageError}.swift (https://github.com/steipete/CodexBar). The two-host
// endpoints + EXACT request headers (incl. the magic Bx-V), the camelCase AND
// snake_case decode, the additive total+shared quota merge, and the ISO8601 /
// epoch reset parse are ported; the fetch is reimplemented on CLI Pulse's
// CookieResolver seam + URLSession and mapped to `.quota`.
//
// v1.40.0 — add the (absent) Qoder provider: manual-cookie big_model_credits.
// The QoderCookieImporter (browser auto-import) is intentionally SKIPPED — manual
// paste / QODER_COOKIE env only.
//
// Divergences from upstream:
//   * URLSession + CookieResolver; no CodexBarLog.
//   * We don't know which host the pasted cookie belongs to, so we try the
//     international host first and fall back to China on an auth/parse failure.
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

/// Reports Qoder "big model" credit usage via session cookie.
public struct QoderCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.qoder

    private static let envVars = ["QODER_COOKIE"]
    private static let cookieDomains = ["qoder.com", "www.qoder.com", "qoder.com.cn", "www.qoder.com.cn"]
    private static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    /// Alibaba anti-bot version header. Can rotate — soft-fail if it does.
    static let bxVersion = "2.5.35"

    enum Site: CaseIterable {
        case international, china
        var origin: String { self == .international ? "https://qoder.com" : "https://qoder.com.cn" }
        var usageURL: String { "\(origin)/api/v2/me/usages/big_model_credits" }
    }

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config, envVarNames: Self.envVars, domains: Self.cookieDomains,
            knownSessionCookieNames: [])
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("Qoder: no session cookie")
        }
        // The pasted cookie is host-specific; try international, fall back to China.
        var lastError: Error = CollectorError.notSignedIn("Qoder: session rejected")
        for site in Site.allCases {
            do {
                let data = try await Self.fetch(cookie: cookie, site: site)
                let snapshot = try Self.parse(data)
                return Self.buildResult(snapshot)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty { return true }
        return false
    }

    // MARK: - Networking

    static func fetch(cookie: String, site: Site) async throws -> Data {
        guard let url = URL(string: site.usageURL) else { throw CollectorError.invalidURL("qoder usage") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue(site.origin, forHTTPHeaderField: "Origin")
        request.setValue("\(site.origin)/account/usage", forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(bxVersion, forHTTPHeaderField: "Bx-V")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.notSignedIn("Qoder: session expired (sign in again)")
        }
        // Reject a cross-origin redirect that could have leaked the cookie.
        if let responseHost = http?.url?.host?.lowercased(),
           let requestHost = url.host?.lowercased(), responseHost != requestHost {
            throw CollectorError.notSignedIn("Qoder: redirected off-origin")
        }
        guard (200..<300).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "Qoder")
        }
        return data
    }

    // MARK: - Parse (pure; total + shared additive; camel + snake keys)

    struct Snapshot: Sendable, Equatable {
        var usedCredits: Double
        var totalCredits: Double
        var remainingCredits: Double
        var usagePercentage: Double
        var unit: String?
        var resetsAt: Date?
    }

    static func parse(_ data: Data) throws -> Snapshot {
        let response: Response
        do {
            response = try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Qoder: invalid JSON (\(error.localizedDescription))")
        }
        guard let base = response.totalQuota?.quotaSummary else {
            throw CollectorError.parseFailed("Qoder: missing totalQuota.quotaSummary")
        }
        let shared = response.sharedQuota?.quotaSummary

        let baseRemaining = try remaining(for: base)
        var used = base.usedValue, total = base.limitValue, remaining = baseRemaining
        if let shared {
            used += shared.usedValue
            total += shared.limitValue
            remaining += try Self.remaining(for: shared)
        }
        let pct = try percentage(used: used, total: total, provided: shared == nil ? base.usagePercentage : nil)
        return Snapshot(
            usedCredits: used, totalCredits: total, remainingCredits: remaining,
            usagePercentage: pct, unit: base.unit ?? shared?.unit, resetsAt: response.nextResetAt)
    }

    private static func remaining(for s: QuotaSummary) throws -> Double {
        guard s.usedValue >= 0, s.limitValue >= 0, (s.remainingValue.map { $0 >= 0 } ?? true) else {
            throw CollectorError.parseFailed("Qoder: quota values must be nonnegative")
        }
        return s.remainingValue ?? max(0, s.limitValue - s.usedValue)
    }

    private static func percentage(used: Double, total: Double, provided: Double?) throws -> Double {
        guard used >= 0, total >= 0 else { throw CollectorError.parseFailed("Qoder: negative quota") }
        guard total > 0 else {
            guard used == 0 else { throw CollectorError.parseFailed("Qoder: nonzero use of zero quota") }
            return provided ?? 100
        }
        return provided ?? (used / total) * 100
    }

    // MARK: - Result building (.quota credits)

    static func buildResult(_ s: Snapshot) -> CollectorResult {
        let unit = s.unit?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unitSuffix = (unit?.isEmpty == false) ? " \(unit!)" : " credits"
        let total = creditInt(s.totalCredits)
        let remaining = min(total, creditInt(s.remainingCredits))
        let reset = s.resetsAt.map { sharedISO8601Formatter.string(from: $0) }
        let tier = TierDTO(name: "Credits", quota: total, remaining: remaining, reset_time: reset)
        let status = "\(remaining) / \(total)\(unitSuffix) left"

        let usage = ProviderUsage(
            provider: ProviderKind.qoder.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: total, remaining: remaining, plan_type: "Qoder",
            reset_time: reset, tiers: [tier],
            status_text: status, trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Qoder", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    /// Non-negative credit magnitude, saturating instead of trapping `Int(Double)`
    /// on a finite-but-huge value (e.g. an "unlimited" plan's Int64.max sentinel).
    static func creditInt(_ value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 0 }
        return value >= Double(Int.max) ? Int.max : Int(value.rounded())
    }

    // MARK: - Response DTOs (camelCase ?? snake_case)

    private struct Response: Decodable {
        let totalQuota: Container?
        let sharedQuota: Container?
        let nextResetAt: Date?

        private enum CodingKeys: String, CodingKey {
            case totalQuota, totalQuotaSnake = "total_quota"
            case sharedQuota, sharedQuotaSnake = "shared_quota"
            case nextResetAt, nextResetAtSnake = "next_reset_at"
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            totalQuota = try c.decodeIfPresent(Container.self, forKey: .totalQuota)
                ?? c.decodeIfPresent(Container.self, forKey: .totalQuotaSnake)
            sharedQuota = try c.decodeIfPresent(Container.self, forKey: .sharedQuota)
                ?? c.decodeIfPresent(Container.self, forKey: .sharedQuotaSnake)
            nextResetAt = Self.date(c, .nextResetAt) ?? Self.date(c, .nextResetAtSnake)
        }
        private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Date? {
            if let s = try? c.decode(String.self, forKey: key) { return iso(s) }
            if let v = try? c.decode(Double.self, forKey: key) {
                return Date(timeIntervalSince1970: v > 10_000_000_000 ? v / 1000 : v)
            }
            return nil
        }
        private static func iso(_ s: String) -> Date? {
            let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = frac.date(from: s) { return d }
            let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }
    }

    private struct Container: Decodable {
        let quotaSummary: QuotaSummary?
        private enum CodingKeys: String, CodingKey { case quotaSummary, quotaSummarySnake = "quota_summary" }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            quotaSummary = try c.decodeIfPresent(QuotaSummary.self, forKey: .quotaSummary)
                ?? c.decodeIfPresent(QuotaSummary.self, forKey: .quotaSummarySnake)
        }
    }

    struct QuotaSummary: Decodable {
        let usedValue: Double
        let limitValue: Double
        let remainingValue: Double?
        let usagePercentage: Double?
        let unit: String?
        private enum CodingKeys: String, CodingKey {
            case usedValue, usedValueSnake = "used_value"
            case limitValue, limitValueSnake = "limit_value"
            case remainingValue, remainingValueSnake = "remaining_value"
            case usagePercentage, usagePercentageSnake = "usage_percentage"
            case unit
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            usedValue = try c.decodeIfPresent(Double.self, forKey: .usedValue)
                ?? c.decode(Double.self, forKey: .usedValueSnake)
            limitValue = try c.decodeIfPresent(Double.self, forKey: .limitValue)
                ?? c.decode(Double.self, forKey: .limitValueSnake)
            remainingValue = try c.decodeIfPresent(Double.self, forKey: .remainingValue)
                ?? c.decodeIfPresent(Double.self, forKey: .remainingValueSnake)
            usagePercentage = try c.decodeIfPresent(Double.self, forKey: .usagePercentage)
                ?? c.decodeIfPresent(Double.self, forKey: .usagePercentageSnake)
            unit = try c.decodeIfPresent(String.self, forKey: .unit)
        }
    }
}
#endif
