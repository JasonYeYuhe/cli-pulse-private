// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Zed/ZedStatusProbe.swift
// (https://github.com/steipete/CodexBar). The Keychain credential read (Zed's
// OWN item), the non-Bearer "<userID> <accessToken>" auth header, the
// /client/users/me response model (plan_v3, edit_predictions used/limit incl.
// "unlimited", billing-cycle window, overdue-invoices), and the custom ISO8601
// date decode are ported; the fetch is reimplemented on CLI Pulse's collector
// idiom and mapped to `.quota`.
//
// v1.40.0 — add the (absent) Zed provider. **DEVID-only at runtime**: the App
// Store sandbox cannot read another app's Keychain item, so `isAvailable` is
// gated `#if DEVID_BUILD`. The descriptor stays present on all builds so the
// registry-coverage invariant holds; on MAS the provider is simply never
// available. Keychain queries pass the no-UI flag (`kSecUseAuthenticationUIFail`)
// so a Touch-ID/passcode-protected item fails fast instead of prompting — but a
// Zed item with a restrictive cross-app ACL can STILL make macOS show a one-time
// SecurityAgent "allow access" dialog (upstream docs/zed.md notes the same). To
// avoid re-triggering that dialog every refresh (the prompt-spam class this
// codebase already fixed for Claude — [[feedback_claude_oauth_keychain_prompt_spam]],
// [[feedback_keychain_agent_bug_macos26]]), an interaction-denied read arms a
// 30-min cooldown during which `isAvailable` returns false.
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
import Security

/// Backs off Zed Keychain reads after an interaction-denied result so a
/// restrictive-ACL item can't re-trigger the SecurityAgent dialog every refresh.
enum ZedKeychainGate {
    static let cooldown: TimeInterval = 30 * 60
    nonisolated(unsafe) private static var deniedUntil: Date?
    private static let lock = NSLock()

    static func noteInteractionDenied(now: Date = Date()) {
        lock.withLock { deniedUntil = now.addingTimeInterval(cooldown) }
    }
    static func isCoolingDown(now: Date = Date()) -> Bool {
        lock.withLock { if let d = deniedUntil { return now < d }; return false }
    }
    /// Test seam.
    static func reset() { lock.withLock { deniedUntil = nil } }
}

