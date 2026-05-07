import Foundation

/// Per-provider quota snapshot. Mirrors the Python helper's
/// `estimate_provider_quotas` return shape — a single combined view
/// of what's left for the user this billing window.
public struct ProviderQuotaSnapshot: Codable, Sendable, Equatable {

    /// Top-line quota cap (always 100 in our schema — values are
    /// percent-based).
    public let quota: Int

    /// Top-line remaining percentage (0…100).
    public let remaining: Int

    /// Display name of the user's plan: "Pro", "Max 5x", "Max 20x",
    /// "Plus", "Free", "Unknown".
    public let planType: String?

    /// ISO-8601 next-reset time, when known.
    public let resetTime: String?

    /// Per-window breakdown (Session / Weekly / Opus etc.), in the
    /// order the provider exposes them.
    public let tiers: [ProviderQuotaTier]

    /// Where this snapshot came from. `Phase 4E v2 P0`-required
    /// surfacing so the macOS app's diagnostic block can show the
    /// user which fallback path produced their displayed quota.
    public let provenance: QuotaProvenance

    /// ISO-8601 timestamp of when the helper sampled this snapshot.
    public let fetchedAt: String

    private enum CodingKeys: String, CodingKey {
        case quota
        case remaining
        case planType = "plan_type"
        case resetTime = "reset_time"
        case tiers
        case provenance
        case fetchedAt = "fetched_at"
    }

    public init(
        quota: Int,
        remaining: Int,
        planType: String?,
        resetTime: String?,
        tiers: [ProviderQuotaTier],
        provenance: QuotaProvenance,
        fetchedAt: String
    ) {
        self.quota = quota
        self.remaining = remaining
        self.planType = planType
        self.resetTime = resetTime
        self.tiers = tiers
        self.provenance = provenance
        self.fetchedAt = fetchedAt
    }
}

public struct ProviderQuotaTier: Codable, Sendable, Equatable {
    public let name: String           // "Session", "Weekly", "Opus", etc.
    public let quota: Int             // Always 100 (percentage-based).
    public let remaining: Int         // 0…100 (percentage-based).
    public let resetTime: String?     // ISO-8601 next reset.

    private enum CodingKeys: String, CodingKey {
        case name
        case quota
        case remaining
        case resetTime = "reset_time"
    }

    public init(name: String, quota: Int, remaining: Int, resetTime: String?) {
        self.name = name
        self.quota = quota
        self.remaining = remaining
        self.resetTime = resetTime
    }
}

/// Where a `ProviderQuotaSnapshot` came from. Required by Gemini
/// Phase 4E v2 P0 — without a visible provenance, "the OAuth API
/// failed and we silently fell through to the web cookie which was
/// stale" is indistinguishable from "the API returned bad data".
/// The macOS app's Settings → Diagnostics block displays this so
/// users can verify before reporting bugs.
public enum QuotaProvenance: Codable, Sendable, Equatable {
    /// Anthropic OAuth `/api/oauth/usage` — primary, fresh path.
    case anthropicOAuth
    /// `claude.ai/api/organizations/{id}/usage` via Chromium cookie —
    /// secondary fallback. Currently NOT implemented in Swift port
    /// (Slice 2c.5 follow-up); Python helper still serves this path.
    case anthropicWebCookie
    /// `claude /usage` CLI parse — historical, never fires on v2.x.
    case anthropicCLILegacy
    /// OpenAI WHAM API for Codex.
    case openAIWham
    /// Google Cloud Code `retrieveUserQuota` for Gemini.
    case googleCloudCode
    /// All paths returned no data. `reason` carries a short token
    /// (`"keychain_empty"`, `"oauth_429"`, `"oauth_unauthorized"`,
    /// `"network_error"`, `"parse_error"`, `"plan_only_fallback"`)
    /// so we can correlate with Sentry breadcrumbs.
    case unavailable(reason: String)

    private enum DiscriminatorKey: String, CodingKey { case kind, reason }
    private enum Kind: String, Codable {
        case anthropicOAuth = "anthropic_oauth"
        case anthropicWebCookie = "anthropic_web_cookie"
        case anthropicCLILegacy = "anthropic_cli_legacy"
        case openAIWham = "openai_wham"
        case googleCloudCode = "google_cloud_code"
        case unavailable
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DiscriminatorKey.self)
        switch self {
        case .anthropicOAuth: try c.encode(Kind.anthropicOAuth, forKey: .kind)
        case .anthropicWebCookie: try c.encode(Kind.anthropicWebCookie, forKey: .kind)
        case .anthropicCLILegacy: try c.encode(Kind.anthropicCLILegacy, forKey: .kind)
        case .openAIWham: try c.encode(Kind.openAIWham, forKey: .kind)
        case .googleCloudCode: try c.encode(Kind.googleCloudCode, forKey: .kind)
        case .unavailable(let reason):
            try c.encode(Kind.unavailable, forKey: .kind)
            try c.encode(reason, forKey: .reason)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DiscriminatorKey.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .anthropicOAuth: self = .anthropicOAuth
        case .anthropicWebCookie: self = .anthropicWebCookie
        case .anthropicCLILegacy: self = .anthropicCLILegacy
        case .openAIWham: self = .openAIWham
        case .googleCloudCode: self = .googleCloudCode
        case .unavailable:
            let reason = try c.decode(String.self, forKey: .reason)
            self = .unavailable(reason: reason)
        }
    }
}

/// Plan-name inference from Anthropic's `rate_limit_tier` /
/// `subscription_type` strings. Mirrors `_infer_claude_plan` 1:1.
public enum ClaudePlanInferrer {
    public static func plan(rateLimitTier: String, subscriptionType: String) -> String {
        let combined = "\(rateLimitTier) \(subscriptionType)".lowercased()
        // Specific Max tiers FIRST (before generic max) — order matters.
        if combined.contains("max_20x") || combined.contains("max 20x") { return "Max 20x" }
        if combined.contains("max_5x") || combined.contains("max 5x") { return "Max 5x" }
        if combined.contains("max") { return "Max 5x" }   // default Max → 5x
        for (label, keyword) in [
            ("Ultra", "ultra"), ("Pro", "pro"), ("Team", "team"),
            ("Enterprise", "enterprise"), ("Free", "free"),
        ] where combined.contains(keyword) {
            return label
        }
        if !subscriptionType.isEmpty {
            return subscriptionType.prefix(1).uppercased() + subscriptionType.dropFirst().lowercased()
        }
        return "Unknown"
    }
}
