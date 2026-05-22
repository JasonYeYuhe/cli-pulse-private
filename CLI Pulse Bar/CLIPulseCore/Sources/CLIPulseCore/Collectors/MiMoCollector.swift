// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/MiMo/{MiMoUsageFetcher,MiMoCookieImporter,
// MiMoUsageSnapshot}.swift (https://github.com/steipete/CodexBar). The
// balance/tokenPlan response models, the required-cookie validation, the
// three-endpoint shape, and the period-end date parse are ported; the fetch is
// reimplemented on CLI Pulse's G1 `CookieResolver` seam + URLSession.
//
// CodexBar-parity Phase C-18 — add the (absent) MiMo provider (Xiaomi 小米,
// platform.xiaomimimo.com). LAST of the niche cookie batch. Hybrid: a
// token-plan quota (used/limit) + a monetary balance (currency, likely CNY).
//
// Divergences from upstream:
//   * `URLSession`; no CodexBarLog. 3 endpoints run CONCURRENTLY (`async let`,
//     balance required + detail/usage best-effort) ⇒ ~15s bound.
//   * the monetary balance is shown in status_text (currency-coded), NOT mapped
//     to `.credits` — CLI Pulse's `.credits` is hardcoded to a USD/100_000
//     scale and the balance is likely CNY (Gemini C-18 R1 Q1/Q2).
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

