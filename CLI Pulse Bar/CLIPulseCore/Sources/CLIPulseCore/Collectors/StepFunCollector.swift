// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/StepFun/StepFunUsageFetcher.swift
// (https://github.com/steipete/CodexBar). The flexible number/timestamp
// decoders, the rate-limit + plan-status response models, the oasis-* headers,
// and the two-window mapping are ported; the fetch is reimplemented on CLI
// Pulse's G1 `CookieResolver` seam + URLSession.
//
// CodexBar-parity Phase C-16 — add the (absent) StepFun (阶跃星辰) provider.
//
// CRITICAL divergence — NO password login. Upstream performs a username/
// PASSWORD sign-in (RegisterDevice → SignInByPassword). CLI Pulse never stores
// user passwords (autonomy/security contract). We use the `Oasis-Token` COOKIE
// directly (auto-import / manual paste) and call the usage RPCs — CodexBar's
// own `fetchUsage(token:)` path proves a standalone token works without login.
//
// Other divergences:
//   * `URLSession`; no CodexBarLog. plan-status is best-effort grace-bounded
//     (~5s self-cancelling race) so it can't stall the shared TaskGroup.
//   * leftRate clamped to 0...1 before the percent (API-glitch guard).
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

/// Reports StepFun 5-hour + weekly usage windows via the `Oasis-Token` cookie.
///
/// `POST platform.stepfun.com/api/…Dashboard/QueryStepPlanRateLimit` (+ best-
/// effort GetStepPlanStatus). Auth: `Oasis-Token` cookie from auto-import /
/// manual paste / env `STEPFUN_COOKIE` / `STEPFUN_OASIS_TOKEN`.
public struct StepFunCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.stepfun

    private static let envVars = ["STEPFUN_COOKIE", "STEPFUN_OASIS_TOKEN"]
    private static let cookieDomains = ["platform.stepfun.com", "stepfun.com"]
    private static let knownSessionNames: Set<String> = ["Oasis-Token"]
    static let rateLimitURL =
        "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/QueryStepPlanRateLimit"
    static let planStatusURL =
        "https://platform.stepfun.com/api/step.openapi.devcenter.Dashboard/GetStepPlanStatus"
    // Vendored device/app constants (CodexBar). webid falls back to this when
    // the user's cookie doesn't carry an Oasis-Webid.
    static let fallbackWebID = "c8a1002d2c457e758785a9979832217c7c0b884c"
    static let appID = "10300"
    static let planGraceSeconds: Double = 5

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.knownSessionNames)
        guard let header = resolution.headerValue else {
            throw CollectorError.missingCredentials("StepFun: no session cookie (manual or auto-import)")
        }
        let (token, webidFromCookie) = Self.cookieTokens(fromHeader: header)
        guard let token else {
            throw CollectorError.missingCredentials("StepFun: cookie has no Oasis-Token")
        }
        let webid = webidFromCookie ?? Self.fallbackWebID

        async let rateTask = fetchRateLimit(token: token, webid: webid)
        async let planTask = fetchPlanWithGrace(token: token, webid: webid)
        let rate = try await rateTask
        let plan = await planTask
        return Self.buildResult(rate: rate, planName: plan)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Cookie extraction

    /// Extracts `Oasis-Token` + `Oasis-Webid` from a Cookie header (or accepts
    /// a bare token).
    static func cookieTokens(fromHeader raw: String) -> (token: String?, webid: String?) {
        var token: String?
        var webid: String?
        for part in raw.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if name.caseInsensitiveCompare("Oasis-Token") == .orderedSame, !value.isEmpty { token = value }
            if name.caseInsensitiveCompare("Oasis-Webid") == .orderedSame, !value.isEmpty { webid = value }
        }
        if token == nil {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty, !t.contains("="), !t.contains(";") { token = t }   // bare token env
        }
        return (token, webid)
    }

    // MARK: - Networking

    private func fetchRateLimit(token: String, webid: String) async throws -> Rate {
        let data = try await Self.postRPC(urlString: Self.rateLimitURL, token: token, webid: webid)
        return try Self.parseRateLimit(data)
    }

    /// Best-effort plan-status bounded to a ~5s self-cancelling grace (Gemini
    /// C-16 R1 LOW) — nil on timeout/failure (rate-limit data still renders).
    private func fetchPlanWithGrace(token: String, webid: String) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                guard let data = try? await Self.postRPC(
                    urlString: Self.planStatusURL, token: token, webid: webid) else { return nil }
                return try? Self.parsePlanStatus(data)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, Self.planGraceSeconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func postRPC(urlString: String, token: String, webid: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw CollectorError.invalidURL("stepfun rpc") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(appID, forHTTPHeaderField: "oasis-appid")
        request.setValue("web", forHTTPHeaderField: "oasis-platform")
        request.setValue(webid, forHTTPHeaderField: "oasis-webid")
        request.setValue("Oasis-Token=\(token); Oasis-Webid=\(webid)", forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/147.0.0.0 Safari/537.36",
            forHTTPHeaderField: "user-agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("StepFun: session expired or unauthorized")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "StepFun")
        }
        return data
    }

    // MARK: - Parse

    struct Rate: Sendable, Equatable {
        var fiveHourLeftRate: Double
        var weeklyLeftRate: Double
        var fiveHourReset: Date
        var weeklyReset: Date
    }

    static func parseRateLimit(_ data: Data) throws -> Rate {
        let resp: RateLimitResponse
        do {
            resp = try JSONDecoder().decode(RateLimitResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("StepFun: \(error.localizedDescription)")
        }
        guard resp.status == 1 else {
            throw CollectorError.parseFailed("StepFun: \(resp.message ?? resp.code.map(String.init) ?? "not ok")")
        }
        guard let fh = resp.fiveHourUsageLeftRate, let wk = resp.weeklyUsageLeftRate,
              let fhr = resp.fiveHourUsageResetTime, let wkr = resp.weeklyUsageResetTime else {
            throw CollectorError.parseFailed("StepFun: missing usage/reset fields")
        }
        return Rate(
            fiveHourLeftRate: fh.value, weeklyLeftRate: wk.value,
            fiveHourReset: Date(timeIntervalSince1970: TimeInterval(fhr.value)),
            weeklyReset: Date(timeIntervalSince1970: TimeInterval(wkr.value)))
    }

    static func parsePlanStatus(_ data: Data) throws -> String? {
        let resp = try JSONDecoder().decode(PlanStatusResponse.self, from: data)
        let name = resp.subscription?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty ?? true) ? nil : name
    }

    // MARK: - Result building (.quota — 5h + weekly percent windows)

    static func buildResult(rate: Rate, planName: String?) -> CollectorResult {
        func remainingPercent(_ leftRate: Double) -> Int {
            Int((max(0, min(1, leftRate)) * 100).rounded())   // clamp 0...1 (Gemini C-16 R1 LOW)
        }
        let fhRemaining = remainingPercent(rate.fiveHourLeftRate)
        let wkRemaining = remainingPercent(rate.weeklyLeftRate)
        let fhResetISO = sharedISO8601Formatter.string(from: rate.fiveHourReset)
        let wkResetISO = sharedISO8601Formatter.string(from: rate.weeklyReset)

        let tiers = [
            TierDTO(name: "5-hour", quota: 100, remaining: fhRemaining, reset_time: fhResetISO,
                    windowMinutes: 300, role: nil),
            TierDTO(name: "Weekly", quota: 100, remaining: wkRemaining, reset_time: wkResetISO,
                    windowMinutes: 10080, role: nil),
        ]
        let usage = ProviderUsage(
            provider: ProviderKind.stepfun.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: fhRemaining,        // headline = the 5-hour window
            plan_type: planName ?? "StepFun", reset_time: fhResetISO, tiers: tiers,
            status_text: "5h \(fhRemaining)% left · Weekly \(wkRemaining)% left",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "StepFun", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    // MARK: - Vendored response model + flexible decoders (fileprivate)

    private struct RateLimitResponse: Decodable {
        let status: Int?
        let code: Int?
        let message: String?
        let fiveHourUsageLeftRate: FlexibleNumber?
        let weeklyUsageLeftRate: FlexibleNumber?
        let fiveHourUsageResetTime: FlexibleTimestamp?
        let weeklyUsageResetTime: FlexibleTimestamp?
        enum CodingKeys: String, CodingKey {
            case status, code, message
            case fiveHourUsageLeftRate = "five_hour_usage_left_rate"
            case weeklyUsageLeftRate = "weekly_usage_left_rate"
            case fiveHourUsageResetTime = "five_hour_usage_reset_time"
            case weeklyUsageResetTime = "weekly_usage_reset_time"
        }
    }

    private struct PlanStatusResponse: Decodable {
        let subscription: Subscription?
        struct Subscription: Decodable { let name: String? }
    }

    /// Decodes from a JSON int OR float (StepFun returns either for rates).
    struct FlexibleNumber: Decodable, Sendable {
        let value: Double
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let i = try? c.decode(Int.self) { value = Double(i) }
            else if let d = try? c.decode(Double.self) { value = d }
            else { value = 0 }
        }
    }

    /// Decodes from a JSON string OR int (StepFun returns epoch as either).
    struct FlexibleTimestamp: Decodable, Sendable {
        let value: Int64
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self), let parsed = Int64(s) { value = parsed }
            else if let i = try? c.decode(Int64.self) { value = i }
            else { value = 0 }
        }
    }
}
#endif
