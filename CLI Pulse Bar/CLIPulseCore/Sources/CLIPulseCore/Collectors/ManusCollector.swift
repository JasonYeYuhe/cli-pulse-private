// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Manus/{ManusUsageFetcher,
// ManusCookieHeader}.swift (https://github.com/steipete/CodexBar).
// The Codable `ManusCreditsResponse` (lossy-double + flexible-date
// decode), the envelope-tolerant parse, the "require ≥1 known credits
// key" guard, and the `session_id`-from-cookie token extraction are
// ported; the fetch is reimplemented on CLI Pulse's G1 `CookieResolver`
// seam + URLSession, and the result is mapped to CLI Pulse's `.quota`
// model (CodexBar's `UsageSnapshot`/`RateWindow` types are NOT vendored).
//
// CodexBar-parity Phase C-8 — add the (absent) Manus provider. First of
// the cookie batch. Auth novelty: the `session_id` cookie VALUE is sent
// as `Authorization: Bearer <value>` (not a `Cookie:` header). Manus
// returns two capped credit pools (monthly pro + periodic refresh) ⇒
// maps to `.quota` (Codebuff/ElevenLabs precedent), not `.credits`.
//
// Divergences from upstream:
//   * fetch uses `CookieResolver` (manual / env / macOS auto-import) +
//     URLSession instead of CodexBar's bespoke importer + ProviderHTTPClient.
//   * token extractor adds a tightened bare-token fallback (recovers a
//     base64-padded bare token from the `MANUS_SESSION_TOKEN` env var);
//     upstream returns nil there. Restricted to trailing `=` padding so a
//     stray non-session cookie pair is NOT mis-read as a token (Gemini
//     C-8 R1 MEDIUM).
//   * single endpoint, single bounded request ⇒ no shared-TaskGroup
//     concurrency hazard (unlike C-6/C-7's fan-out).
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

