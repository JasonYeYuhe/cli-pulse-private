// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Codebuff/{CodebuffUsageFetcher,
// CodebuffUsageSnapshot,CodebuffSettingsReader}.swift
// (https://github.com/steipete/CodexBar). The flexible-JSON parse
// (Int|String|Number tolerant), the credits-quota mapping, and the
// resolvedTotal/resolvedUsed derivations are ported; the fetch path is
// reimplemented on URLSession.
//
// CodexBar-parity Phase C-6 — add the (absent) Codebuff provider as a
// `.quota` collector. Codebuff credits have a hard cap + reset, so the
// primary maps to a quota gauge (ElevenLabs precedent). The optional
// weekly window + tier come from a best-effort second endpoint.
//
// Divergences from upstream:
//   * `URLSession` instead of CodexBar's `ProviderHTTPClient`; no
//     CodexBarLog.
//   * Subscription endpoint is best-effort, run CONCURRENTLY with the
//     required usage call and bounded to a ~2s grace window (Gemini
//     C-6 R1 CRITICAL): `DataRefreshManager.runCollectors` runs all
//     collectors in one TaskGroup, so a slow secondary call must NOT
//     block the shared refresh — usage always renders; subscription
//     only enriches if it returns within the grace.
//   * Auth-file token fallback (`~/.codebuff/…`) NOT ported — needs
//     SandboxFileAccess; env + config is the documented path (YAGNI,
//     note as divergence).
//   * Degenerate total≤0 ⇒ `.statusOnly` (VolcanoEngine conditional-
//     dataKind precedent) rather than a misleading 0/healthy gauge.
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

