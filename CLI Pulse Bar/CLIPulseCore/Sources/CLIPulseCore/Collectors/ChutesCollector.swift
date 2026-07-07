// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Chutes/{ChutesUsageStats,
// ChutesSettingsReader}.swift (https://github.com/steipete/CodexBar). The
// rolling-4h / monthly window model, the used/limit/remaining ⇒ usedPercent
// derivation, the flexible epoch(sec|ms)/ISO8601 reset parse, and the label
// key families are ported; the fetch is reimplemented on CLI Pulse's api-key
// collector idiom and mapped to `.quota`.
//
// v1.40.0 — add the (absent) Chutes provider: the `subscription_usage`
// endpoint's rolling-4h (primary) + monthly (secondary) quota windows. Bearer
// CHUTES_API_KEY (or config apiKey).
//
// Divergences from upstream (deliberate — plan §1b):
//   * PRIMARY SHAPE ONLY. Upstream's 1045-LOC parser is intentional over-
//     tolerance (recursive quota-object discovery, dedup, a full subscription-
//     state machine, and a `/quotas` + per-quota-usage fallback endpoint). We
//     port the two named windows off `subscription_usage` with a sane key
//     subset and skip the kitchen-sink discovery until users report variants.
//   * `URLSession` instead of ProviderHTTPClient; no CodexBarLog.
//   * On auth-OK-but-no-parseable-window (schema drift) we degrade to
//     `.statusOnly "Connected"` rather than a hard parse failure (Grok C-23
//     graceful-fallback precedent).
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

