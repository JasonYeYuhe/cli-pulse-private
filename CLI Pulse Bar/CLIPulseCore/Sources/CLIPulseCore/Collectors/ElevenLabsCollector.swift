// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/ElevenLabs/
// {ElevenLabsUsageFetcher,ElevenLabsSettingsReader}.swift
// (https://github.com/steipete/CodexBar). The Codable response
// model, displayTier transform, and Unix→Date reset semantics are
// vendored; fetch + mapping reimplemented on CLI Pulse's api-key
// collector idiom (`ZaiCollector`/`DeepSeekCollector` precedent).
//
// CodexBar-parity Phase C-3 — promote the (absent) ElevenLabs
// provider to a real `.quota` collector (character_limit cap +
// next_character_count_reset_unix renewal). Custom `xi-api-key`
// header (NOT `Authorization: Bearer`) — the only auth-shape quirk
// vs C-1/C-2.
//
// Divergences from upstream:
//   * fetch via URLSession; no CodexBar HTTP transport / log.
//   * `dataKind .quota` with the standard CLI Pulse quota
//     (quota/remaining/reset_time) instead of CodexBar's
//     `RateWindow`+`extraRateWindows`; voice-slot sub-quotas
//     surface as additional `TierDTO`s (Gemini Phase-C3 R1 LOW).
//   * Env-var quote-stripping NOT ported (YAGNI per Gemini C-2 LOW
//     + C-3 LOW — match Zai/Crof/DeepSeek).
//   * `current_overage` surfaces in `status_text` when non-nil
//     (Gemini R1 MEDIUM) rather than polluting `plan_type`.
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

/// Fetches ElevenLabs character-quota + voice-slot subscription via
/// api-key auth.
///
/// Endpoint: `GET https://api.elevenlabs.io/v1/user/subscription`
/// Auth: custom `xi-api-key: <apiKey>` header (NOT Bearer).
public struct ElevenLabsCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.elevenLabs

    private static let subscriptionURL = "https://api.elevenlabs.io/v1/user/subscription"
    private static let envVars = ["ELEVENLABS_API_KEY", "XI_API_KEY"]

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials("ElevenLabs: no API key found")
        }
        let data = try await fetchSubscription(token: token)
        let parsed = try Self.parseResponse(data)
        return buildResult(parsed)
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

    private func fetchSubscription(token: String) async throws -> Data {
        guard let url = URL(string: Self.subscriptionURL) else {
            throw CollectorError.invalidURL("elevenlabs subscription")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        // The quirk: ElevenLabs uses `xi-api-key`, not `Authorization: Bearer`.
        request.setValue(token, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299:
            return data
        case 401, 403:
            throw CollectorError.missingCredentials("ElevenLabs: API key rejected (HTTP \(status))")
        default:
            throw CollectorError.httpError(status: status, provider: "ElevenLabs")
        }
    }

    // MARK: - Response model (vendored verbatim, snake_case)

    struct Overage: Decodable, Sendable, Equatable {
        let amount: String?
        let currency: String?
    }

    struct SubscriptionResponse: Decodable, Sendable {
        let tier: String?
        let characterCount: Int
        let characterLimit: Int
        let voiceSlotsUsed: Int?
        let professionalVoiceSlotsUsed: Int?
        let voiceLimit: Int?
        let professionalVoiceLimit: Int?
        let currentOverage: Overage?
        let status: String?
        let nextCharacterCountResetUnix: Int?

        enum CodingKeys: String, CodingKey {
            case tier
            case characterCount = "character_count"
            case characterLimit = "character_limit"
            case voiceSlotsUsed = "voice_slots_used"
            case professionalVoiceSlotsUsed = "professional_voice_slots_used"
            case voiceLimit = "voice_limit"
            case professionalVoiceLimit = "professional_voice_limit"
            case currentOverage = "current_overage"
            case status
            case nextCharacterCountResetUnix = "next_character_count_reset_unix"
        }
    }

    static func parseResponse(_ data: Data) throws -> SubscriptionResponse {
        do {
            return try JSONDecoder().decode(SubscriptionResponse.self, from: data)
        } catch {
            throw CollectorError.parseFailed("ElevenLabs: \(error.localizedDescription)")
        }
    }

    /// Port of CodexBar's `displayTier`: snake_case tier rendered as
    /// Title Case + optional " · {status}" suffix when status is
    /// non-nil and not "active" (Gemini R1 MEDIUM — verbatim).
    /// Returns the raw status when tier is nil/empty; nil when both
    /// are absent.
    static func displayTier(_ tier: String?, status: String?) -> String? {
        let trimmedTier = tier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedTier.isEmpty { return status?.isEmpty == true ? nil : status }
        let titled = trimmedTier.replacingOccurrences(of: "_", with: " ").capitalized
        if let s = status, !s.isEmpty, s.lowercased() != "active" {
            return "\(titled) · \(s)"
        }
        return titled
    }

    /// Locale-formatted with grouping commas (en_US_POSIX) — matches
    /// CodexBar's characterSummary.
    static func formatCount(_ value: Int) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    // MARK: - Result building (.quota with character cap + reset)

    func buildResult(_ r: SubscriptionResponse) -> CollectorResult {
        let remaining = max(0, r.characterLimit - r.characterCount)
        let quota: Int? = r.characterLimit > 0 ? r.characterLimit : nil
        let resetISO: String? = r.nextCharacterCountResetUnix.map {
            sharedISO8601Formatter.string(from: Date(timeIntervalSince1970: TimeInterval($0)))
        }

        // Primary characters tier + optional voice-slot sub-tiers
        // (Gemini R1 LOW — preserves the CodexBar extraRateWindows).
        var tiers: [TierDTO] = []
        if let q = quota {
            tiers.append(TierDTO(
                name: "Characters", quota: q, remaining: remaining, reset_time: resetISO))
        }
        if let used = r.voiceSlotsUsed, let limit = r.voiceLimit, limit > 0 {
            tiers.append(TierDTO(
                name: "Voice slots", quota: limit, remaining: max(0, limit - used),
                reset_time: nil))
        }
        if let used = r.professionalVoiceSlotsUsed,
           let limit = r.professionalVoiceLimit, limit > 0 {
            tiers.append(TierDTO(
                name: "Professional voices", quota: limit, remaining: max(0, limit - used),
                reset_time: nil))
        }

        // status_text: "X / Y characters" plus overage suffix if
        // non-nil (Gemini R1 MEDIUM — surface, don't pollute plan_type).
        var statusText = "\(Self.formatCount(r.characterCount)) / \(Self.formatCount(r.characterLimit)) characters"
        if let o = r.currentOverage,
           let amount = o.amount?.trimmingCharacters(in: .whitespacesAndNewlines), !amount.isEmpty,
           let currency = o.currency?.trimmingCharacters(in: .whitespacesAndNewlines), !currency.isEmpty {
            statusText += " (Overage: \(amount) \(currency))"
        }

        let usage = ProviderUsage(
            provider: ProviderKind.elevenLabs.rawValue,
            today_usage: r.characterCount, week_usage: r.characterCount,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: quota, remaining: remaining,
            plan_type: Self.displayTier(r.tier, status: r.status) ?? "API key",
            reset_time: resetISO,
            tiers: tiers,
            status_text: statusText,
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(
                display_name: "ElevenLabs", category: "cloud",
                supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
