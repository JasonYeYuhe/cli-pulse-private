// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/CommandCode/{CommandCodeUsageFetcher,
// CommandCodeUsageSnapshot,CommandCodePlanCatalog,CommandCodeCookieHeader}.swift
// (https://github.com/steipete/CodexBar). The two-endpoint shape, the
// better-auth cookie extraction, the static plan catalog, and the
// monthly-grant cap/used derivation are ported; the fetch is reimplemented on
// CLI Pulse's G1 `CookieResolver` seam + URLSession and mapped to `.credits`.
//
// CodexBar-parity Phase C-11 — add the (absent) Command Code provider. LAST of
// the cookie batch, most involved mapping: USD `.credits` ($1 = 100_000 units,
// OpenRouter/Perplexity convention), a monthly grant whose CAP comes from a
// static plan catalog (the API returns only *remaining*), + 3 extra balance
// pools (purchased / premium / opensource).
//
// Divergences from upstream (Gemini C-11 R1 GO, all confirmed):
//   * subscription is BEST-EFFORT grace-bounded (Codebuff/Abacus pattern), not
//     a hard `try await` — a flaky secondary endpoint can't tank the shared
//     collector TaskGroup; absent subscription unifies with the free-tier path.
//   * unknown active planId DEGRADES to balance-without-cap (CodexBar throws
//     `unknownPlan`) — robustness over strictness for a shipped app.
//   * ALL credit pools clamped to >= 0 (billing systems briefly report negative
//     during reconciliation — a negative TierDTO breaks the UI; Gemini R1 LOW).
//   * `URLSession` + `CookieResolver`; no CodexBarLog.
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

