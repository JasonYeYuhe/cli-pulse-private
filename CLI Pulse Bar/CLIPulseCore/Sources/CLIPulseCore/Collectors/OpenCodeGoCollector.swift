// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/OpenCodeGo/{OpenCodeGoUsageFetcher,
// OpenCodeGoUsageSnapshot,OpenCodeGoZenBalanceParser}.swift
// (https://github.com/steipete/CodexBar). The workspace discovery, the usage
// page regex/JSON parse, the window mapping, and the Zen-balance parse are
// ported; the fetch is reimplemented on CLI Pulse's `CookieResolver` seam +
// URLSession.
//
// CodexBar-parity Phase C-22 — add the (absent) OpenCode Go provider
// (opencode.ai). Most fragile cookie port. Unverifiable (no live session).
//
// CAVEAT / fragility (Gemini C-22 R1): the `_server` workspace discovery uses a
// Next.js server-fn hash that breaks on opencode.ai deploys; the usage page is
// regex/JSON-scraped. The `OPENCODEGO_WORKSPACE_ID` env override is the ROBUST
// PRIMARY path — discovery is a graceful fallback that guides the user to the
// env var when the hash breaks. Best-effort; degrades to clear errors.
//
// Divergences: `URLSession`/`CookieResolver`; no CodexBarLog; JSON window
// finder depth-limited to 3; Zen balance shown in status_text only (a balance,
// not spend — avoids corrupting cost aggregation, Gemini C-22 R1 Q4).
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

