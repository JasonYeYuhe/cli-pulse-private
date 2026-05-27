// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Alibaba/{AlibabaTokenPlanUsageFetcher,
// AlibabaTokenPlanUsageSnapshot}.swift (https://github.com/steipete/CodexBar).
// The gateway request shape, the sec_token HTML scrape, the CSRF handling, the
// expandedJSON + verbatim key-sets + defensive recursive find, and the quota
// mapping are ported; the fetch is reimplemented on CLI Pulse's `CookieResolver`
// seam + URLSession.
//
// CodexBar-parity Phase C-20 — add the (absent) Alibaba Bailian **Token Plan**
// subscription. DISTINCT from CLI Pulse's existing Alibaba (the *coding plan*,
// queryCodingPlanInstanceInfoV2). Heaviest cookie port.
//
// CAVEAT: console-internal API (no public docs, no live token to test). This
// is a best-effort verbatim transcription; graceful errors + a depth-limited
// defensive parser mitigate. Fragile to upstream console changes.
//
// Divergences from upstream: `URLSession`/`CookieResolver`; no CodexBarLog; no
// RedirectDiagnostics; recursion depth-limited to 10 (Gemini C-20 R1 MEDIUM).
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

/// Fetches Alibaba Bailian Token Plan subscription usage via console cookies.
public struct AlibabaTokenPlanCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.alibabaTokenPlan

    private static let envVars = ["ALIBABA_TOKENPLAN_COOKIE", "ALIBABA_COOKIE"]
    private static let cookieDomains = ["bailian.console.aliyun.com", "aliyun.com"]
    private static let knownSessionNames: Set<String> = []
    // v1.26 A3: upstream (CodexBar 3be413f) switched the usage refresh from
    // the BSP gateway's `zeldaEasy.bailian-commerce.tokenPlan.*` API to the
    // Bailian subscription-summary endpoint. The old gateway host
    // (bailian-cs.console.aliyun.com) + BroadScopeAspnGateway action returns
    // empty payloads since the API drift.
    static let gatewayBase = "https://bailian.console.aliyun.com"
    static let dashboardURLString = "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan"
    static let bssServiceCode = "BssOpenAPI-V3"
    static let subscriptionSummaryAction = "GetSubscriptionSummary"
    static let productCode = "sfm_tokenplanteams_dp_cn"
    static let regionID = "cn-beijing"
    static let maxDepth = 10
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config, envVarNames: Self.envVars,
            domains: Self.cookieDomains, knownSessionCookieNames: Self.knownSessionNames)
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("Alibaba Token Plan: no console cookie")
        }
        guard Self.csrf(from: cookie) != nil else {
            throw CollectorError.missingCredentials("Alibaba Token Plan: cookie has no CSRF token (log in)")
        }
        let secToken = await Self.resolveSECToken(cookie: cookie)
        let data = try await fetchUsage(cookie: cookie, secToken: secToken)
        let snapshot = try Self.parseUsage(data)
        return Self.buildResult(snapshot)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty { return true }
        return false
    }

    // MARK: - Cookie helpers

    static func csrf(from cookie: String) -> String? {
        extractCookieValue("login_aliyunid_csrf", cookie) ?? extractCookieValue("csrf", cookie)
    }

    static func extractCookieValue(_ name: String, _ header: String) -> String? {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            if pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(name) == .orderedSame {
                let v = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    // MARK: - sec_token (HTML scrape, cookie fallback — Gemini C-20 R1 HIGH)

    static func resolveSECToken(cookie: String) async -> String? {
        guard let url = URL(string: dashboardURLString) else { return extractCookieValue("sec_token", cookie) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        if let (data, response) = try? await URLSession.shared.data(for: request),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let html = String(data: data, encoding: .utf8),
           let token = extractSECToken(from: html) {
            return token
        }
        return extractCookieValue("sec_token", cookie)
    }

    static func extractSECToken(from html: String) -> String? {
        let patterns = [
            #""secToken"\s*:\s*"([^"]+)""#,
            #""sec_token"\s*:\s*"([^"]+)""#,
            #"secToken['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"sec_token['"]?\s*[:=]\s*['"]([^'"]+)['"]"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            if let m = regex.firstMatch(in: html, range: range), m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: html) {
                let token = String(html[r])
                if !token.isEmpty { return token }
            }
        }
        return nil
    }

    // MARK: - Request

    private func fetchUsage(cookie: String, secToken: String?) async throws -> Data {
        var components = URLComponents(string: Self.gatewayBase + "/data/api.json")!
        components.queryItems = [
            URLQueryItem(name: "action", value: Self.subscriptionSummaryAction),
            URLQueryItem(name: "product", value: Self.bssServiceCode),
            URLQueryItem(name: "_tag", value: ""),
        ]
        guard let url = components.url else { throw CollectorError.invalidURL("alibaba tokenplan") }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.httpBody = Self.requestBody(secToken: secToken)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        if let csrf = Self.csrf(from: cookie) {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://bailian.console.aliyun.com", forHTTPHeaderField: "Origin")
        request.setValue(Self.dashboardURLString, forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("Alibaba Token Plan: login required")
        }
        guard status == 200 else { throw CollectorError.httpError(status: status, provider: "Alibaba Token Plan") }
        return data
    }

    static func requestBody(secToken: String?) -> Data {
        // v1.26 A3: the subscription-summary endpoint expects a simple
        // `{"ProductCode": "..."}` payload. The legacy `cornerstoneParam` /
        // anonymousID / Api+V envelope is no longer accepted.
        let params: [String: Any] = ["ProductCode": productCode]
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
              let paramsString = String(data: paramsData, encoding: .utf8) else { return Data() }
        var components = URLComponents()
        var items = [
            URLQueryItem(name: "product", value: bssServiceCode),
            URLQueryItem(name: "action", value: subscriptionSummaryAction),
            URLQueryItem(name: "params", value: paramsString),
            URLQueryItem(name: "region", value: regionID),
        ]
        if let secToken, !secToken.isEmpty { items.append(URLQueryItem(name: "sec_token", value: secToken)) }
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    // MARK: - Parse (depth-limited defensive find; ported key-sets)

    struct Snapshot: Sendable, Equatable {
        var planName: String?
        var used: Double?
        var total: Double?
        var remaining: Double?
        var resetsAt: Date?
    }

    static func parseUsage(_ data: Data) throws -> Snapshot {
        guard !data.isEmpty else { throw CollectorError.parseFailed("Alibaba Token Plan: empty response") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch {
            if isLoginHTML(data) { throw CollectorError.missingCredentials("Alibaba Token Plan: login required") }
            throw CollectorError.parseFailed("Alibaba Token Plan: invalid JSON")
        }
        let expanded = expandedJSON(object, depth: 0)
        guard let dict = expanded as? [String: Any] else {
            throw CollectorError.parseFailed("Alibaba Token Plan: unexpected payload")
        }
        try throwIfError(dict)

        // v1.26 A3: prefer the `Data` / `data` subtree of the
        // GetSubscriptionSummary response — it carries the
        // TotalValue / TotalSurplusValue / TotalCount fields. Fall
        // back to a depth-limited search so legacy payloads (still
        // surfaced by some cached cookies) keep working.
        let summary = findSubscriptionSummary(in: dict) ?? dict
        let used = anyDouble(usedQuotaKeys, summary)
        let total = anyDouble(totalQuotaKeys, summary)
        let remaining = anyDouble(remainingQuotaKeys, summary)
        // GetSubscriptionSummary reports total + remaining, not used;
        // derive used = max(0, total - remaining) when absent.
        let derivedUsed = used ?? total.flatMap { t in remaining.map { max(0, t - $0) } }
        let totalCount = anyDouble(subscriptionCountKeys, summary)
        let reset = anyDate(resetDateKeys, in: dict, depth: 0)
        let plan = anyString(planNameKeys, in: dict, depth: 0)
            ?? (((totalCount ?? 0) > 0 || total != nil) ? "TOKEN PLAN" : nil)

        guard plan != nil || total != nil || used != nil || remaining != nil || totalCount != nil else {
            throw CollectorError.parseFailed("Alibaba Token Plan: missing token-plan fields")
        }
        return Snapshot(planName: plan, used: derivedUsed, total: total, remaining: remaining, resetsAt: reset)
    }

    /// Locate the subscription-summary dict in a GetSubscriptionSummary
    /// response. Prefers the standard `Data` / `data` envelope when it
    /// already contains quota fields; otherwise scans the tree for the
    /// first dict matching any known quota key — handles both the new
    /// endpoint and any nested `successResponse` wrapping.
    static func findSubscriptionSummary(in payload: [String: Any]) -> [String: Any]? {
        for key in ["Data", "data", "successResponse", "success_response"] {
            if let nested = payload[key] as? [String: Any], containsSummaryFields(nested) {
                return nested
            }
        }
        return firstDict(
            containingAnyKey: usedQuotaKeys + totalQuotaKeys + remainingQuotaKeys + subscriptionCountKeys,
            in: payload, depth: 0)
    }

    static func containsSummaryFields(_ payload: [String: Any]) -> Bool {
        let keys = usedQuotaKeys + totalQuotaKeys + remainingQuotaKeys + subscriptionCountKeys
        return keys.contains { payload[$0] != nil }
    }

    static func buildResult(_ s: Snapshot) -> CollectorResult {
        let plan = (s.planName?.isEmpty == false) ? s.planName! : "Token Plan"
        let resetISO = s.resetsAt.map { sharedISO8601Formatter.string(from: $0) }
        if let total = s.total, total > 0 {
            let totalInt = Int(total.rounded())
            let remainingInt: Int = {
                if let r = s.remaining { return max(0, min(Int(r.rounded()), totalInt)) }
                if let u = s.used { return max(0, totalInt - Int(u.rounded())) }
                return totalInt
            }()
            let usedInt = max(0, totalInt - remainingInt)
            let usage = ProviderUsage(
                provider: ProviderKind.alibabaTokenPlan.rawValue,
                today_usage: usedInt, week_usage: usedInt,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: totalInt, remaining: remainingInt, plan_type: plan, reset_time: resetISO,
                tiers: [TierDTO(name: "Token Plan", quota: totalInt, remaining: remainingInt, reset_time: resetISO)],
                status_text: "\(compact(Double(usedInt)))/\(compact(total)) credits used",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(display_name: "Alibaba Token Plan", category: "cloud",
                                           supports_exact_cost: false, supports_quota: true))
            return CollectorResult(usage: usage, dataKind: .quota)
        }
        // No cap ⇒ status-only.
        let statusText = s.remaining.map { "\(compact($0)) credits left" } ?? "Connected"
        let usage = ProviderUsage(
            provider: ProviderKind.alibabaTokenPlan.rawValue,
            today_usage: 0, week_usage: 0, estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: nil, plan_type: plan, reset_time: resetISO, tiers: [],
            status_text: statusText, trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Alibaba Token Plan", category: "cloud",
                                       supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .statusOnly)
    }

    // MARK: - Vendored key-sets

    static let planNameKeys = ["planName", "plan_name", "packageName", "package_name", "commodityName",
                               "commodity_name", "instanceName", "instance_name", "displayName", "display_name",
                               "ProductName", "productName",
                               "name", "title", "planType", "plan_type"]
    static let usedQuotaKeys = ["usedQuota", "used_quota", "usedCredits", "usedCredit", "consumedCredits",
                                "usage", "used", "usedAmount", "consumeAmount",
                                "usedValue", "UsedValue", "consumedValue", "ConsumedValue"]
    static let totalQuotaKeys = ["totalQuota", "total_quota", "totalCredits", "totalCredit", "quota",
                                 "creditLimit", "creditsTotal", "monthlyTotalQuota", "amount",
                                 "totalValue", "TotalValue"]
    static let remainingQuotaKeys = ["remainingQuota", "remainQuota", "remainingCredits", "remainingCredit",
                                     "availableCredits", "balance", "remaining", "availableAmount", "remainAmount",
                                     "totalSurplusValue", "TotalSurplusValue", "surplusValue", "SurplusValue"]
    // v1.26 A3: GetSubscriptionSummary can carry a "TotalCount" alone
    // (an active subscription with no quota window — status-only).
    static let subscriptionCountKeys = ["totalCount", "TotalCount",
                                        "subscriptionTotalNumber", "SubscriptionTotalNumber"]
    static let resetDateKeys = ["nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd",
                                "billCycleEndTime", "expireTime", "expirationTime", "endTime", "validEndTime",
                                "instanceEndTime",
                                "nearestExpireDate", "NearestExpireDate"]

    // MARK: - Defensive helpers (depth-limited)

    static func throwIfError(_ dict: [String: Any]) throws {
        // v1.26 A3: GetSubscriptionSummary returns `Success: false` (or
        // `success: false`) on auth / lookup failures before the legacy
        // `statusCode`-shaped error envelope. Check that first.
        for k in ["Success", "success"] {
            if let raw = dict[k], let ok = parseBool(raw), !ok {
                let msg = ["Message", "message", "msg", "Code", "code"]
                    .compactMap { (dict[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty }) ?? "request was not successful"
                let lowered = msg.lowercased()
                if lowered.contains("needlogin") || lowered.contains("login") || lowered.contains("log in") {
                    throw CollectorError.missingCredentials("Alibaba Token Plan: login required")
                }
                throw CollectorError.parseFailed("Alibaba Token Plan: \(msg)")
            }
        }
        for k in ["statusCode", "status_code", "code"] {
            if let code = parseInt(dict[k]), code != 0, code != 200 {
                if code == 401 || code == 403 {
                    throw CollectorError.missingCredentials("Alibaba Token Plan: login required")
                }
                let msg = ["statusMessage", "message", "msg"].compactMap { dict[$0] as? String }.first
                throw CollectorError.parseFailed("Alibaba Token Plan: \(msg ?? "code \(code)")")
            }
        }
        let texts = ["code", "status", "message", "msg"].compactMap { (dict[$0] as? String)?.lowercased() }
        if texts.contains(where: { $0.contains("login") || $0.contains("log in") }) {
            throw CollectorError.missingCredentials("Alibaba Token Plan: login required")
        }
    }

    static func parseBool(_ raw: Any) -> Bool? {
        if let b = raw as? Bool { return b }
        if let n = raw as? NSNumber { return n.boolValue }
        if let s = raw as? String {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func expandedJSON(_ value: Any, depth: Int) -> Any {
        guard depth < maxDepth else { return value }
        if let dict = value as? [String: Any] {
            return dict.mapValues { expandedJSON($0, depth: depth + 1) }
        }
        if let array = value as? [Any] { return array.map { expandedJSON($0, depth: depth + 1) } }
        if let s = value as? String, let d = s.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: d),
           nested is [String: Any] || nested is [Any] {
            return expandedJSON(nested, depth: depth + 1)
        }
        return value
    }

    static func firstDict(containingAnyKey keys: [String], in value: Any, depth: Int) -> [String: Any]? {
        guard depth < maxDepth else { return nil }
        if let dict = value as? [String: Any] {
            if keys.contains(where: { dict[$0] != nil }) { return dict }
            for v in dict.values {
                if let f = firstDict(containingAnyKey: keys, in: v, depth: depth + 1) { return f }
            }
        }
        if let array = value as? [Any] {
            for v in array {
                if let f = firstDict(containingAnyKey: keys, in: v, depth: depth + 1) { return f }
            }
        }
        return nil
    }

    static func anyDouble(_ keys: [String], _ dict: [String: Any]) -> Double? {
        for k in keys { if let v = parseDouble(dict[k]) { return v } }
        return nil
    }

    static func anyString(_ keys: [String], in value: Any, depth: Int) -> String? {
        guard depth < maxDepth else { return nil }
        if let dict = value as? [String: Any] {
            for k in keys { if let s = (dict[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !s.isEmpty { return s } }
            for v in dict.values { if let f = anyString(keys, in: v, depth: depth + 1) { return f } }
        }
        if let array = value as? [Any] {
            for v in array { if let f = anyString(keys, in: v, depth: depth + 1) { return f } }
        }
        return nil
    }

    static func anyDate(_ keys: [String], in value: Any, depth: Int) -> Date? {
        guard depth < maxDepth else { return nil }
        if let dict = value as? [String: Any] {
            for k in keys { if let d = parseDate(dict[k]) { return d } }
            for v in dict.values { if let f = anyDate(keys, in: v, depth: depth + 1) { return f } }
        }
        if let array = value as? [Any] {
            for v in array { if let f = anyDate(keys, in: v, depth: depth + 1) { return f } }
        }
        return nil
    }

    static func parseInt(_ raw: Any?) -> Int? {
        if let v = raw as? Int { return v }
        if let v = raw as? NSNumber { return v.intValue }
        if let s = raw as? String { return Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    static func parseDouble(_ raw: Any?) -> Double? {
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        if let s = raw as? String {
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    static func parseDate(_ raw: Any?) -> Date? {
        if let i = parseInt(raw) {
            return Date(timeIntervalSince1970: i > 1_000_000_000_000 ? TimeInterval(i) / 1000 : TimeInterval(i))
        }
        if let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return nil
    }

    static func isLoginHTML(_ data: Data) -> Bool {
        guard let t = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return t.contains("<html") && (t.contains("login") || t.contains("sign in"))
    }

    static func compact(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.usesGroupingSeparator = true
        f.maximumFractionDigits = value.rounded() == value ? 0 : 2
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
#endif
