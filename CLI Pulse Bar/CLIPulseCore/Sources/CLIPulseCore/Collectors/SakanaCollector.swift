// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Sakana/{SakanaUsageFetcher,
// SakanaSettingsReader}.swift (https://github.com/steipete/CodexBar). The
// billing-page HTML scrape (5-hour + weekly window regexes, `% used` / `Resets
// on`), the UTC reset-date parse (upstream #1826), the Pay-as-you-go credit
// scrape, and the React `<!-- -->` hydration-comment stripping are ported
// VERBATIM; the fetch is reimplemented on CLI Pulse's CookieResolver seam +
// URLSession and mapped to `.quota`.
//
// v1.40.0 — add the (absent) Sakana AI provider: manual-cookie console billing.
// Manual paste / SAKANA_COOKIE env only. Everything soft-fails.
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

/// Reports Sakana AI 5-hour + weekly usage windows (+ PAYG credit) via cookie.
public struct SakanaCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.sakana

    private static let envVars = ["SAKANA_COOKIE"]
    private static let cookieDomains = ["console.sakana.ai"]
    private static let billingURL = "https://console.sakana.ai/billing"
    private static let payAsYouGoURL = "https://console.sakana.ai/billing?tab=payAsYouGo"
    private static let host = "console.sakana.ai"

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config, envVarNames: Self.envVars, domains: Self.cookieDomains,
            knownSessionCookieNames: [])
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("Sakana AI: no session cookie")
        }
        let html = try await Self.fetchHTML(url: Self.billingURL, cookie: cookie)
        var snapshot = try Self.parseBillingHTML(html)
        // Best-effort PAYG credit — never fails the primary window fetch.
        if let payHTML = try? await Self.fetchHTML(url: Self.payAsYouGoURL, cookie: cookie) {
            snapshot.payAsYouGoCreditUSD = Self.parsePayAsYouGoCredit(payHTML)
        }
        return Self.buildResult(snapshot)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty { return true }
        return false
    }

    // MARK: - Networking

    static func fetchHTML(url urlString: String, cookie: String) async throws -> String {
        guard let url = URL(string: urlString) else { throw CollectorError.invalidURL("sakana billing") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status == 401 || status == 403 || (300..<400).contains(status) {
            throw CollectorError.notSignedIn("Sakana AI: login required")
        }
        // Reject a redirect to a different origin (auth wall on another host).
        guard http?.url?.scheme?.lowercased() == "https",
              http?.url?.host?.lowercased() == Self.host else {
            throw CollectorError.notSignedIn("Sakana AI: login required")
        }
        guard status == 200 else { throw CollectorError.httpError(status: status, provider: "Sakana AI") }
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw CollectorError.parseFailed("Sakana AI: empty billing page")
        }
        return html
    }

    // MARK: - Parse (pure)

    struct Window: Sendable, Equatable {
        var usedPercent: Double
        var resetsAt: Date?
    }

    struct Snapshot: Sendable, Equatable {
        var planName: String?
        var priceLabel: String?
        var fiveHour: Window?
        var weekly: Window?
        var payAsYouGoCreditUSD: Double?
    }

    static func parseBillingHTML(_ html: String) throws -> Snapshot {
        let fiveHour = try parseWindow(label: "5-hour", html: html)
        let weekly = try parseWindow(label: "Weekly", html: html)
        guard fiveHour != nil || weekly != nil else {
            throw CollectorError.parseFailed("Sakana AI: usage limit windows not found")
        }
        return Snapshot(
            planName: capture(#"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>\s*([^<]+?)\s*</span>"#, html),
            priceLabel: capture(
                #"<div[^>]*data-slot="card-title"[^>]*>[\s\S]*?<span>[^<]+</span>\s*<span[^>]*>\s*([^<]+?)\s*</span>"#,
                html),
            fiveHour: fiveHour, weekly: weekly)
    }

    private static func parseWindow(label: String, html: String) throws -> Window? {
        guard let body = windowBody(label: label, html: html) else { return nil }
        guard let pctText = capture(#"<p[^>]*>\s*([0-9]+(?:\.[0-9]+)?)% used\s*</p>"#, body),
              let pct = Double(pctText), pct.isFinite, (0...100).contains(pct) else {
            throw CollectorError.parseFailed("Sakana AI: invalid \(label) usage percentage")
        }
        let resetText = capture(#"<p[^>]*>\s*Resets on ([^<]+?)\s*</p>"#, body)
        return Window(usedPercent: pct, resetsAt: resetText.flatMap(parseResetDate))
    }

    /// The body between a window's `<p>LABEL</p>` and the next window / card start.
    private static func windowBody(label: String, html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: label)
        guard let labelMatch = firstMatch("<p[^>]*>\\s*\(escaped)\\s*</p>", html),
              let bodyStart = Range(labelMatch.range, in: html)?.upperBound else { return nil }
        let boundary = #"<p[^>]*>\s*(?:5-hour|Weekly)\s*</p>|<div[^>]*data-slot=(?:"card"|'card'|"card-title"|'card-title')[^>]*>"#
        let ns = html as NSString
        let searchRange = NSRange(location: NSMaxRange(labelMatch.range),
                                  length: max(0, ns.length - NSMaxRange(labelMatch.range)))
        let bodyEnd: String.Index
        if let regex = try? NSRegularExpression(pattern: boundary, options: [.caseInsensitive]),
           let m = regex.firstMatch(in: html, options: [], range: searchRange),
           let end = Range(m.range, in: html)?.lowerBound {
            bodyEnd = end
        } else {
            bodyEnd = html.endIndex
        }
        let body = html[bodyStart..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : String(body)
    }

    /// PAYG prepaid credit balance ($). Strips React hydration comments.
    static func parsePayAsYouGoCredit(_ html: String) -> Double? {
        let pattern = #"<h2[^>]*>\s*Credit balance\s*</h2>[\s\S]{0,900}?<p[^>]*tabular-nums[^"]*"[^>]*>"#
            + #"\$?([0-9][0-9,]*(?:\.[0-9]+)?)</p>"#
        guard let text = capture(pattern, html) else { return nil }
        return Double(text.replacingOccurrences(of: ",", with: ""))
    }

    /// The billing page server-renders "Resets on <date>" in UTC; the client only
    /// re-localizes after JS hydration, which this scraper never runs. Parsing in
    /// any other TZ shifts every reset by the device offset (steipete/CodexBar#1826).
    static func parseResetDate(_ value: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return f.date(from: value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Result building (.quota windows; PAYG credit in status)

    static func buildResult(_ s: Snapshot) -> CollectorResult {
        func tier(_ name: String, _ w: Window, windowMinutes: Int) -> TierDTO {
            let remaining = Int((100 - max(0, min(100, w.usedPercent))).rounded())
            let reset = w.resetsAt.map { sharedISO8601Formatter.string(from: $0) }
            return TierDTO(name: name, quota: 100, remaining: remaining, reset_time: reset, windowMinutes: windowMinutes)
        }
        var tiers: [TierDTO] = []
        if let f = s.fiveHour { tiers.append(tier("5-hour", f, windowMinutes: 300)) }
        if let w = s.weekly { tiers.append(tier("Weekly", w, windowMinutes: 7 * 24 * 60)) }

        let primary = s.fiveHour ?? s.weekly
        let primaryRemaining = Int((100 - max(0, min(100, primary?.usedPercent ?? 0))).rounded())
        var status = "\(s.fiveHour != nil ? "5h" : "Weekly") \(primaryRemaining)% left"
        if s.fiveHour != nil, let w = s.weekly {
            status += " · Weekly \(Int((100 - max(0, min(100, w.usedPercent))).rounded()))% left"
        }
        if let credit = s.payAsYouGoCreditUSD, credit > 0 {
            status += String(format: " · $%.2f credit", credit)
        }
        let planType = [s.planName, s.priceLabel]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let usage = ProviderUsage(
            provider: ProviderKind.sakana.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: primaryRemaining, plan_type: planType.isEmpty ? "Sakana AI" : planType,
            reset_time: tiers.first?.reset_time, tiers: tiers,
            status_text: status, trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Sakana AI", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    // MARK: - Regex helpers

    private static func capture(_ pattern: String, _ html: String) -> String? {
        guard let match = firstMatch(pattern, html), match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: html) else { return nil }
        let value = html[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func firstMatch(_ pattern: String, _ html: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.firstMatch(in: html, options: [], range: range)
    }
}
#endif
