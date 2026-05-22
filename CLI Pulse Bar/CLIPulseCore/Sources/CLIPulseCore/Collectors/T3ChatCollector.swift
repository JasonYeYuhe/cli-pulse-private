// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/T3Chat/{T3ChatUsageFetcher,
// T3ChatUsageSnapshot}.swift (https://github.com/steipete/CodexBar). The
// getCustomerData tRPC request shape, the JSONL parser (recursive customerData
// finder), the Codable customer/subscription models, and the ms-epoch date
// handling are ported; the fetch is reimplemented on CLI Pulse's G1
// `CookieResolver` seam + URLSession and mapped to `.quota`.
//
// CodexBar-parity Phase C-17 — add the (absent) T3 Chat provider (t3.chat).
// Clean tRPC GET → JSONL API (NOT HTML scraping). Two usage windows (4-hour +
// month) ⇒ `.quota` percent gauges like Claude/Codex.
//
// Divergences from upstream:
//   * `URLSession`; no CodexBarLog. cURL-capture header-forwarding NOT ported
//     (power-user path) — cookie auto-import also grabs Vercel clearance
//     cookies, so an authenticated request + browser-like headers passes; a
//     429 bot-challenge is surfaced as an actionable error (Gemini C-17 R1).
//   * single bounded GET ⇒ no shared-TaskGroup hazard.
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

/// Reports T3 Chat 4-hour + month usage windows via session-cookie auth.
///
/// `GET t3.chat/api/trpc/getCustomerData?batch=1&input=…` (tRPC → JSONL). Auth:
/// `Cookie:` header (all t3.chat cookies — incl. Vercel clearance) from
/// auto-import / manual paste / env `T3CHAT_COOKIE`.
public struct T3ChatCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.t3chat

    private static let envVars = ["T3CHAT_COOKIE"]
    private static let cookieDomains = ["t3.chat", "www.t3.chat"]
    private static let knownSessionNames: Set<String> = []   // grab all (need clearance cookies too)
    // Captured getCustomerData tRPC input shape (CodexBar, May 2026).
    static let inputParam = #"{"0":{"json":{"sessionId":null},"meta":{"values":{"sessionId":["undefined"]}}}}"#

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
            throw CollectorError.missingCredentials("T3 Chat: no session cookie (manual or auto-import)")
        }
        let data = try await fetch(cookie: cookie)
        let customer = try Self.parseJSONLines(data)
        return Self.buildResult(customer)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Networking

    private func fetch(cookie: String) async throws -> Data {
        guard var components = URLComponents(string: "https://t3.chat/api/trpc/getCustomerData") else {
            throw CollectorError.invalidURL("t3chat")
        }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: Self.inputParam),
        ]
        guard let url = components.url else { throw CollectorError.invalidURL("t3chat query") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/jsonl", forHTTPHeaderField: "trpc-accept")
        request.setValue("web-client", forHTTPHeaderField: "x-trpc-source")
        request.setValue("true", forHTTPHeaderField: "x-trpc-batch")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue("https://t3.chat/settings/customization", forHTTPHeaderField: "Referer")
        request.setValue("https://t3.chat", forHTTPHeaderField: "Origin")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
            + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.missingCredentials("T3 Chat: session expired or unauthorized")
        }
        if status == 429, http?.value(forHTTPHeaderField: "x-vercel-mitigated") == "challenge" {
            throw CollectorError.missingCredentials(
                "T3 Chat: access blocked by Vercel bot protection. Open t3.chat in your browser, "
                + "ensure you are logged in, then refresh your session cookies.")
        }
        guard status == 200 else {
            throw CollectorError.httpError(status: status, provider: "T3 Chat")
        }
        return data
    }

    // MARK: - Parse (JSONL → recursive customerData finder; vendored)

    static func parseJSONLines(_ data: Data) throws -> CustomerData {
        guard let text = String(data: data, encoding: .utf8) else {
            throw CollectorError.parseFailed("T3 Chat: response is not UTF-8")
        }
        return try parseJSONLines(text: text)
    }

    static func parseJSONLines(text: String) throws -> CustomerData {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let customerObject = findCustomerData(in: object) else { continue }
            do {
                let raw = try JSONSerialization.data(withJSONObject: customerObject)
                return try JSONDecoder().decode(CustomerData.self, from: raw)
            } catch {
                throw CollectorError.parseFailed("T3 Chat: \(error.localizedDescription)")
            }
        }
        throw CollectorError.parseFailed("T3 Chat: missing customer data object")
    }

    private static func findCustomerData(in object: Any) -> [String: Any]? {
        if let dict = object as? [String: Any] {
            if dict["usageFourHourPercentage"] != nil || dict["usageMonthPercentage"] != nil
                || (dict["subscription"] != nil && dict["usageBand"] != nil) {
                return dict
            }
            for value in dict.values {
                if let found = findCustomerData(in: value) { return found }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let found = findCustomerData(in: value) { return found }
            }
        }
        return nil
    }

    // MARK: - Vendored Codable models

    public struct Subscription: Decodable, Sendable {
        public let productName: String?
        public let currentPeriodEnd: TimeInterval?
    }

    public struct CustomerData: Decodable, Sendable {
        public let subTier: String?
        public let subscription: Subscription?
        public let usageBand: String?
        public let usageFourHourPercentage: Double?
        public let usageMonthPercentage: Double?
        public let usagePeriodPercentage: Double?
        public let usageFourHourNextResetAt: TimeInterval?
        public let usageWindowNextResetAt: TimeInterval?

        public var planName: String? {
            let raw = subscription?.productName ?? subTier
            guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw.split(separator: "-")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")
        }
    }

    // MARK: - Result building (.quota — 4-hour + month percent windows)

    static func buildResult(_ c: CustomerData) -> CollectorResult {
        func remaining(_ usedPct: Double?) -> Int {
            Int((100 - min(100, max(0, usedPct ?? 0))).rounded())   // usage% is USED ⇒ remaining = 100 − used
        }
        let r4h = remaining(c.usageFourHourPercentage)
        let rMonth = remaining(c.usageMonthPercentage ?? c.usagePeriodPercentage)
        let reset4h = date(fromMilliseconds: c.usageFourHourNextResetAt ?? c.usageWindowNextResetAt)
        let resetMonth = date(fromMilliseconds: c.subscription?.currentPeriodEnd)
        let reset4hISO = reset4h.map { sharedISO8601Formatter.string(from: $0) }
        let resetMonthISO = resetMonth.map { sharedISO8601Formatter.string(from: $0) }

        let tiers = [
            TierDTO(name: "4-hour", quota: 100, remaining: r4h, reset_time: reset4hISO,
                    windowMinutes: 240, role: nil),
            TierDTO(name: "Monthly", quota: 100, remaining: rMonth, reset_time: resetMonthISO,
                    windowMinutes: nil, role: nil),
        ]
        var status = "4h \(r4h)% left · Month \(rMonth)% left"
        if let band = c.usageBand?.trimmingCharacters(in: .whitespacesAndNewlines), !band.isEmpty {
            status += " · \(band)"
        }
        let usage = ProviderUsage(
            provider: ProviderKind.t3chat.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: r4h,          // headline = 4-hour window
            plan_type: c.planName ?? "T3 Chat", reset_time: reset4hISO, tiers: tiers,
            status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "T3 Chat", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    /// JS epoch milliseconds (>1e10) → seconds → Date.
    static func date(fromMilliseconds raw: TimeInterval?) -> Date? {
        guard let raw, raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1000 : raw)
    }
}
#endif