/// Reports OpenCode Go rolling/weekly/monthly usage windows via session cookie.
public struct OpenCodeGoCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.openCodeGo

    private static let envVars = ["OPENCODEGO_COOKIE"]
    private static let cookieDomains = ["opencode.ai"]
    private static let knownSessionNames: Set<String> = []
    static let workspaceIDEnv = "OPENCODEGO_WORKSPACE_ID"
    static let serverURL = "https://opencode.ai/_server"
    static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    static let ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
    static let zenGraceSeconds: Double = 5

    public func isAvailable(config: ProviderConfig) -> Bool {
        hasManualOrEnv(config: config) || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        let resolution = await CookieResolver.resolve(
            config: config, envVarNames: Self.envVars,
            domains: Self.cookieDomains, knownSessionCookieNames: Self.knownSessionNames)
        guard let cookie = resolution.headerValue else {
            throw CollectorError.missingCredentials("OpenCode Go: no session cookie")
        }
        let workspaceID = try await resolveWorkspaceID(cookie: cookie, config: config)
        let pageText = try await Self.fetchPage(
            url: "https://opencode.ai/workspace/\(workspaceID)/go", cookie: cookie)
        var snapshot = try Self.parseUsage(pageText)
        snapshot.zenBalanceUSD = await fetchZenWithGrace(workspaceID: workspaceID, cookie: cookie)
        return Self.buildResult(snapshot)
    }

    private func hasManualOrEnv(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        for v in Self.envVars where !(ProcessInfo.processInfo.environment[v] ?? "").isEmpty { return true }
        return false
    }

    // MARK: - Workspace ID (env primary; _server discovery fallback)

    private func resolveWorkspaceID(cookie: String, config: ProviderConfig) async throws -> String {
        if let env = ProcessInfo.processInfo.environment[Self.workspaceIDEnv],
           let id = Self.normalizeWorkspaceID(env) { return id }
        if let manual = config.manualCookieHeader, let id = Self.normalizeWorkspaceID(manual) { return id }
        // Fragile fallback — guides to the env var if the server-fn hash broke.
        return try await Self.discoverWorkspaceID(cookie: cookie)
    }

    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        if raw.hasPrefix("wrk_"), raw.count > 4 { return raw }
        if let m = raw.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) { return String(raw[m]) }
        return nil
    }

    private static func discoverWorkspaceID(cookie: String) async throws -> String {
        guard var c = URLComponents(string: serverURL) else { throw CollectorError.invalidURL("opencodego _server") }
        c.queryItems = [URLQueryItem(name: "id", value: workspacesServerID)]
        guard let url = c.url else { throw CollectorError.invalidURL("opencodego _server") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(workspacesServerID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        if status == 401 || status == 403 || looksSignedOut(text) {
            throw CollectorError.missingCredentials("OpenCode Go: session expired (sign in again)")
        }
        guard status == 200, let id = firstWorkspaceID(in: text) else {
            throw CollectorError.missingCredentials(
                "OpenCode Go: couldn't discover workspace — set OPENCODEGO_WORKSPACE_ID (wrk_…)")
        }
        return id
    }

    static func firstWorkspaceID(in text: String) -> String? {
        if let m = text.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) { return String(text[m]) }
        return nil
    }

    static func looksSignedOut(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("sign in") || t.contains("\"unauthorized\"") || t.contains("login required")
    }

    // MARK: - Page fetch

    static func fetchPage(url: String, cookie: String) async throws -> String {
        guard let u = URL(string: url) else { throw CollectorError.invalidURL("opencodego page") }
        var request = URLRequest(url: u)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        if status == 401 || status == 403 || looksSignedOut(text) {
            throw CollectorError.missingCredentials("OpenCode Go: session expired (sign in again)")
        }
        guard status == 200 else { throw CollectorError.httpError(status: status, provider: "OpenCode Go") }
        return text
    }

    private func fetchZenWithGrace(workspaceID: String, cookie: String) async -> Double? {
        await withTaskGroup(of: Double?.self) { group in
            group.addTask {
                guard let text = try? await Self.fetchPage(
                    url: "https://opencode.ai/workspace/\(workspaceID)", cookie: cookie) else { return nil }
                return Self.parseZenBalance(text)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, Self.zenGraceSeconds) * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // MARK: - Usage parse (regex primary; depth-limited JSON fallback)

    struct Snapshot: Sendable, Equatable {
        var rollingUsedPercent: Double
        var weeklyUsedPercent: Double
        var monthlyUsedPercent: Double?
        var rollingResetSec: Int
        var weeklyResetSec: Int
        var monthlyResetSec: Int?
        var zenBalanceUSD: Double?
    }

    static func parseUsage(_ text: String) throws -> Snapshot {
        func dbl(_ window: String) -> Double? {
            extractDouble(#"\#(window)[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text)
        }
        func sec(_ window: String) -> Int? {
            extractInt(#"\#(window)[^}]*?resetInSec\s*:\s*([0-9]+)"#, text)
        }
        if let r = dbl("rollingUsage"), let rs = sec("rollingUsage"),
           let w = dbl("weeklyUsage"), let ws = sec("weeklyUsage") {
            return Snapshot(
                rollingUsedPercent: clamp(r), weeklyUsedPercent: clamp(w),
                monthlyUsedPercent: dbl("monthlyUsage").map(clamp),
                rollingResetSec: rs, weeklyResetSec: ws, monthlyResetSec: sec("monthlyUsage"))
        }
        if let s = parseUsageJSON(text) { return s }
        throw CollectorError.parseFailed("OpenCode Go: usage fields not found")
    }

    /// Depth-limited (≤3) JSON window finder fallback.
    static func parseUsageJSON(_ text: String) -> Snapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        guard let rolling = findWindow(["rolling", "hour", "5h"], in: object, depth: 0),
              let weekly = findWindow(["weekly", "week"], in: object, depth: 0) else { return nil }
        let monthly = findWindow(["monthly", "month"], in: object, depth: 0)
        return Snapshot(
            rollingUsedPercent: rolling.0, weeklyUsedPercent: weekly.0, monthlyUsedPercent: monthly?.0,
            rollingResetSec: rolling.1, weeklyResetSec: weekly.1, monthlyResetSec: monthly?.1)
    }

    private static func findWindow(_ needles: [String], in object: Any, depth: Int) -> (Double, Int)? {
        guard depth <= 3 else { return nil }
        if let dict = object as? [String: Any] {
            for (key, value) in dict where needles.contains(where: { key.lowercased().contains($0) }) {
                if let sub = value as? [String: Any], let w = parseWindow(sub) { return w }
            }
            for value in dict.values {
                if let f = findWindow(needles, in: value, depth: depth + 1) { return f }
            }
        }
        if let array = object as? [Any] {
            for value in array { if let f = findWindow(needles, in: value, depth: depth + 1) { return f } }
        }
        return nil
    }

    private static func parseWindow(_ dict: [String: Any]) -> (Double, Int)? {
        let percentKeys = ["usagePercent", "usedPercent", "percentUsed", "percent", "utilization"]
        var pct: Double?
        for k in percentKeys { if let v = num(dict[k]) { pct = v; break } }
        if pct == nil, let used = num(dict["used"]), let limit = num(dict["limit"]), limit > 0 {
            pct = used / limit * 100
        }
        guard var p = pct else { return nil }
        if p <= 1, p >= 0 { p *= 100 }
        let resetKeys = ["resetInSec", "resetInSeconds", "resetSeconds", "resetSec"]
        var reset = 0
        for k in resetKeys { if let v = num(dict[k]) { reset = Int(v); break } }
        return (clamp(p), reset)
    }

    // MARK: - Zen balance (ported; balance keys + $ regex)

    static func parseZenBalance(_ text: String) -> Double? {
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
           let v = findBalance(object, depth: 0) { return v }
        if let m = matchGroup(#"(?i)(?:zen\s*balance|current\s*balance)[\s\S]{0,120}?\$\s*([0-9][0-9,]*(?:\.[0-9]+)?)"#, text) {
            return Double(m.replacingOccurrences(of: ",", with: ""))
        }
        return nil
    }

    private static func findBalance(_ object: Any, depth: Int) -> Double? {
        guard depth <= 4 else { return nil }
        let keys = ["zenbalance", "zencurrentbalance", "currentbalance", "currentbalanceusd", "balanceusd", "usdbalance"]
        if let dict = object as? [String: Any] {
            for (k, v) in dict {
                if keys.contains(k.lowercased().filter { $0.isLetter || $0.isNumber }), let n = num(v) { return n }
                if let f = findBalance(v, depth: depth + 1) { return f }
            }
        }
        if let array = object as? [Any] {
            for v in array { if let f = findBalance(v, depth: depth + 1) { return f } }
        }
        return nil
    }

    // MARK: - Result building (.quota windows; Zen in status_text only)

    static func buildResult(_ s: Snapshot) -> CollectorResult {
        func windowTier(_ name: String, used: Double, resetSec: Int) -> TierDTO {
            let remaining = Int((100 - clamp(used)).rounded())
            let reset = resetSec > 0
                ? sharedISO8601Formatter.string(from: Date().addingTimeInterval(TimeInterval(resetSec))) : nil
            return TierDTO(name: name, quota: 100, remaining: remaining, reset_time: reset)
        }
        var tiers = [
            windowTier("Rolling", used: s.rollingUsedPercent, resetSec: s.rollingResetSec),
            windowTier("Weekly", used: s.weeklyUsedPercent, resetSec: s.weeklyResetSec),
        ]
        if let m = s.monthlyUsedPercent {
            tiers.append(windowTier("Monthly", used: m, resetSec: s.monthlyResetSec ?? 0))
        }
        let rollingRemaining = Int((100 - clamp(s.rollingUsedPercent)).rounded())
        let weeklyRemaining = Int((100 - clamp(s.weeklyUsedPercent)).rounded())
        var status = "Rolling \(rollingRemaining)% · Weekly \(weeklyRemaining)% left"
        if let zen = s.zenBalanceUSD { status += String(format: " · $%.2f Zen", zen) }

        let usage = ProviderUsage(
            provider: ProviderKind.openCodeGo.rawValue, today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: 100, remaining: rollingRemaining, plan_type: "OpenCode Go",
            reset_time: tiers.first?.reset_time, tiers: tiers,
            status_text: status, trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "OpenCode Go", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    // MARK: - Small helpers

    static func clamp(_ p: Double) -> Double { max(0, min(100, p)) }
    static func num(_ raw: Any?) -> Double? {
        if let b = raw as? Bool { _ = b; return nil }
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")) }
        return nil
    }
    static func extractDouble(_ pattern: String, _ text: String) -> Double? { matchGroup(pattern, text).flatMap(Double.init) }
    static func extractInt(_ pattern: String, _ text: String) -> Int? { matchGroup(pattern, text).flatMap { Int($0) } }
    static func matchGroup(_ pattern: String, _ text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let m = regex.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}
#endif