/// Fetches Manus credit pools via session-cookie auth, sending the
/// `session_id` cookie value as a Bearer token.
///
/// Endpoint: `POST https://api.manus.im/user.v1.UserService/GetAvailableCredits`
/// (Connect-RPC, body `{}`). Auth: `Authorization: Bearer <session_id>` —
/// the token comes from browser auto-import (G1), a manual Cookie header /
/// `session_id` value, or `MANUS_SESSION_TOKEN` / `MANUS_SESSION_ID` /
/// `MANUS_COOKIE`.
public struct ManusCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.manus

    private static let envVars = ["MANUS_SESSION_TOKEN", "MANUS_SESSION_ID", "MANUS_COOKIE"]
    private static let cookieDomains = ["manus.im", "api.manus.im"]
    private static let knownSessionNames: Set<String> = ["session_id"]
    private static let creditsURLString =
        "https://api.manus.im/user.v1.UserService/GetAvailableCredits"

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
            throw CollectorError.missingCredentials("Manus: no session cookie (manual or auto-import)")
        }
        guard let token = Self.sessionToken(fromCookieHeader: header) else {
            throw CollectorError.missingCredentials("Manus: cookie has no session_id value")
        }
        let data = try await fetchCredits(token: token)
        let parsed = try Self.parseResponse(data)
        return Self.buildResult(parsed)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Token extraction (ported from ManusCookieHeader.token(from:))

    /// Extracts the `session_id` value to use as the Bearer token from a
    /// resolved Cookie header — or accepts a bare token directly.
    static func sessionToken(fromCookieHeader raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Clearly a bare token: no cookie syntax at all.
        if !trimmed.contains("="), !trimmed.contains(";") { return trimmed }

        // Parse "name=value; name2=value2" pairs; split each on the FIRST
        // '=' so a base64 value containing '=' survives intact.
        for part in trimmed.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.caseInsensitiveCompare(Self.knownSessionNames.first ?? "session_id") == .orderedSame
            else { continue }
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        // Fallback: a single value (no ';') whose only '=' are trailing
        // base64 padding ⇒ treat the whole thing as a bare token. A stray
        // non-session pair like `analytics_id=123` keeps an interior '='
        // after stripping padding ⇒ rejected (Gemini C-8 R1 MEDIUM).
        if !trimmed.contains(";") {
            let stripped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "="))
            if !stripped.contains("=") { return trimmed }
        }
        return nil
    }

    // MARK: - Networking (single bounded request)

    private func fetchCredits(token: String) async throws -> Data {
        guard let url = URL(string: Self.creditsURLString) else {
            throw CollectorError.invalidURL("manus credits")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.httpBody = Data("{}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("https://manus.im", forHTTPHeaderField: "Origin")
        request.setValue("https://manus.im/", forHTTPHeaderField: "Referer")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(
                status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Manus")
        }
        return data
    }

    // MARK: - Response model (vendored verbatim, Codable)

    struct ManusCreditsResponse: Decodable, Sendable {
        let totalCredits: Double
        let freeCredits: Double
        let periodicCredits: Double
        let addonCredits: Double
        let refreshCredits: Double
        let maxRefreshCredits: Double
        let proMonthlyCredits: Double
        let eventCredits: Double
        let nextRefreshTime: Date?
        let refreshInterval: String?

        private enum CodingKeys: String, CodingKey {
            case totalCredits, freeCredits, periodicCredits, addonCredits
            case refreshCredits, maxRefreshCredits, proMonthlyCredits, eventCredits
            case nextRefreshTime, refreshInterval
        }

        init(
            totalCredits: Double = 0, freeCredits: Double = 0, periodicCredits: Double = 0,
            addonCredits: Double = 0, refreshCredits: Double = 0, maxRefreshCredits: Double = 0,
            proMonthlyCredits: Double = 0, eventCredits: Double = 0,
            nextRefreshTime: Date? = nil, refreshInterval: String? = nil)
        {
            self.totalCredits = totalCredits
            self.freeCredits = freeCredits
            self.periodicCredits = periodicCredits
            self.addonCredits = addonCredits
            self.refreshCredits = refreshCredits
            self.maxRefreshCredits = maxRefreshCredits
            self.proMonthlyCredits = proMonthlyCredits
            self.eventCredits = eventCredits
            self.nextRefreshTime = nextRefreshTime
            self.refreshInterval = refreshInterval
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.totalCredits = c.manusLossyDouble(.totalCredits) ?? 0
            self.freeCredits = c.manusLossyDouble(.freeCredits) ?? 0
            self.periodicCredits = c.manusLossyDouble(.periodicCredits) ?? 0
            self.addonCredits = c.manusLossyDouble(.addonCredits) ?? 0
            self.refreshCredits = c.manusLossyDouble(.refreshCredits) ?? 0
            self.maxRefreshCredits = c.manusLossyDouble(.maxRefreshCredits) ?? 0
            self.proMonthlyCredits = c.manusLossyDouble(.proMonthlyCredits) ?? 0
            self.eventCredits = c.manusLossyDouble(.eventCredits) ?? 0
            self.nextRefreshTime = c.manusFlexibleDate(.nextRefreshTime)
            self.refreshInterval = try? c.decodeIfPresent(String.self, forKey: .refreshInterval)
        }
    }

    private struct ManusCreditsEnvelope: Decodable {
        let data: ManusCreditsResponse?
        let result: ManusCreditsResponse?
        let response: ManusCreditsResponse?
        let availableCredits: ManusCreditsResponse?
    }

    private static let expectedCreditsKeys: Set<String> = [
        "totalCredits", "freeCredits", "periodicCredits", "addonCredits",
        "refreshCredits", "maxRefreshCredits", "proMonthlyCredits", "eventCredits",
    ]

    static func parseResponse(_ data: Data) throws -> ManusCreditsResponse {
        let decoder = JSONDecoder()
        // Envelope first — the lossy decoder defaults missing fields to 0,
        // so a wrapped payload would otherwise "succeed" as all-zero.
        if let envelope = try? decoder.decode(ManusCreditsEnvelope.self, from: data),
           let response = envelope.data ?? envelope.result ?? envelope.response ?? envelope.availableCredits {
            return response
        }
        let response: ManusCreditsResponse
        do {
            response = try decoder.decode(ManusCreditsResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Manus: \(error.localizedDescription)")
        }
        // Reject an unrelated/error payload that decoded to a bogus
        // zero-credit snapshot: require ≥1 known credits key in the raw JSON.
        guard Self.payloadContainsCreditsField(data: data) else {
            throw CollectorError.parseFailed("Manus: response missing expected credits fields")
        }
        return response
    }

    private static func payloadContainsCreditsField(data: Data) -> Bool {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return !Self.expectedCreditsKeys.isDisjoint(with: object.keys)
    }

    // MARK: - Result building (.quota when a pool is capped; else .statusOnly)

    static func buildResult(_ r: ManusCreditsResponse) -> CollectorResult {
        let balanceText = "Balance: \(creditCountString(r.totalCredits)) credits"
        // plan_type inferred from the subscription pool (no plan name in the
        // payload) — mirrors the Perplexity precedent (Gemini C-8 R1 Q1).
        let planType = r.proMonthlyCredits > 0 ? "Pro" : "Free"

        // The refresh pool, if present, surfaces as a secondary tier.
        let refreshTier: TierDTO? = r.maxRefreshCredits > 0 ? {
            let quota = clampedInt(r.maxRefreshCredits)
            let remaining = clampedInt(r.refreshCredits, max: quota)
            let resetISO = r.nextRefreshTime.map { sharedISO8601Formatter.string(from: $0) }
            return TierDTO(name: "Refresh", quota: quota, remaining: remaining, reset_time: resetISO)
        }() : nil

        let refreshDetail: String? = r.maxRefreshCredits > 0 ? {
            let label = (r.refreshInterval?.isEmpty == false) ? r.refreshInterval!.capitalized : "Refresh"
            return "\(label): \(creditCountString(r.refreshCredits))/\(creditCountString(r.maxRefreshCredits))"
        }() : nil

        func statusText(_ extra: String?) -> String {
            [balanceText, extra].compactMap { $0 }.joined(separator: " · ")
        }

        // 1) Monthly pro pool is the primary gauge.
        if r.proMonthlyCredits > 0 {
            let quota = clampedInt(r.proMonthlyCredits)
            let remaining = clampedInt(r.periodicCredits, max: quota)
            // NOTE: monthly-pool consumption mapped onto today/week_usage so
            // the primary progress bar renders — this is a pragmatic UI
            // mapping, NOT a real daily/weekly figure (Gemini C-8 R1 LOW).
            let used = max(0, quota - remaining)
            var tiers: [TierDTO] = [
                // Monthly pool has no reset in this payload (subscription
                // renewal isn't returned) ⇒ reset_time nil (Gemini C-8 R1 Q2).
                TierDTO(name: "Monthly", quota: quota, remaining: remaining, reset_time: nil),
            ]
            if let refreshTier { tiers.append(refreshTier) }
            return CollectorResult(
                usage: usage(
                    today: used, week: used, quota: quota, remaining: remaining,
                    planType: planType, resetISO: nil, tiers: tiers,
                    statusText: statusText(refreshDetail), supportsQuota: true),
                dataKind: .quota)
        }

        // 2) No monthly pool, but a refresh pool ⇒ refresh-only quota.
        if r.maxRefreshCredits > 0 {
            let quota = clampedInt(r.maxRefreshCredits)
            let remaining = clampedInt(r.refreshCredits, max: quota)
            let used = max(0, quota - remaining)
            let resetISO = r.nextRefreshTime.map { sharedISO8601Formatter.string(from: $0) }
            return CollectorResult(
                usage: usage(
                    today: used, week: used, quota: quota, remaining: remaining,
                    planType: planType, resetISO: resetISO,
                    tiers: refreshTier.map { [$0] } ?? [],
                    statusText: statusText(refreshDetail), supportsQuota: true),
                dataKind: .quota)
        }

        // 3) Neither pool capped ⇒ status-only balance.
        return CollectorResult(
            usage: usage(
                today: 0, week: 0, quota: nil, remaining: nil,
                planType: planType, resetISO: nil, tiers: [],
                statusText: balanceText, supportsQuota: false),
            dataKind: .statusOnly)
    }

    // MARK: - Helpers

    private static func usage(
        today: Int, week: Int, quota: Int?, remaining: Int?,
        planType: String, resetISO: String?, tiers: [TierDTO],
        statusText: String, supportsQuota: Bool) -> ProviderUsage
    {
        ProviderUsage(
            provider: ProviderKind.manus.rawValue,
            today_usage: today, week_usage: week,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: quota, remaining: remaining,
            plan_type: planType, reset_time: resetISO, tiers: tiers,
            status_text: statusText,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "Manus", category: "cloud",
                supports_exact_cost: false, supports_quota: supportsQuota))
    }

    /// Rounds and clamps a credit count to a non-negative Int, optionally
    /// capping at `max` (so remaining can never exceed its quota).
    private static func clampedInt(_ value: Double, max cap: Int = Int.max) -> Int {
        let rounded = value.isFinite ? Int(value.rounded()) : 0
        return Swift.max(0, Swift.min(rounded, cap))
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

// MARK: - Lossy decode helpers (vendored verbatim, fileprivate)

extension KeyedDecodingContainer {
    fileprivate func manusLossyDouble(_ key: K) -> Double? {
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return value }
        if let intValue = try? decodeIfPresent(Int.self, forKey: key) { return Double(intValue) }
        if let stringValue = try? decodeIfPresent(String.self, forKey: key) {
            return Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    fileprivate func manusFlexibleDate(_ key: K) -> Date? {
        if let value = try? decodeIfPresent(Date.self, forKey: key) { return value }
        guard let stringValue = try? decodeIfPresent(String.self, forKey: key),
              !stringValue.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: stringValue)
    }
}
#endif
