// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Abacus/{AbacusUsageFetcher,
// AbacusUsageSnapshot}.swift (https://github.com/steipete/CodexBar). The
// two-endpoint shape (compute-points required + billing optional), the
// `{success, result}` envelope + auth-error detection, the credit-field
// parse, and the ISO date parse are ported; the fetch is reimplemented on
// CLI Pulse's G1 `CookieResolver` seam + URLSession and mapped to `.quota`.
//
// CodexBar-parity Phase C-9 — add the (absent) Abacus AI provider. Cookie
// batch #2. Composes two proven in-repo templates: PerplexityCollector
// (cookie-HEADER passthrough — the whole resolved header is sent as
// `Cookie:`, no token extraction) + CodebuffCollector (a REQUIRED call +
// a best-effort grace-bounded SECOND call run concurrently so the optional
// one can never stall the shared collector TaskGroup — Gemini C-6 CRITICAL).
//
// Divergences from upstream:
//   * `URLSession` + `CookieResolver` instead of CodexBar's bespoke
//     SweetCookieKit importer + ProviderHTTPClient; no CodexBarLog.
//   * billing is grace-bounded (~5s) via the Codebuff race rather than
//     CodexBar's in-TaskGroup `min(timeout,5)` budget — same guarantee.
//   * auth-error keyword set tightened (drop bare "session"/"expired") to
//     avoid false-positive re-auth prompts on non-auth error strings
//     (Gemini C-9 R1 LOW).
//   * degenerate total<=0 ⇒ `.statusOnly` (Codebuff precedent) rather than
//     a degenerate 0/0 gauge.
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