/// Fetches Command Code USD credits via the better-auth session cookie.
///
/// Credits (required): `GET api.commandcode.ai/internal/billing/credits`.
/// Subscription (best-effort, ~5s): `GET .../internal/billing/subscriptions`
/// → plan id (the cap comes from `CommandCodePlanCatalog`). Auth: `Cookie:
/// <better-auth session cookie>` from browser auto-import (G1), manual paste,
/// or `COMMANDCODE_COOKIE` / `COMMANDCODE_SESSION_TOKEN`.
public struct CommandCodeCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.commandCode

    private static let envVars = ["COMMANDCODE_COOKIE", "COMMANDCODE_SESSION_TOKEN"]
    private static let cookieDomains = ["commandcode.ai", "api.commandcode.ai"]
    static let sessionCookieNames = [
        "__Host-better-auth.session_token",
        "__Secure-better-auth.session_token",
        "better-auth.session_token",
    ]
    private static let knownSessionNames = Set(sessionCookieNames)
    static let apiBase = "https://api.commandcode.ai"
    static let subscriptionGraceSeconds: Double = 5
    static let usdUnitScale = 100_000.0   // $1 = 100_000 units (OpenRouter/Perplexity)

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.knownSessionNames)
        guard let raw = resolution.headerValue,
              let cookieHeader = Self.cookieHeaderValue(from: raw) else {
            throw CollectorError.missingCredentials("Command Code: no better-auth session cookie")
        }
        // Credits required (throws); subscription best-effort grace-bounded so
        // it can never stall the shared collector TaskGroup.
        async let creditsTask = fetchCredits(cookie: cookieHeader)
        async let subTask = fetchSubscriptionWithGrace(cookie: cookieHeader)
        let credits = try await creditsTask
        let subscription = await subTask
        let plan = subscription.flatMap { Self.planForID($0.planID) }   // nil ⇒ degrade (no throw)
        return Self.buildResult(credits: credits, plan: plan, periodEnd: subscription?.currentPeriodEnd)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Cookie (ported from CommandCodeCookieHeader.override(from:))

    /// Resolves a clean `Cookie:` header value (`name=value`) for the
    /// better-auth session cookie — accepts a bare token or a full header.
    static func cookieHeaderValue(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Bare token ⇒ assume the production cookie name.
        if !trimmed.contains("="), !trimmed.contains(";") {
            return "__Secure-better-auth.session_token=\(trimmed)"
        }
        // Parse pairs; match a known session cookie (case-insensitive).
        var byLowerName: [String: (name: String, value: String)] = [:]
        for chunk in trimmed.split(separator: ";") {
            let part = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = part.firstIndex(of: "=") else { continue }
            let name = String(part[..<eq]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            byLowerName[name.lowercased()] = (name, value)
        }
        for expected in sessionCookieNames {
            if let match = byLowerName[expected.lowercased()] {
                return "\(match.name)=\(match.value)"
            }
        }
        return nil
    }

    // MARK: - Payloads

    struct Credits: Sendable, Equatable {
        var monthly: Double
        var purchased: Double
        var premium: Double
        var opensource: Double
    }

    struct Subscription: Sendable, Equatable {
        var planID: String
        var status: String
        var currentPeriodEnd: Date?
    }

    // MARK: - Networking

    private func fetchCredits(cookie: String) async throws -> Credits {
        let data = try await Self.send(path: "/internal/billing/credits", cookie: cookie)
        return try Self.parseCredits(data)
    }

    /// Best-effort subscription bounded to ~5s — races the request against a
    /// sleep; nil on timeout/failure (credits still render, see Q1 divergence).
    private func fetchSubscriptionWithGrace(cookie: String) async -> Subscription? {
        await withTaskGroup(of: Subscription?.self) { group in
            group.addTask {
                guard let data = try? await Self.send(path: "/internal/billing/subscriptions", cookie: cookie)
                else { return nil }
                return (try? Self.parseSubscription(data)) ?? nil
            }
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

    private static func send(path: String, cookie: String) async throws -> Data {
        guard let url = URL(string: apiBase + path) else {
            throw CollectorError.invalidURL("commandcode \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://commandcode.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://commandcode.ai/", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("Command Code: session expired or unauthorized")
        }
        guard (200..<300).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "Command Code")
        }
        return data
    }

    // MARK: - Parsing

    static func parseCredits(_ data: Data) throws -> Credits {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Command Code: invalid credits JSON")
        }
        guard let credits = root["credits"] as? [String: Any] else {
            throw CollectorError.parseFailed("Command Code: missing 'credits' object")
        }
        guard let monthly = double(from: credits["monthlyCredits"]) else {
            throw CollectorError.parseFailed("Command Code: missing monthlyCredits")
        }
        // Clamp every pool to >= 0 — reconciliation can briefly report negative
        // (Gemini C-11 R1 LOW: a negative TierDTO breaks UI rendering).
        return Credits(
            monthly: max(0, monthly),
            purchased: max(0, double(from: credits["purchasedCredits"]) ?? 0),
            premium: max(0, double(from: credits["premiumMonthlyCredits"]) ?? 0),
            opensource: max(0, double(from: credits["opensourceMonthlyCredits"]) ?? 0))
    }

    /// `{success, data:{planId,status,currentPeriodEnd}}`; nil on free tier
    /// (missing/false success or missing data).
    static func parseSubscription(_ data: Data) throws -> Subscription? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Command Code: invalid subscriptions JSON")
        }
        guard root["success"] as? Bool ?? false, let d = root["data"] as? [String: Any] else {
            return nil
        }
        guard let planID = (d["planId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !planID.isEmpty else {
            return nil   // active-but-no-planId ⇒ treat as free/unknown (degrade, don't throw)
        }
        return Subscription(
            planID: planID,
            status: (d["status"] as? String) ?? "unknown",
            currentPeriodEnd: date(from: d["currentPeriodEnd"]))
    }

    // MARK: - Plan catalog (ported verbatim; commandcode.ai/pricing)

    struct Plan: Sendable, Equatable {
        let id: String
        let displayName: String
        let monthlyCreditsUSD: Double
    }

    static let plans: [Plan] = [
        Plan(id: "individual-go", displayName: "Go", monthlyCreditsUSD: 10),
        Plan(id: "individual-pro", displayName: "Pro", monthlyCreditsUSD: 30),
        Plan(id: "individual-max", displayName: "Max", monthlyCreditsUSD: 150),
        Plan(id: "individual-ultra", displayName: "Ultra", monthlyCreditsUSD: 300),
    ]

    static func planForID(_ planID: String) -> Plan? {
        let normalized = planID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return plans.first { $0.id == normalized }
    }

    // MARK: - Value coercion

    static func double(from value: Any?) -> Double? {
        switch value {
        case let n as NSNumber:
            let d = n.doubleValue
            return d.isFinite ? d : nil
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    static func date(from value: Any?) -> Date? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    // MARK: - Result building (.credits, USD → units)

    static func buildResult(credits: Credits, plan: Plan?, periodEnd: Date?) -> CollectorResult {
        let resetISO = periodEnd.map { sharedISO8601Formatter.string(from: $0) }
        // Extra balance pools as uncapped TierDTOs (quota == remaining).
        var poolTiers: [TierDTO] = []
        func addPool(_ name: String, _ usd: Double) {
            guard usd > 0 else { return }
            let u = units(usd)
            poolTiers.append(TierDTO(name: name, quota: u, remaining: u, reset_time: nil))
        }

        if let plan, plan.monthlyCreditsUSD > 0 {
            let cap = plan.monthlyCreditsUSD
            let remainingUSD = min(max(0, credits.monthly), cap)
            let usedUSD = max(0, cap - remainingUSD)
            var tiers = [TierDTO(
                name: "Monthly", quota: units(cap), remaining: units(remainingUSD), reset_time: resetISO)]
            addPool("Purchased", credits.purchased)
            addPool("Premium", credits.premium)
            addPool("Open Source", credits.opensource)
            tiers.append(contentsOf: poolTiers)
            let usage = ProviderUsage(
                provider: ProviderKind.commandCode.rawValue,
                today_usage: units(usedUSD), week_usage: units(usedUSD),
                estimated_cost_today: 0, estimated_cost_week: usedUSD,
                cost_status_today: "Unavailable", cost_status_week: "Exact",
                quota: units(cap), remaining: units(remainingUSD),
                plan_type: plan.displayName, reset_time: resetISO, tiers: tiers,
                status_text: "\(plan.displayName) · \(formatUSD(usedUSD)) of \(formatUSD(cap))",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(
                    display_name: "Command Code", category: "cloud",
                    supports_exact_cost: true, supports_quota: false))
            return CollectorResult(usage: usage, dataKind: .credits)
        }

        // Free tier / unknown plan / subscription unavailable ⇒ uncapped balance.
        let totalUSD = credits.monthly + credits.purchased + credits.premium + credits.opensource
        addPool("Monthly", credits.monthly)
        addPool("Purchased", credits.purchased)
        addPool("Premium", credits.premium)
        addPool("Open Source", credits.opensource)
        let usage = ProviderUsage(
            provider: ProviderKind.commandCode.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: nil, remaining: units(totalUSD),
            plan_type: "Free", reset_time: resetISO, tiers: poolTiers,
            status_text: "\(formatUSD(totalUSD)) remaining",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Command Code", category: "cloud",
                supports_exact_cost: false, supports_quota: false))
        return CollectorResult(usage: usage, dataKind: .credits)
    }

    static func units(_ usd: Double) -> Int {
        guard usd.isFinite, usd > 0 else { return 0 }
        return Int((usd * usdUnitScale).rounded())
    }

    static func formatUSD(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        let digits = value < 100 ? 2 : 0
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}
#endif