/// Fetches MiMo (Xiaomi) token-plan usage + monetary balance via session cookie.
///
/// `GET {base}/balance` (required) + `/tokenPlan/{detail,usage}` (best-effort).
/// Auth: `Cookie:` header carrying `api-platform_serviceToken` + `userId`,
/// from auto-import / manual paste / env `MIMO_COOKIE`. Base from env
/// `MIMO_API_URL` (default `platform.xiaomimimo.com/api/v1`).
public struct MiMoCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.mimo

    private static let envVars = ["MIMO_COOKIE"]
    private static let cookieDomains = ["platform.xiaomimimo.com", "xiaomimimo.com"]
    static let requiredCookieNames: Set<String> = ["api-platform_serviceToken", "userId"]
    static let knownCookieNames: Set<String> = requiredCookieNames.union([
        "api-platform_ph", "api-platform_slh",
    ])
    static let apiURLEnv = "MIMO_API_URL"
    static let defaultBase = "https://platform.xiaomimimo.com/api/v1"

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.requiredCookieNames)
        guard let header = resolution.headerValue,
              let cookie = Self.normalizedHeader(from: header) else {
            throw CollectorError.missingCredentials(
                "MiMo: cookie needs api-platform_serviceToken + userId (log in at platform.xiaomimimo.com)")
        }
        let base = Self.resolveBase()
        async let balanceData = Self.fetchAuthenticated(urlString: base + "/balance", cookie: cookie)
        async let detailData: Data? = try? await Self.fetchAuthenticated(
            urlString: base + "/tokenPlan/detail", cookie: cookie)
        async let usageData: Data? = try? await Self.fetchAuthenticated(
            urlString: base + "/tokenPlan/usage", cookie: cookie)

        let (balance, currency) = try Self.parseBalance(try await balanceData)
        let detail = (await detailData).flatMap { try? Self.parseDetail($0) } ?? (nil, nil, false)
        let usage = (await usageData).flatMap { try? Self.parseUsage($0) } ?? (0, 0)

        return Self.buildResult(
            balance: balance, currency: currency,
            planCode: detail.0, periodEnd: detail.1, expired: detail.2,
            used: usage.0, limit: usage.1)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    static func resolveBase() -> String {
        if let raw = ProcessInfo.processInfo.environment[apiURLEnv]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }
        return defaultBase
    }

    // MARK: - Cookie (require serviceToken + userId; clean filtered header)

    static func normalizedHeader(from raw: String) -> String? {
        var byName: [String: String] = [:]
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard knownCookieNames.contains(name), !value.isEmpty else { continue }
            byName[name] = value
        }
        guard requiredCookieNames.isSubset(of: Set(byName.keys)) else { return nil }
        return byName.keys.sorted().map { "\($0)=\(byName[$0]!)" }.joined(separator: "; ")
    }

    // MARK: - Networking

    private static func fetchAuthenticated(urlString: String, cookie: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CollectorError.invalidURL("mimo") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://platform.xiaomimimo.com", forHTTPHeaderField: "Origin")
        request.setValue("https://platform.xiaomimimo.com/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("MiMo: session expired (log in again)")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "MiMo")
        }
        return data
    }

    // MARK: - Parse (code==0 envelope)

    static func parseBalance(_ data: Data) throws -> (balance: Double?, currency: String) {
        let resp: BalanceResponse
        do { resp = try JSONDecoder().decode(BalanceResponse.self, from: data) }
        catch { throw CollectorError.parseFailed("MiMo: \(error.localizedDescription)") }
        guard resp.code == 0 else {
            if resp.code == 401 || resp.code == 403 {
                throw CollectorError.missingCredentials("MiMo: session expired (log in again)")
            }
            throw CollectorError.parseFailed("MiMo: code \(resp.code)")
        }
        guard let payload = resp.data else { throw CollectorError.parseFailed("MiMo: missing balance payload") }
        // Lenient: a non-numeric balance ⇒ nil (shown "Unknown"), don't drop the
        // whole snapshot (Gemini C-18 R1 LOW).
        return (Double(payload.balance.trimmingCharacters(in: .whitespacesAndNewlines)),
                payload.currency.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Best-effort: code != 0 ⇒ nils (swallowed by the caller's `try?`).
    static func parseDetail(_ data: Data) throws -> (planCode: String?, periodEnd: Date?, expired: Bool) {
        let resp = try JSONDecoder().decode(TokenPlanDetailResponse.self, from: data)
        guard resp.code == 0, let p = resp.data else { return (nil, nil, false) }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)   // UTC (matches upstream)
        return (p.planCode, p.currentPeriodEnd.flatMap { f.date(from: $0) }, p.expired)
    }

    static func parseUsage(_ data: Data) throws -> (used: Int, limit: Int) {
        let resp = try JSONDecoder().decode(TokenPlanUsageResponse.self, from: data)
        guard resp.code == 0, let item = resp.data?.monthUsage?.items.first else { return (0, 0) }
        return (item.used, item.limit)
    }

    // MARK: - Result building (.quota when a live token plan exists; else .statusOnly)

    static func buildResult(
        balance: Double?, currency: String, planCode: String?,
        periodEnd: Date?, expired: Bool, used: Int, limit: Int) -> CollectorResult
    {
        let plan = (planCode?.isEmpty == false) ? planCode! : "MiMo"
        let balanceText: String = {
            guard let balance else { return "balance unavailable" }
            let cur = currency.isEmpty ? "" : "\(currency) "
            return "\(cur)\(String(format: "%.2f", balance))"
        }()

        if limit > 0, !expired {
            let remaining = max(0, limit - used)
            let resetISO = periodEnd.map { sharedISO8601Formatter.string(from: $0) }
            let usage = ProviderUsage(
                provider: ProviderKind.mimo.rawValue,
                today_usage: max(0, used), week_usage: max(0, used),
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: limit, remaining: remaining,
                plan_type: plan, reset_time: resetISO,
                tiers: [TierDTO(name: "Token Plan", quota: limit, remaining: remaining, reset_time: resetISO)],
                status_text: "\(Self.compact(used))/\(Self.compact(limit)) tokens · \(balanceText)",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(
                    display_name: "MiMo", category: "cloud",
                    supports_exact_cost: false, supports_quota: true))
            return CollectorResult(usage: usage, dataKind: .quota)
        }

        // No live token plan ⇒ status-only balance.
        let status = expired ? "\(balanceText) · plan expired" : "\(balanceText) balance"
        let usage = ProviderUsage(
            provider: ProviderKind.mimo.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil,
            plan_type: plan, reset_time: nil, tiers: [],
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "MiMo", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    static func compact(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.locale = Locale(identifier: "en_US_POSIX")
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Vendored response models

    private struct BalanceResponse: Decodable {
        let code: Int
        let data: BalancePayload?
    }
    private struct BalancePayload: Decodable { let balance: String; let currency: String }

    private struct TokenPlanDetailResponse: Decodable {
        let code: Int
        let data: TokenPlanDetailPayload?
    }
    private struct TokenPlanDetailPayload: Decodable {
        let planCode: String?
        let currentPeriodEnd: String?
        let expired: Bool
    }

    private struct TokenPlanUsageResponse: Decodable {
        let code: Int
        let data: TokenPlanUsagePayload?
    }
    private struct TokenPlanUsagePayload: Decodable { let monthUsage: MonthUsage? }
    private struct MonthUsage: Decodable { let items: [UsageItem] }
    private struct UsageItem: Decodable { let used: Int; let limit: Int }
}
#endif