/// Fetches Abacus AI organization compute-points (required) + billing
/// (best-effort) via session-cookie auth.
///
/// Compute points: `GET apps.abacus.ai/api/_getOrganizationComputePoints`
/// → totalComputePoints / computePointsLeft. Billing (best-effort, ~5s):
/// `POST .../api/_getBillingInfo` → nextBillingDate / currentTier. Auth:
/// `Cookie:` header from browser auto-import (G1), manual paste, or
/// `ABACUS_COOKIE` / `ABACUS_SESSION_TOKEN`.
public struct AbacusCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.abacus

    private static let envVars = ["ABACUS_COOKIE", "ABACUS_SESSION_TOKEN"]
    private static let cookieDomains = ["apps.abacus.ai", "abacus.ai"]
    private static let knownSessionNames: Set<String> = ["sessionid", "session_id", "session_token"]
    static let computePointsURL = "https://apps.abacus.ai/api/_getOrganizationComputePoints"
    static let billingURL = "https://apps.abacus.ai/api/_getBillingInfo"
    static let billingGraceSeconds: Double = 5

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.envVars,
            domains: Self.cookieDomains,
            knownSessionCookieNames: Self.knownSessionNames)
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("Abacus AI: no session cookie (manual or auto-import)")
        }
        // Compute points is required (throws); billing is best-effort and
        // grace-bounded so it can never stall the shared collector TaskGroup.
        async let computeTask = fetchComputePoints(cookie: cookie)
        async let billingTask = fetchBillingWithGrace(cookie: cookie)
        let compute = try await computeTask
        let billing = await billingTask
        return Self.buildResult(compute: compute, billing: billing)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Payloads

    struct ComputePoints: Sendable, Equatable {
        var total: Double
        var left: Double
    }

    struct Billing: Sendable, Equatable {
        var nextBillingDate: Date?
        var currentTier: String?
    }

    // MARK: - Networking

    private func fetchComputePoints(cookie: String) async throws -> ComputePoints {
        let result = try await Self.fetchResult(
            urlString: Self.computePointsURL, method: "GET", cookie: cookie, timeout: 15)
        return try Self.parseComputePoints(result)
    }

    /// Best-effort billing bounded to a ~5s grace — races the request
    /// against a sleep; nil on timeout/failure (credits still render).
    private func fetchBillingWithGrace(cookie: String) async -> Billing? {
        await withTaskGroup(of: Billing?.self) { group in
            group.addTask { try? await Self.fetchBilling(cookie: cookie) }
            group.addTask {
                let nanos = UInt64(max(0, Self.billingGraceSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func fetchBilling(cookie: String) async throws -> Billing {
        let result = try await fetchResult(
            urlString: billingURL, method: "POST", cookie: cookie, timeout: billingGraceSeconds)
        return parseBilling(result)
    }

    /// Performs the request, validates the `{success, result}` envelope, and
    /// returns the inner `result` dict. Throws `.missingCredentials` on an
    /// auth failure (401/403 or an auth-flavored error string) so the UI
    /// prompts re-auth, else `.httpError`/`.parseFailed`.
    private static func fetchResult(
        urlString: String, method: String, cookie: String, timeout: TimeInterval) async throws -> [String: Any]
    {
        guard let url = URL(string: urlString) else {
            throw CollectorError.invalidURL("abacus \(method)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("https://apps.abacus.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://apps.abacus.ai/", forHTTPHeaderField: "Referer")
        if method == "POST" {
            request.httpBody = Data("{}".utf8)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try unwrapResult(data: data, status: status)
    }

    /// Validates the HTTP status + `{success, result}` envelope, returning
    /// the inner `result` dict. Extracted from the request for testability.
    static func unwrapResult(data: Data, status: Int) throws -> [String: Any] {
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("Abacus AI: session expired or unauthorized")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "Abacus AI")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Abacus AI: invalid JSON")
        }
        if root["success"] as? Bool == true, let result = root["result"] as? [String: Any] {
            return result
        }
        // Failure envelope — decide re-auth vs parse error from the message.
        let message = (root["error"] as? String ?? "unknown error")
        if Self.isAuthErrorMessage(message) {
            throw CollectorError.missingCredentials("Abacus AI: \(message)")
        }
        throw CollectorError.parseFailed("Abacus AI: \(message)")
    }

    /// Auth-flavored error detection. Tightened vs upstream (no bare
    /// "session"/"expired") to avoid false-positive re-auth prompts on
    /// non-auth errors like "model prediction session failed" (Gemini R1 LOW).
    static func isAuthErrorMessage(_ message: String) -> Bool {
        let m = message.lowercased()
        let needles = [
            "unauthorized", "unauthenticated", "not authenticated", "forbidden",
            "authenticate", "log in", "login", "session expired", "expired session",
            "invalid session", "no session",
        ]
        return needles.contains { m.contains($0) }
    }

    // MARK: - Parsing

    static func parseComputePoints(_ result: [String: Any]) throws -> ComputePoints {
        guard let total = double(from: result["totalComputePoints"]),
              let left = double(from: result["computePointsLeft"]) else {
            let keys = result.keys.sorted().joined(separator: ", ")
            throw CollectorError.parseFailed("Abacus AI: missing compute-point fields. Keys: [\(keys)]")
        }
        return ComputePoints(total: total, left: left)
    }

    static func parseBilling(_ result: [String: Any]) -> Billing {
        Billing(
            nextBillingDate: parseDate(result["nextBillingDate"] as? String),
            currentTier: string(from: result["currentTier"]))
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
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// ISO8601 (fractional or plain) → Date. (Vendored from CodexBar's
    /// AbacusUsageFetcher.parseDate.)
    static func parseDate(_ isoString: String?) -> Date? {
        guard let isoString, !isoString.isEmpty else { return nil }
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: isoString) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: isoString)
    }

    // MARK: - Result building (.quota when capped; else .statusOnly)

    static func buildResult(compute: ComputePoints, billing: Billing?) -> CollectorResult {
        let planType = billing?.currentTier.map { $0.capitalized } ?? "Account"
        let resetISO = billing?.nextBillingDate.map { sharedISO8601Formatter.string(from: $0) }

        let total = max(0, compute.total)
        let leftClamped = min(max(0, compute.left), total)

        // Degenerate: no usable cap ⇒ status-only (avoid a 0/0 gauge).
        guard total > 0 else {
            let u = ProviderUsage(
                provider: ProviderKind.abacus.rawValue,
                today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: nil, remaining: nil,
                plan_type: planType, reset_time: resetISO, tiers: [],
                status_text: "\(creditCountString(max(0, compute.left))) compute points",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(
                    display_name: "Abacus AI", category: "cloud",
                    supports_exact_cost: false, supports_quota: false))
            return CollectorResult(usage: u, dataKind: .statusOnly)
        }

        let quotaInt = Int(total.rounded())
        let remainingInt = min(max(0, Int(leftClamped.rounded())), quotaInt)
        // Monthly-cycle consumption mapped onto today/week_usage so the
        // primary progress bar renders — pragmatic UI mapping, not a real
        // daily figure.
        let usedInt = max(0, quotaInt - remainingInt)
        let tiers = [
            TierDTO(name: "Compute Points", quota: quotaInt, remaining: remainingInt, reset_time: resetISO),
        ]
        let u = ProviderUsage(
            provider: ProviderKind.abacus.rawValue,
            today_usage: usedInt, week_usage: usedInt,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: quotaInt, remaining: remainingInt,
            plan_type: planType, reset_time: resetISO, tiers: tiers,
            status_text: "\(creditCountString(Double(remainingInt)))/\(creditCountString(total)) compute points",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Abacus AI", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: u, dataKind: .quota)
    }

    static func creditCountString(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "en_US_POSIX")
        let rounded = value.isFinite ? value.rounded() : 0
        return f.string(from: NSNumber(value: rounded)) ?? String(Int(rounded))
    }
}
#endif