/// Fetches Codebuff credit balance + (best-effort) subscription via
/// Bearer api-key auth.
///
/// Primary: `POST https://www.codebuff.com/api/v1/usage` (body
/// `{"fingerprintId":"clipulse-usage"}`) → credits used/total/remaining
/// + next reset. Secondary (best-effort, ~2s grace): `GET /api/user/
/// subscription` → weekly window + tier + email. Auth:
/// `Authorization: Bearer <key>` (`config.apiKey` or `CODEBUFF_API_KEY`).
public struct CodebuffCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.codebuff

    static let baseURL = "https://www.codebuff.com"
    static let envVar = "CODEBUFF_API_KEY"
    static let subscriptionGraceSeconds: Double = 2

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("Codebuff: no API key (set CODEBUFF_API_KEY)")
        }
        // Concurrent: usage is required (throws); subscription is
        // best-effort and grace-bounded so it can never stall the
        // shared collector TaskGroup (Gemini C-6 R1 CRITICAL).
        async let usageTask = fetchUsage(token: token)
        async let subTask = fetchSubscriptionWithGrace(token: token)
        let usage = try await usageTask
        let subscription = await subTask
        return Self.buildResult(usage: usage, subscription: subscription)
    }

    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        if let k = ProcessInfo.processInfo.environment[Self.envVar]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            return k
        }
        return nil
    }

    // MARK: - Payloads

    struct UsagePayload: Sendable, Equatable {
        var used: Double?
        var total: Double?
        var remaining: Double?
        var nextQuotaReset: Date?
        var autoTopUpEnabled: Bool?
    }

    struct SubscriptionPayload: Sendable, Equatable {
        var tier: String?
        var status: String?
        var email: String?
        var weeklyUsed: Double?
        var weeklyLimit: Double?
        var weeklyResetsAt: Date?
    }

    // MARK: - Networking

    private func fetchUsage(token: String) async throws -> UsagePayload {
        guard let url = URL(string: "\(Self.baseURL)/api/v1/usage") else {
            throw CollectorError.invalidURL("codebuff usage")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["fingerprintId": "clipulse-usage"])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Codebuff")
        }
        return try Self.parseUsage(data)
    }

    /// Best-effort subscription fetch bounded to a ~2s grace window —
    /// races the request against a sleep; whichever finishes first wins.
    /// Returns nil on timeout/failure (usage still renders).
    private func fetchSubscriptionWithGrace(token: String) async -> SubscriptionPayload? {
        await withTaskGroup(of: SubscriptionPayload?.self) { group in
            group.addTask { try? await Self.fetchSubscription(token: token) }
            group.addTask {
                let nanos = UInt64(max(0, Self.subscriptionGraceSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func fetchSubscription(token: String) async throws -> SubscriptionPayload {
        guard let url = URL(string: "\(baseURL)/api/user/subscription") else {
            throw CollectorError.invalidURL("codebuff subscription")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Codebuff")
        }
        return try parseSubscription(data)
    }

    // MARK: - Parsing (flexible JSON — vendored Int|String|Number tolerance)

    static func parseUsage(_ data: Data) throws -> UsagePayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Codebuff: invalid usage JSON")
        }
        return UsagePayload(
            used: double(from: root["usage"]) ?? double(from: root["used"]),
            total: double(from: root["quota"]) ?? double(from: root["limit"]),
            remaining: double(from: root["remainingBalance"]) ?? double(from: root["remaining"]),
            nextQuotaReset: dateValue(from: root["next_quota_reset"]),
            autoTopUpEnabled: root["autoTopupEnabled"] as? Bool ?? root["auto_topup_enabled"] as? Bool)
    }

    static func parseSubscription(_ data: Data) throws -> SubscriptionPayload {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Codebuff: invalid subscription JSON")
        }
        let subscription = root["subscription"] as? [String: Any]
        let rateLimit = root["rateLimit"] as? [String: Any]
        let tier = string(from: subscription?["displayName"])
            ?? string(from: root["displayName"])
            ?? string(from: subscription?["tier"])
            ?? string(from: root["tier"])
            ?? string(from: subscription?["scheduledTier"])
        let email = root["email"] as? String
            ?? (root["user"] as? [String: Any])?["email"] as? String
        return SubscriptionPayload(
            tier: tier,
            status: subscription?["status"] as? String,
            email: email,
            weeklyUsed: double(from: rateLimit?["weeklyUsed"]) ?? double(from: rateLimit?["used"]),
            weeklyLimit: double(from: rateLimit?["weeklyLimit"]) ?? double(from: rateLimit?["limit"]),
            weeklyResetsAt: dateValue(from: rateLimit?["weeklyResetsAt"]))
    }

    static func double(from value: Any?) -> Double? {
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

    static func string(from value: Any?) -> String? {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        default:
            return nil
        }
    }

    /// ISO8601 (fractional or plain) | epoch seconds | epoch millis → Date.
    static func dateValue(from value: Any?) -> Date? {
        switch value {
        case let s as String:
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return nil }
            let frac = ISO8601DateFormatter()
            frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = frac.date(from: t) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let d = plain.date(from: t) { return d }
            if let interval = Double(t), interval.isFinite { return dateFromNumeric(interval) }
            return nil
        case let n as NSNumber:
            let raw = n.doubleValue
            return raw.isFinite ? dateFromNumeric(raw) : nil
        default:
            return nil
        }
    }

    static func dateFromNumeric(_ value: Double) -> Date {
        // Heuristic: > ~year-2286-in-seconds ⇒ the value is milliseconds.
        value > 10_000_000_000
            ? Date(timeIntervalSince1970: value / 1000)
            : Date(timeIntervalSince1970: value)
    }

    // MARK: - Derivations (vendored)

    static func resolvedTotal(_ u: UsagePayload) -> Double? {
        if let t = u.total { return max(0, t) }
        if let used = u.used, let rem = u.remaining { return max(0, used + rem) }
        return nil
    }

    static func resolvedUsed(_ u: UsagePayload) -> Double {
        if let used = u.used { return max(0, used) }
        if let total = resolvedTotal(u), let rem = u.remaining { return max(0, total - rem) }
        return 0
    }

    // MARK: - Result building (.quota when capped; else .statusOnly)

    static func buildResult(usage: UsagePayload, subscription: SubscriptionPayload?) -> CollectorResult {
        let total = resolvedTotal(usage)
        let used = resolvedUsed(usage)
        let resetISO = usage.nextQuotaReset.map { sharedISO8601Formatter.string(from: $0) }
        let planType = subscription?.tier.map { $0.capitalized } ?? "API key"

        // Weekly TierDTO from the (best-effort) subscription.
        var extraTiers: [TierDTO] = []
        if let limit = subscription?.weeklyLimit, limit > 0 {
            let wUsed = max(0, subscription?.weeklyUsed ?? 0)
            let wRemaining = max(0, Int((limit - wUsed).rounded()))
            let wResetISO = subscription?.weeklyResetsAt.map { sharedISO8601Formatter.string(from: $0) }
            extraTiers.append(TierDTO(
                name: "Weekly", quota: Int(limit.rounded()),
                remaining: wRemaining, reset_time: wResetISO))
        }

        guard let total, total > 0 else {
            // Degenerate: a bare balance with no usable cap ⇒ status-only.
            let hasAnyData = usage.remaining != nil || usage.used != nil
            let statusText: String
            if let rem = usage.remaining {
                statusText = "\(Self.compactCredits(rem)) credits remaining"
            } else if hasAnyData {
                statusText = "Credits data unavailable"
            } else {
                statusText = "Connected"
            }
            let u = ProviderUsage(
                provider: ProviderKind.codebuff.rawValue,
                today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: nil, remaining: nil,
                plan_type: planType, reset_time: resetISO, tiers: extraTiers,
                status_text: appendAutoTopUp(statusText, usage.autoTopUpEnabled),
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(
                    display_name: "Codebuff", category: "cloud",
                    supports_exact_cost: false, supports_quota: false))
            return CollectorResult(usage: u, dataKind: .statusOnly)
        }

        let totalInt = Int(total.rounded())
        let remainingInt = usage.remaining.map { max(0, Int($0.rounded())) }
            ?? max(0, totalInt - Int(used.rounded()))
        var tiers: [TierDTO] = [
            TierDTO(name: "Credits", quota: totalInt, remaining: remainingInt, reset_time: resetISO),
        ]
        tiers.append(contentsOf: extraTiers)

        let u = ProviderUsage(
            provider: ProviderKind.codebuff.rawValue,
            today_usage: max(0, Int(used.rounded())), week_usage: max(0, Int(used.rounded())),
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: totalInt, remaining: remainingInt,
            plan_type: planType, reset_time: resetISO, tiers: tiers,
            status_text: appendAutoTopUp("\(Self.compactCredits(Double(remainingInt))) credits remaining",
                                         usage.autoTopUpEnabled),
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Codebuff", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: u, dataKind: .quota)
    }

    static func appendAutoTopUp(_ text: String, _ enabled: Bool?) -> String {
        enabled == true ? "\(text) · auto top-up" : text
    }

    static func compactCredits(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = value >= 1000 ? 0 : 1
        return f.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
    }
}
#endif