/// Reports Chutes rolling-4h + monthly quota windows via Bearer api-key.
///
/// `GET https://api.chutes.ai/users/me/subscription_usage`,
/// `Authorization: Bearer <apiKey>`. Key: `config.apiKey` or env `CHUTES_API_KEY`.
public struct ChutesCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.chutes

    private static let usageURL = "https://api.chutes.ai/users/me/subscription_usage"
    private static let envVars = ["CHUTES_API_KEY", "CHUTES_KEY"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("Chutes: no API key (set CHUTES_API_KEY)")
        }
        let data = try await fetchUsage(token: token)
        let snapshot = try Self.parse(data)
        return Self.buildResult(snapshot)
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

    private func fetchUsage(token: String) async throws -> Data {
        guard let url = URL(string: Self.usageURL) else {
            throw CollectorError.invalidURL("chutes subscription_usage")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.notSignedIn("Chutes: API key rejected (401/403)")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "Chutes")
        }
        return data
    }

    // MARK: - Parse (pure)

    struct Window: Sendable, Equatable {
        var usedPercent: Double     // clamped 0…100
        var resetsAt: Date?
    }

    struct Snapshot: Sendable, Equatable {
        var rolling: Window?
        var monthly: Window?
        var planName: String?
    }

    static func parse(_ data: Data) throws -> Snapshot {
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            throw CollectorError.parseFailed("Chutes: invalid JSON")
        }
        let root: [String: Any] = (object as? [String: Any]) ?? [:]
        let dataRoot = dictionary(root["data"]) ?? dictionary(root["result"]) ?? root

        let rolling = firstDictionary(root, dataRoot, keys: rollingKeys).flatMap(parseWindow)
        let monthly = firstDictionary(root, dataRoot, keys: monthlyKeys).flatMap(parseWindow)
        let plan = firstString(root, keys: planKeys) ?? firstString(dataRoot, keys: planKeys)
        return Snapshot(rolling: rolling, monthly: monthly, planName: plan)
    }

    private static func parseWindow(_ payload: [String: Any]) -> Window? {
        var used = firstDouble(payload, keys: usedKeys)
        var limit = firstDouble(payload, keys: limitKeys)
        var remaining = firstDouble(payload, keys: remainingKeys)

        var usedPercent = normalizedPercent(firstDouble(payload, keys: percentUsedKeys))
        if usedPercent == nil, let remPct = normalizedPercent(firstDouble(payload, keys: percentRemainingKeys)) {
            usedPercent = 100 - remPct
        }

        // Fill the missing leg of used/limit/remaining, then derive a percent.
        if limit == nil, let u = used, let r = remaining { limit = u + r }
        if used == nil, let l = limit, let r = remaining { used = l - r }
        if remaining == nil, let l = limit, let u = used { remaining = max(0, l - u) }

        if usedPercent == nil, let u = used, let l = limit, l > 0 {
            usedPercent = (u / l) * 100
        }

        guard let pct = usedPercent else { return nil }
        return Window(usedPercent: clamp(pct), resetsAt: firstDate(payload, keys: resetKeys))
    }

    // MARK: - Result building (.quota windows; .statusOnly fallback)

    static func buildResult(_ s: Snapshot) -> CollectorResult {
        let plan = s.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let planType = (plan?.isEmpty == false) ? plan! : "Chutes"

        func tier(_ name: String, _ w: Window) -> TierDTO {
            let remaining = Int((100 - clamp(w.usedPercent)).rounded())
            let reset = w.resetsAt.map { sharedISO8601Formatter.string(from: $0) }
            return TierDTO(name: name, quota: 100, remaining: remaining, reset_time: reset)
        }

        var tiers: [TierDTO] = []
        if let r = s.rolling { tiers.append(tier("4-hour", r)) }
        if let m = s.monthly { tiers.append(tier("Monthly", m)) }

        guard !tiers.isEmpty else {
            // Auth worked but no window parsed (schema drift) — graceful status.
            let usage = ProviderUsage(
                provider: ProviderKind.chutes.rawValue,
                today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: nil, remaining: nil, plan_type: planType, reset_time: nil, tiers: [],
                status_text: "Connected",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(display_name: "Chutes", category: "cloud",
                                           supports_exact_cost: false, supports_quota: false))
            return CollectorResult(usage: usage, dataKind: .statusOnly)
        }

        // Primary gauge = rolling if present, else monthly.
        let primary = s.rolling ?? s.monthly!
        let primaryRemaining = Int((100 - clamp(primary.usedPercent)).rounded())
        var status = "\(s.rolling != nil ? "4-hour" : "Monthly") \(primaryRemaining)% left"
        if s.rolling != nil, let m = s.monthly {
            status += " · Monthly \(Int((100 - clamp(m.usedPercent)).rounded()))% left"
        }

        let usage = ProviderUsage(
            provider: ProviderKind.chutes.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: primaryRemaining, plan_type: planType,
            reset_time: tiers.first?.reset_time, tiers: tiers,
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Chutes", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    // MARK: - JSON helpers

    static func clamp(_ p: Double) -> Double { max(0, min(100, p)) }

    private static func normalizedPercent(_ v: Double?) -> Double? {
        guard let v, v.isFinite else { return nil }
        return max(0, min(100, v))
    }

    private static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }

    private static func firstDictionary(
        _ root: [String: Any], _ dataRoot: [String: Any], keys: [String]) -> [String: Any]?
    {
        for k in keys {
            if let d = dictionary(root[k]) { return d }
            if let d = dictionary(dataRoot[k]) { return d }
        }
        return nil
    }

    private static func firstDouble(_ dict: [String: Any], keys: [String]) -> Double? {
        for k in keys { if let v = double(dict[k]) { return v } }
        return nil
    }

    private static func firstString(_ dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private static func firstDate(_ dict: [String: Any], keys: [String]) -> Date? {
        for k in keys { if let d = date(from: dict[k]) { return d } }
        return nil
    }

    static func double(_ raw: Any?) -> Double? {
        if raw is Bool { return nil }
        if let d = raw as? Double { return d.isFinite ? d : nil }
        if let n = raw as? NSNumber { let d = n.doubleValue; return d.isFinite ? d : nil }
        if let s = raw as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: "%", with: "")
            guard !t.isEmpty, let d = Double(t), d.isFinite else { return nil }
            return d
        }
        return nil
    }

    static func date(from raw: Any?) -> Date? {
        switch raw {
        case let n as NSNumber:
            return epochDate(n.doubleValue)
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(t) { return epochDate(numeric) }
            return sharedISO8601Formatter.date(from: t)
        default:
            return nil
        }
    }

    private static func epochDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        // ms if the magnitude is clearly beyond a plausible seconds epoch.
        let seconds = value > 10_000_000_000 ? value / 1000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: - Key families (primary-shape subset)

    private static let rollingKeys = [
        "rolling", "rolling_window", "rollingWindow", "rolling_4h", "rolling4h",
        "four_hour", "fourHour", "four_hour_usage", "fourHourUsage",
    ]
    private static let monthlyKeys = [
        "monthly", "monthly_usage", "monthlyUsage", "subscription", "subscription_usage",
        "subscriptionUsage", "billing_period", "billingPeriod",
    ]
    private static let limitKeys = [
        "limit", "quota", "cap", "max", "maximum", "total", "quota_limit", "quotaLimit",
        "hard_limit", "hardLimit",
    ]
    private static let usedKeys = [
        "used", "usage", "consumed", "current", "used_amount", "usedAmount",
        "requests", "request_count", "requestCount", "tokens",
    ]
    private static let remainingKeys = ["remaining", "available", "balance", "left"]
    private static let percentUsedKeys = [
        "percent_used", "percentUsed", "used_percent", "usedPercent",
        "usage_percent", "usagePercent", "utilization", "utilizationPercent",
    ]
    private static let percentRemainingKeys = [
        "percent_remaining", "percentRemaining", "remaining_percent", "remainingPercent",
    ]
    private static let resetKeys = [
        "reset_at", "resetAt", "resets_at", "resetsAt", "reset_time", "resetTime",
        "next_reset_at", "nextResetAt", "period_end", "periodEnd",
        "current_period_end", "currentPeriodEnd", "expires_at", "expiresAt",
        "renews_at", "renewsAt",
    ]
    private static let planKeys = [
        "plan", "plan_name", "planName", "tier", "subscription_type", "subscriptionType",
        "product", "product_name", "productName",
    ]
}
#endif