public struct ZedCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.zed

    static let keychainServer = "https://zed.dev"
    static let cloudAPIURL = "https://cloud.zed.dev/client/users/me"

    public func isAvailable(config: ProviderConfig) -> Bool {
        #if DEVID_BUILD
        // Skip entirely while cooling down from an interaction-denied read, so we
        // don't re-trigger the SecurityAgent ACL dialog every refresh.
        guard !ZedKeychainGate.isCoolingDown() else { return false }
        // Available only when Zed's own credential is present in the Keychain.
        return Self.credentialsPresent()
        #else
        // MAS sandbox cannot read another app's Keychain item.
        return false
        #endif
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        #if DEVID_BUILD
        guard let creds = try Self.loadCredentials() else {
            throw CollectorError.notSignedIn("Zed: sign in from the Zed editor (GitHub)")
        }
        let data = try await Self.fetch(creds)
        let response = try Self.parse(data)
        return Self.buildResult(response)
        #else
        throw CollectorError.missingCredentials("Zed: Developer-ID build only")
        #endif
    }

    // MARK: - Keychain (no-UI; reads Zed's own item)

    /// Applies the no-UI flag so a locked/interaction-required item fails fast
    /// (errSecInteractionNotAllowed) instead of prompting the user.
    private static func noUI(_ query: inout [String: Any]) {
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    /// Cheap presence check (no data returned) for `isAvailable`.
    static func credentialsPresent() -> Bool {
        for cls in [kSecClassInternetPassword, kSecClassGenericPassword] {
            var query: [String: Any] = [
                kSecClass as String: cls,
                (cls == kSecClassInternetPassword ? kSecAttrServer : kSecAttrService) as String: keychainServer,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: false,
            ]
            noUI(&query)
            let status = SecItemCopyMatching(query as CFDictionary, nil)
            if status == errSecSuccess { return true }
            if status == errSecInteractionNotAllowed { ZedKeychainGate.noteInteractionDenied() }
        }
        return false
    }

    /// Loads (userID, accessToken) from Zed's Keychain item — internet-password
    /// first, then generic-password. nil if absent; throws on lock/denial.
    static func loadCredentials() throws -> ZedCredentials? {
        if let c = try read(kSecClassInternetPassword) { return c }
        return try read(kSecClassGenericPassword)
    }

    private static func read(_ cls: CFString) throws -> ZedCredentials? {
        var query: [String: Any] = [
            kSecClass as String: cls,
            (cls == kSecClassInternetPassword ? kSecAttrServer : kSecAttrService) as String: keychainServer,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        noUI(&query)
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: break
        case errSecItemNotFound: return nil
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecNoAccessForItem:
            ZedKeychainGate.noteInteractionDenied()   // back off so we don't re-prompt every refresh
            throw CollectorError.notSignedIn("Zed: Keychain access needs approval — allow access to zed.dev in the dialog, or sign in to Zed again")
        default:
            throw CollectorError.notSignedIn("Zed: could not read Keychain (status \(status))")
        }
        guard let item = result as? [String: Any],
              let account = (item[kSecAttrAccount as String] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines), !account.isEmpty,
              let tokenData = item[kSecValueData as String] as? Data,
              let token = String(data: tokenData, encoding: .utf8), !token.isEmpty
        else { return nil }
        return ZedCredentials(userID: account, accessToken: token)
    }

    struct ZedCredentials: Sendable, Equatable {
        let userID: String
        let accessToken: String
        /// Zed's auth header is "<userID> <accessToken>" — NOT Bearer.
        var authorizationHeader: String { "\(userID) \(accessToken)" }
    }

    // MARK: - Networking

    static func fetch(_ creds: ZedCredentials) async throws -> Data {
        guard let url = URL(string: cloudAPIURL) else { throw CollectorError.invalidURL("zed users/me") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(creds.authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw CollectorError.notSignedIn("Zed: credentials invalid/expired — sign in to Zed again")
        }
        guard status == 200 else { throw CollectorError.httpError(status: status, provider: "Zed") }
        return data
    }

    // MARK: - Parse (pure)

    enum UsageLimit: Equatable, Sendable { case limited(Int), unlimited }

    struct Snapshot: Sendable, Equatable {
        var planV3: String
        var githubLogin: String
        var editUsed: Int
        var editLimit: UsageLimit
        var cycleStart: Date?
        var cycleEnd: Date?
        var hasOverdueInvoices: Bool
    }

    static func parse(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = iso(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601: \(s)")
        }
        let resp: Response
        do {
            resp = try decoder.decode(Response.self, from: data)
        } catch {
            throw CollectorError.parseFailed("Zed: \(error.localizedDescription)")
        }
        return Snapshot(
            planV3: resp.plan.planV3,
            githubLogin: resp.user.githubLogin,
            editUsed: resp.plan.usage.editPredictions.used,
            editLimit: resp.plan.usage.editPredictions.limit.value,
            cycleStart: resp.plan.subscriptionPeriod?.startedAt,
            cycleEnd: resp.plan.subscriptionPeriod?.endedAt,
            hasOverdueInvoices: resp.plan.hasOverdueInvoices)
    }

    private static func iso(_ s: String) -> Date? {
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = frac.date(from: s) { return d }
        let plain = ISO8601DateFormatter(); plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    // MARK: - Result building (.quota — edit predictions + billing cycle)

    static func buildResult(_ s: Snapshot) -> CollectorResult {
        var tiers: [TierDTO] = []
        var status: String
        let planName = displayPlanName(s.planV3)

        // Primary: edit predictions.
        let editRemaining: Int
        let editQuota: Int
        switch s.editLimit {
        case .unlimited:
            editQuota = 100; editRemaining = 100
            tiers.append(TierDTO(name: "Edit Predictions", quota: 100, remaining: 100, reset_time: nil))
            status = "\(planName) · Unlimited edit predictions"
        case let .limited(total):
            let t = max(0, total)
            let used = max(0, min(t, s.editUsed))
            editQuota = t; editRemaining = max(0, t - used)
            tiers.append(TierDTO(name: "Edit Predictions", quota: t, remaining: editRemaining, reset_time: nil))
            status = "\(planName) · \(used) / \(t) edit predictions"
        }

        // Secondary: billing cycle elapsed.
        if let start = s.cycleStart, let end = s.cycleEnd {
            let elapsed = billingCycleUsedPercent(start: start, end: end)
            let reset = sharedISO8601Formatter.string(from: end)
            tiers.append(TierDTO(name: "Billing Cycle", quota: 100,
                                 remaining: Int((100 - elapsed).rounded()), reset_time: reset))
        }
        if s.hasOverdueInvoices { status += " · ⚠︎ overdue invoices" }

        let usage = ProviderUsage(
            provider: ProviderKind.zed.rawValue,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: editQuota, remaining: editRemaining, plan_type: planName,
            reset_time: s.cycleEnd.map { sharedISO8601Formatter.string(from: $0) },
            tiers: tiers, status_text: status,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "Zed", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }

    static func billingCycleUsedPercent(start: Date, end: Date, now: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return max(0, min(100, now.timeIntervalSince(start) / total * 100))
    }

    static func displayPlanName(_ raw: String) -> String {
        switch raw.lowercased() {
        case "zed_free": return "Zed Free"
        case "zed_pro": return "Zed Pro"
        case "zed_pro_trial": return "Zed Pro Trial"
        case "zed_student": return "Zed Student"
        case "zed_business": return "Zed Business"
        default:
            return raw.replacingOccurrences(of: "_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    // MARK: - Response DTOs

    private struct Response: Decodable {
        let user: User
        let plan: Plan
    }
    private struct User: Decodable {
        let githubLogin: String
        enum CodingKeys: String, CodingKey { case githubLogin = "github_login" }
    }
    private struct Plan: Decodable {
        let planV3: String
        let subscriptionPeriod: Period?
        let usage: Usage
        let hasOverdueInvoices: Bool
        enum CodingKeys: String, CodingKey {
            case planV3 = "plan_v3"
            case subscriptionPeriod = "subscription_period"
            case usage
            case hasOverdueInvoices = "has_overdue_invoices"
        }
    }
    private struct Period: Decodable {
        let startedAt: Date
        let endedAt: Date
        enum CodingKeys: String, CodingKey { case startedAt = "started_at", endedAt = "ended_at" }
    }
    private struct Usage: Decodable {
        let editPredictions: UsageData
        enum CodingKeys: String, CodingKey { case editPredictions = "edit_predictions" }
    }
    private struct UsageData: Decodable {
        let used: Int
        let limit: Limit
    }
    private struct Limit: Decodable {
        let value: UsageLimit
        private enum CodingKeys: String, CodingKey { case limited }
        init(from decoder: Decoder) throws {
            // Scalar forms: "unlimited" or a bare Int.
            if let single = try? decoder.singleValueContainer() {
                if let s = try? single.decode(String.self), s == "unlimited" { value = .unlimited; return }
                if let n = try? single.decode(Int.self) { value = .limited(n); return }
            }
            // Serde externally-tagged form: {"limited": N} (upstream fallback).
            if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
               let n = try? keyed.decodeIfPresent(Int.self, forKey: .limited) {
                value = .limited(n); return
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Unrecognized Zed usage limit"))
        }
    }
}
#endif
