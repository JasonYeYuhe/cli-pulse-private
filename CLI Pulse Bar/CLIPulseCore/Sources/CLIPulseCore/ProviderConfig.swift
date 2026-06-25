import Foundation
import SwiftUI

// MARK: - Provider Configuration (local state, not from API)

/// Non-sensitive fields that persist in UserDefaults.
/// Secrets (apiKey, manualCookieHeader) are stored/loaded separately via Keychain.
public struct ProviderConfig: Codable, Identifiable, Sendable {
    public let kind: ProviderKind
    public var isEnabled: Bool
    public var sortOrder: Int
    public var sourceMode: SourceType
    public var cookieSource: CookieSource?
    public var accountLabel: String?
    /// v1.23.0 G3 (CodexBar parity, dark/opt-in): when true, the Gemini
    /// collector may fall back to the vendored `GeminiStatusProbe`
    /// (Gemini-CLI-package OAuth path) *only* when its own
    /// Keychain/file credential path has no usable token. Optional ⇒
    /// absent in existing serialized configs ⇒ decodes nil ⇒ OFF ⇒
    /// byte-identical production behavior (same dark-safe pattern as
    /// `cookieSource`). Gemini-only; ignored by other providers.
    public var geminiCliProbeFallback: Bool?

    // Transient — never encoded into UserDefaults.  Populated at runtime from Keychain.
    public var apiKey: String?
    public var manualCookieHeader: String?

    public var id: String { kind.rawValue }

    // Only encode non-sensitive fields to UserDefaults
    private enum CodingKeys: String, CodingKey {
        case kind, isEnabled, sortOrder, sourceMode, cookieSource, accountLabel
        case geminiCliProbeFallback
    }

    public init(
        kind: ProviderKind,
        isEnabled: Bool = true,
        sortOrder: Int = 0,
        sourceMode: SourceType = .auto,
        apiKey: String? = nil,
        cookieSource: CookieSource? = nil,
        manualCookieHeader: String? = nil,
        accountLabel: String? = nil,
        geminiCliProbeFallback: Bool? = nil
    ) {
        self.kind = kind
        self.isEnabled = isEnabled
        self.sortOrder = sortOrder
        self.sourceMode = sourceMode
        self.apiKey = apiKey
        self.cookieSource = cookieSource
        self.manualCookieHeader = manualCookieHeader
        self.accountLabel = accountLabel
        self.geminiCliProbeFallback = geminiCliProbeFallback
    }

    public static func defaults() -> [ProviderConfig] {
        ProviderKind.allCases.enumerated().map { index, kind in
            ProviderConfig(kind: kind, isEnabled: true, sortOrder: index)
        }
    }

    /// Whether this provider has any credentials configured
    public var hasCredentials: Bool {
        (apiKey != nil && !(apiKey?.isEmpty ?? true)) ||
        (manualCookieHeader != nil && !(manualCookieHeader?.isEmpty ?? true)) ||
        cookieSource != nil
    }

    // MARK: - Keychain secret helpers

    private static func keychainKey(_ kind: ProviderKind, _ suffix: String) -> String {
        "cli_pulse_provider_\(kind.rawValue)_\(suffix)"
    }

    /// Access group for per-provider secrets. On macOS the items live in the
    /// shared app-group keychain so the LoginItem helper reads them prompt-free
    /// (see `KeychainHelper.migrateToSharedGroup`). On iOS/watchOS there is no
    /// cross-process helper reading these items, so we keep `nil` (no group) —
    /// byte-identical to pre-2026-06-26 behavior, and no iOS entitlement change
    /// is required.
    static var secretsAccessGroup: String? {
        #if os(macOS)
        return KeychainHelper.sharedAccessGroup
        #else
        return nil
        #endif
    }

    /// Save this config's secrets to Keychain. Call after mutating apiKey / manualCookieHeader.
    public func saveSecrets() {
        let group = Self.secretsAccessGroup
        let apiKeyKey = Self.keychainKey(kind, "apiKey")
        if let key = apiKey, !key.isEmpty {
            KeychainHelper.save(key: apiKeyKey, value: key, accessGroup: group)
        } else {
            KeychainHelper.delete(key: apiKeyKey, accessGroup: group)
        }

        let cookieKey = Self.keychainKey(kind, "cookie")
        if let cookie = manualCookieHeader, !cookie.isEmpty {
            KeychainHelper.save(key: cookieKey, value: cookie, accessGroup: group)
        } else {
            KeychainHelper.delete(key: cookieKey, accessGroup: group)
        }
    }

    /// Load secrets from Keychain into the in-memory fields.
    public mutating func loadSecrets() {
        let group = Self.secretsAccessGroup
        apiKey = KeychainHelper.load(key: Self.keychainKey(kind, "apiKey"), accessGroup: group)
        manualCookieHeader = KeychainHelper.load(key: Self.keychainKey(kind, "cookie"), accessGroup: group)
    }

    /// Remove all Keychain entries for this provider.
    public func deleteSecrets() {
        let group = Self.secretsAccessGroup
        KeychainHelper.delete(key: Self.keychainKey(kind, "apiKey"), accessGroup: group)
        KeychainHelper.delete(key: Self.keychainKey(kind, "cookie"), accessGroup: group)
    }
}

// MARK: - Cookie Source

public enum CookieSource: String, Codable, CaseIterable, Sendable {
    /// CodexBar-parity G1: auto-import the session cookie from any installed
    /// browser (macOS only, via SweetCookieKit). Opt-in — existing configs
    /// keep `nil`/`.manual` and behave exactly as before. Not offered on
    /// iOS/watchOS (no browser cookie stores there).
    case automatic = "Automatic"
    case safari = "Safari"
    case chrome = "Chrome"
    case firefox = "Firefox"
    case manual = "Manual"
}

// MARK: - Usage Tier (e.g., Pro/Flash/Flash Lite for Gemini)

public struct UsageTier: Codable, Identifiable, Sendable {
    public let name: String
    public let usage: Int
    public let quota: Int?
    public let remaining: Int?
    public let resetTime: String?
    /// Window length in minutes (5h = 300, weekly = 10080). v1.30: carried so
    /// the expected-pace bar marker uses the correct per-window duration
    /// instead of the engine's weekly default. Optional + back-compat.
    public let windowMinutes: Int?

    public var id: String { name }

    public var usagePercent: Double {
        guard let quota = quota, quota > 0 else { return 0 }
        let used = quota - (remaining ?? 0)
        return min(1.0, Double(used) / Double(quota))
    }

    public init(name: String, usage: Int, quota: Int?, remaining: Int?, resetTime: String?, windowMinutes: Int? = nil) {
        self.name = name
        self.usage = usage
        self.quota = quota
        self.remaining = remaining
        self.resetTime = resetTime
        self.windowMinutes = windowMinutes
    }
}

// MARK: - Enhanced Provider Detail (combines API data + local config)

public struct ProviderDetail: Identifiable, Equatable {
    public static func == (lhs: ProviderDetail, rhs: ProviderDetail) -> Bool {
        lhs.id == rhs.id &&
        lhs.config.isEnabled == rhs.config.isEnabled &&
        lhs.config.sortOrder == rhs.config.sortOrder &&
        lhs.operationalStatus == rhs.operationalStatus &&
        lhs.sourceType == rhs.sourceType
    }

    public let provider: ProviderUsage
    public var config: ProviderConfig
    public var tiers: [UsageTier]
    public var operationalStatus: ProviderStatus
    public var accountEmail: String?
    public var planType: String?
    public var sourceType: SourceType
    public var version: String?

    public var id: String { provider.id }

    public init(
        provider: ProviderUsage,
        config: ProviderConfig,
        tiers: [UsageTier] = [],
        operationalStatus: ProviderStatus = .operational,
        accountEmail: String? = nil,
        planType: String? = nil,
        sourceType: SourceType = .auto,
        version: String? = nil
    ) {
        self.provider = provider
        self.config = config
        self.tiers = tiers
        self.operationalStatus = operationalStatus
        self.accountEmail = accountEmail
        self.planType = planType
        self.sourceType = sourceType
        self.version = version
    }
}

// MARK: - Menu Bar Display Mode

public enum MenuBarDisplayMode: String, Codable, CaseIterable, Sendable {
    case icon = "Icon"
    case percent = "Percent"
    case pace = "Pace"
    case mostUsed = "Most Used"

    public var localizedName: String {
        switch self {
        case .icon: return L10n.display.icon
        case .percent: return L10n.display.percent
        case .pace: return L10n.display.pace
        case .mostUsed: return L10n.display.mostUsed
        }
    }

    public var description: String {
        switch self {
        case .icon: return "App icon only"
        case .percent: return "Remaining % of most-used"
        case .pace: return "Usage vs expected pace"
        case .mostUsed: return "Most active provider"
        }
    }
}

// MARK: - Menu Bar Content Mode

public enum MenuBarContentMode: String, Codable, CaseIterable, Sendable {
    case usageAsUsed = "Usage (Used)"
    case resetTime = "Reset Time"
    case credits = "Credits"
    case allAccounts = "All Accounts"
}

// MARK: - Provider Descriptor (metadata + capabilities)

public struct ProviderDescriptor: Sendable {
    public let kind: ProviderKind
    public let displayName: String
    public let category: ProviderCategory
    public let supportedSources: [SourceType]
    public let supportsQuota: Bool
    public let supportsExactCost: Bool
    public let supportsCredits: Bool
    public let supportsStatusPolling: Bool
    public let requiresHelperBackend: Bool
    public let cliNames: [String]
    public let webDomain: String?

    public init(
        kind: ProviderKind,
        displayName: String,
        category: ProviderCategory,
        supportedSources: [SourceType],
        supportsQuota: Bool = true,
        supportsExactCost: Bool = false,
        supportsCredits: Bool = false,
        supportsStatusPolling: Bool = false,
        requiresHelperBackend: Bool = false,
        cliNames: [String] = [],
        webDomain: String? = nil
    ) {
        self.kind = kind
        self.displayName = displayName
        self.category = category
        self.supportedSources = supportedSources
        self.supportsQuota = supportsQuota
        self.supportsExactCost = supportsExactCost
        self.supportsCredits = supportsCredits
        self.supportsStatusPolling = supportsStatusPolling
        self.requiresHelperBackend = requiresHelperBackend
        self.cliNames = cliNames
        self.webDomain = webDomain
    }
}

// MARK: - Provider Registry

public enum ProviderRegistry {
    public static let all: [ProviderKind: ProviderDescriptor] = {
        var registry: [ProviderKind: ProviderDescriptor] = [:]
        for d in descriptors { registry[d.kind] = d }
        return registry
    }()

    public static func descriptor(for kind: ProviderKind) -> ProviderDescriptor {
        all[kind] ?? ProviderDescriptor(
            kind: kind, displayName: kind.rawValue, category: .cloud,
            supportedSources: [.auto]
        )
    }

    private static let descriptors: [ProviderDescriptor] = [
        ProviderDescriptor(
            kind: .codex, displayName: "Codex (OpenAI)", category: .cloud,
            supportedSources: [.auto, .web, .cli, .oauth, .api],
            supportsQuota: true, supportsExactCost: true, supportsCredits: true,
            supportsStatusPolling: true, requiresHelperBackend: true,
            cliNames: ["codex"], webDomain: "chatgpt.com"
        ),
        ProviderDescriptor(
            kind: .claude, displayName: "Claude (Anthropic)", category: .cloud,
            supportedSources: [.auto, .web, .cli, .oauth, .api],
            supportsQuota: true, supportsExactCost: true, supportsCredits: true,
            supportsStatusPolling: true, requiresHelperBackend: true,
            cliNames: ["claude"], webDomain: "claude.ai"
        ),
        ProviderDescriptor(
            kind: .gemini, displayName: "Gemini (Google)", category: .cloud,
            supportedSources: [.auto, .web, .oauth, .api],
            supportsQuota: true, supportsExactCost: false, supportsCredits: true,
            supportsStatusPolling: true, requiresHelperBackend: true,
            cliNames: ["gemini"], webDomain: "aistudio.google.com"
        ),
        ProviderDescriptor(
            kind: .cursor, displayName: "Cursor", category: .ide,
            supportedSources: [.auto, .web, .local],
            supportsQuota: true, supportsExactCost: false,
            supportsStatusPolling: true, requiresHelperBackend: true,
            cliNames: ["cursor"], webDomain: "cursor.com"
        ),
        ProviderDescriptor(
            kind: .copilot, displayName: "GitHub Copilot", category: .ide,
            supportedSources: [.auto, .web, .oauth],
            supportsQuota: true, supportsExactCost: false,
            supportsStatusPolling: true, requiresHelperBackend: true,
            cliNames: ["copilot"], webDomain: "github.com"
        ),
        ProviderDescriptor(
            kind: .openCode, displayName: "OpenCode", category: .cloud,
            supportedSources: [.auto, .cli],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["opencode"]
        ),
        ProviderDescriptor(
            kind: .droid, displayName: "Droid / Factory", category: .cloud,
            supportedSources: [.auto, .web, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["droid", "factory"], webDomain: "factory.ai"
        ),
        ProviderDescriptor(
            kind: .antigravity, displayName: "Antigravity", category: .cloud,
            supportedSources: [.auto, .local],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["antigravity"]
        ),
        ProviderDescriptor(
            kind: .zai, displayName: "z.ai", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["zai"], webDomain: "z.ai"
        ),
        ProviderDescriptor(
            kind: .minimax, displayName: "MiniMax", category: .cloud,
            supportedSources: [.auto, .web, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["minimax"], webDomain: "minimax.io"
        ),
        ProviderDescriptor(
            kind: .augment, displayName: "Augment", category: .ide,
            supportedSources: [.auto, .local],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["augment"]
        ),
        ProviderDescriptor(
            kind: .jetbrainsAI, displayName: "JetBrains AI", category: .ide,
            supportedSources: [.auto, .local],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["jbai"]
        ),
        ProviderDescriptor(
            kind: .kimiK2, displayName: "Kimi K2 (Moonshot)", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["kimi-k2"], webDomain: "kimi.moonshot.cn"
        ),
        ProviderDescriptor(
            kind: .kimi, displayName: "Kimi (Moonshot)", category: .cloud,
            supportedSources: [.auto, .web, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["kimi"], webDomain: "kimi.moonshot.cn"
        ),
        ProviderDescriptor(
            kind: .amp, displayName: "Amp", category: .cloud,
            supportedSources: [.auto, .web, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["amp"], webDomain: "amp.dev"
        ),
        ProviderDescriptor(
            kind: .synthetic, displayName: "Synthetic", category: .cloud,
            supportedSources: [.auto],
            supportsQuota: true
        ),
        ProviderDescriptor(
            kind: .warp, displayName: "Warp", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["warp"], webDomain: "warp.dev"
        ),
        ProviderDescriptor(
            kind: .kilo, displayName: "Kilo Code", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["kilo"]
        ),
        ProviderDescriptor(
            kind: .ollama, displayName: "Ollama (Local)", category: .local,
            supportedSources: [.auto, .local, .api],
            supportsQuota: false, supportsExactCost: false,
            cliNames: ["ollama"]
        ),
        ProviderDescriptor(
            kind: .openRouter, displayName: "OpenRouter", category: .aggregator,
            supportedSources: [.auto, .api],
            supportsQuota: true, supportsExactCost: true, supportsCredits: true,
            requiresHelperBackend: true,
            cliNames: ["openrouter"], webDomain: "openrouter.ai"
        ),
        ProviderDescriptor(
            kind: .alibaba, displayName: "Alibaba Coding Plan", category: .cloud,
            supportedSources: [.auto, .web, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["alibaba", "tongyi"], webDomain: "tongyi.aliyun.com"
        ),
        ProviderDescriptor(
            kind: .kiro, displayName: "Kiro (AWS)", category: .ide,
            supportedSources: [.auto, .cli],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["kiro"]
        ),
        ProviderDescriptor(
            kind: .vertexAI, displayName: "Vertex AI (Google Cloud)", category: .cloud,
            // v1.23.0 Phase B-2: real collector via gcloud ADC (OAuth
            // user creds) — drop `.api` (no API-key path);
            // exactCost:false (fetcher returns only a usage %, no $);
            // requiresHelperBackend false (in-app now, metadata-only).
            supportedSources: [.auto, .oauth],
            supportsQuota: true, supportsExactCost: false,
            requiresHelperBackend: false,
            webDomain: "console.cloud.google.com"
        ),
        ProviderDescriptor(
            kind: .perplexity, displayName: "Perplexity", category: .cloud,
            // v1.23.0 Phase B-1: real cookie-based collector — `.web`
            // so the auth UI asks for a session cookie, not an API key
            // (Gemini Phase-B R1 Q3); requiresHelperBackend flipped
            // false (now collected in-app; the flag is metadata-only).
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: true,
            requiresHelperBackend: false,
            cliNames: ["perplexity", "pplx"], webDomain: "perplexity.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-1 (CodexBar parity): new api-key
            // provider — Bearer key, single billing endpoint.
            kind: .crof, displayName: "Crof", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, supportsExactCost: false, supportsCredits: true,
            requiresHelperBackend: false,
            cliNames: ["crof"], webDomain: "crof.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-2 (CodexBar parity): credits-only
            // (uncapped balance, no quota cap). Bearer api-key.
            kind: .deepseek, displayName: "DeepSeek", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: true,
            requiresHelperBackend: false,
            cliNames: ["deepseek"], webDomain: "platform.deepseek.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-3: real character-quota collector
            // (xi-api-key header — not Bearer). Cap + reset_unix.
            kind: .elevenLabs, displayName: "ElevenLabs", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["elevenlabs", "eleven-labs"], webDomain: "elevenlabs.io"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-4: credits provider with USD + DIEM
            // dual currency (DIEM optionally has an epoch allocation
            // cap → surfaced via per-currency TierDTOs, not top-level
            // quota — `.credits` consistency with DeepSeek precedent).
            kind: .venice, displayName: "Venice", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: true,
            requiresHelperBackend: false,
            cliNames: ["venice"], webDomain: "venice.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-5: status-only deployment validator. No
            // quota/credits number — a tiny "ping" chat-completion
            // confirms the deployment is reachable and surfaces the
            // resolved model. Multi-field config (key + endpoint +
            // deployment + api-version) comes from env (AZURE_OPENAI_*),
            // since ProviderConfig only stores `apiKey`.
            kind: .azureOpenAI, displayName: "Azure OpenAI", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["azure-openai", "azureopenai", "aoai"], webDomain: "ai.azure.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-6: credits provider with a hard cap + reset
            // ⇒ .quota gauge (ElevenLabs precedent). Bearer api-key, primary
            // POST /api/v1/usage; best-effort GET /api/user/subscription
            // enriches weekly window + tier (concurrent, ~2s grace-bounded).
            kind: .codebuff, displayName: "Codebuff", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: true, supportsExactCost: false, supportsCredits: true,
            requiresHelperBackend: false,
            cliNames: ["codebuff", "manicode"], webDomain: "codebuff.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-7: status-only usage reporter. No quota /
            // credits denominator — aggregates absolute usage counts
            // (requests / audio hours / tokens) across projects.
            // `Authorization: Token <key>` (not Bearer). Auto-discovers
            // projects (capped + concurrent + absolute-timeout bounded);
            // DEEPGRAM_PROJECT_ID pins a single project.
            kind: .deepgram, displayName: "Deepgram", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["deepgram", "dg"], webDomain: "deepgram.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-8: cookie collector — `session_id` value sent
            // as a Bearer token (not a Cookie header); `.web` so the auth UI
            // asks for a session cookie. Two capped credit pools → `.quota`
            // (supportsCredits:false ⇒ treated as quota, per scoping).
            kind: .manus, displayName: "Manus", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["manus"], webDomain: "manus.im"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-9: cookie collector — full Cookie header
            // passthrough (multi-cookie; not a Bearer like Manus). 2 endpoints
            // (compute-points required + billing bounded) → `.quota` compute
            // points (supportsCredits:false ⇒ quota).
            kind: .abacus, displayName: "Abacus AI", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["abacus"], webDomain: "abacus.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-10: cookie collector — pay-as-you-go, no quota
            // cap/balance ⇒ `.statusOnly` carrying exact month-to-date spend
            // (supportsExactCost:true). Cookie header (ory_session_* + csrftoken).
            kind: .mistral, displayName: "Mistral", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: false, supportsExactCost: true, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["mistral", "mistral-ai"], webDomain: "mistral.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-11: cookie collector — USD `.credits` (monthly
            // grant cap from a static plan catalog + 3 balance pools).
            // better-auth.session_token cookie.
            kind: .commandCode, displayName: "Command Code", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: false, supportsExactCost: true, supportsCredits: true,
            requiresHelperBackend: false,
            cliNames: ["commandcode", "command-code"], webDomain: "commandcode.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-12: api-key collector — Prometheus throughput
            // metrics only (no quota/cost) ⇒ `.statusOnly` req/min · tok/min.
            kind: .groq, displayName: "Groq", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["groq"], webDomain: "groq.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-13: api-key collector — Moonshot DEVELOPER API
            // platform USD balance (distinct from Kimi/Kimi K2 consumer chat).
            // Uncapped balance ⇒ `.credits`.
            kind: .moonshot, displayName: "Moonshot", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: true,
            requiresHelperBackend: false,
            cliNames: ["moonshot"], webDomain: "moonshot.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-14: api-key collector — self-hosted LLM gateway
            // quota-stats aggregate (env LLM_PROXY_BASE_URL). `.statusOnly`
            // (min remaining-% + key/req/tok stats); aggregator category.
            kind: .llmProxy, displayName: "LLM Proxy", category: .aggregator,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["llmproxy", "llm-proxy"], webDomain: nil
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-15: api-key collector — OpenAI ORG admin cost API
            // (sk-admin- key), month-to-date spend ⇒ `.statusOnly` exact cost.
            // Distinct from Codex (the OpenAI Codex CLI). cliNames empty so it
            // doesn't auto-detect local OpenAI CLI creds.
            kind: .openaiAdmin, displayName: "OpenAI Admin", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: true, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: [], webDomain: "platform.openai.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-16: cookie collector — Oasis-Token cookie (NO
            // password login); 5-hour + weekly usage-left-rate windows ⇒
            // `.quota` percent gauges (like Claude/Codex).
            kind: .stepfun, displayName: "StepFun", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["stepfun"], webDomain: "stepfun.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-17: cookie collector — tRPC/JSONL getCustomerData;
            // 4-hour + month usage windows ⇒ `.quota` percent gauges.
            kind: .t3chat, displayName: "T3 Chat", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["t3chat", "t3"], webDomain: "t3.chat"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-18: cookie collector — Xiaomi MiMo token-plan
            // quota (used/limit) + monetary balance; `.quota` when a live plan
            // exists else `.statusOnly`. Requires serviceToken + userId cookies.
            kind: .mimo, displayName: "MiMo", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["mimo"], webDomain: "xiaomimimo.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-19: AWS env-creds + SigV4 → Cost Explorer
            // month-to-date Bedrock spend ⇒ `.statusOnly` exact cost. Env-only
            // creds (CLI/DEVID-oriented); 12h cache (Cost Explorer bills/call).
            kind: .bedrock, displayName: "AWS Bedrock", category: .cloud,
            supportedSources: [.auto, .api],
            supportsQuota: false, supportsExactCost: true, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: [], webDomain: "console.aws.amazon.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-20: cookie+CSRF Bailian console token-plan
            // subscription ⇒ `.quota`. Distinct from Alibaba (coding-plan).
            kind: .alibabaTokenPlan, displayName: "Alibaba Token Plan", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: [], webDomain: "bailian.console.aliyun.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-21: Connect-RPC protobuf GetPlanStatus; daily +
            // weekly quota windows ⇒ `.quota`. 4-value Devin session (manual
            // JSON bundle / env); localStorage auto-read skipped.
            kind: .windsurf, displayName: "Windsurf", category: .ide,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["windsurf"], webDomain: "windsurf.com"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-22: cookie page-scrape; rolling/weekly/monthly
            // usage windows ⇒ `.quota` (+ Zen balance in status). Set
            // OPENCODEGO_WORKSPACE_ID (robust) else _server discovery (fragile).
            kind: .openCodeGo, displayName: "OpenCode Go", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: [], webDomain: "opencode.ai"
        ),
        ProviderDescriptor(
            // v1.23.0 Phase C-23: gRPC-web GetGrokCreditsConfig; usedPercent
            // window ⇒ `.quota` (.statusOnly fallback). Cookie / GROK_TOKEN env;
            // sandbox-safe web billing (NOT the MAS-blocked `grok agent` subprocess).
            kind: .grok, displayName: "Grok", category: .cloud,
            supportedSources: [.auto, .web],
            supportsQuota: true, supportsExactCost: false, supportsCredits: false,
            requiresHelperBackend: false,
            cliNames: ["grok"], webDomain: "grok.com"
        ),
        ProviderDescriptor(
            kind: .volcanoEngine, displayName: "Volcano Engine (豆包)", category: .cloud,
            supportedSources: [.auto, .web, .api],
            supportsQuota: true, requiresHelperBackend: true,
            cliNames: ["volcano", "doubao", "ark", "vecli"],
            webDomain: "console.volcengine.com"
        ),
    ]
}

// MARK: - Cost Summary

/// Per-provider subscription utilization (API equivalent cost / subscription cost)
public struct SubscriptionUtilization: Sendable {
    public let provider: String
    public let plan: String
    public let apiEquivCost: Double      // 30-day API equivalent cost from token scanning
    public let subscriptionCost: Double  // Monthly subscription price
    public let utilizationPercent: Double // apiEquivCost / subscriptionCost * 100 (0 if sub cost is 0)
    public let valueMultiplier: String   // e.g. "23x" if utilization > 100%

    public init(provider: String, plan: String, apiEquivCost: Double, subscriptionCost: Double) {
        self.provider = provider
        self.plan = plan
        self.apiEquivCost = apiEquivCost
        self.subscriptionCost = subscriptionCost
        self.utilizationPercent = subscriptionCost > 0 ? (apiEquivCost / subscriptionCost * 100) : 0
        let multiplier = subscriptionCost > 0 ? apiEquivCost / subscriptionCost : 0
        self.valueMultiplier = multiplier >= 1.0 ? String(format: "%.0fx", multiplier) : ""
    }
}

/// Per-model cost detail for breakdown views
public struct ModelCostDetail: Sendable, Identifiable {
    public var id: String { model }
    public let model: String
    public let cost: Double
    public let inputTokens: Int
    public let outputTokens: Int
    public let cachedTokens: Int

    /// v1.9.4: "I/O tokens" only. Cached is kept as a separate field for
    /// detail views but excluded from the headline number for consistency
    /// with the Providers card and Cost Summary.
    public var totalTokens: Int { inputTokens + outputTokens }
}

public struct CostSummary: Sendable {
    public let todayTotal: Double
    public let todayByProvider: [(provider: String, cost: Double)]
    public let thirtyDayTotal: Double
    public let thirtyDayByProvider: [(provider: String, cost: Double)]
    /// True when costs come from precise JSONL log scanning rather than API estimates
    public let isPrecise: Bool
    /// Monthly subscription costs
    public let subscriptionTotal: Double
    public let subscriptionByProvider: [(provider: String, plan: String, monthlyCost: Double)]
    /// Grand total = subscriptionTotal + thirtyDayTotal
    public let grandTotal: Double
    /// Token totals from CostUsageScanner
    public let todayTokens: Int
    public let thirtyDayTokens: Int
    /// Subscription utilization (API equiv cost vs subscription cost)
    public let utilization: [SubscriptionUtilization]
    /// Per-model cost breakdown for 30-day period
    public let costByModel: [ModelCostDetail]

    public init(
        todayTotal: Double = 0,
        todayByProvider: [(provider: String, cost: Double)] = [],
        thirtyDayTotal: Double = 0,
        thirtyDayByProvider: [(provider: String, cost: Double)] = [],
        isPrecise: Bool = false,
        subscriptionTotal: Double = 0,
        subscriptionByProvider: [(provider: String, plan: String, monthlyCost: Double)] = [],
        grandTotal: Double = 0,
        todayTokens: Int = 0,
        thirtyDayTokens: Int = 0,
        utilization: [SubscriptionUtilization] = [],
        costByModel: [ModelCostDetail] = []
    ) {
        self.todayTotal = todayTotal
        self.todayByProvider = todayByProvider
        self.thirtyDayTotal = thirtyDayTotal
        self.thirtyDayByProvider = thirtyDayByProvider
        self.isPrecise = isPrecise
        self.subscriptionTotal = subscriptionTotal
        self.subscriptionByProvider = subscriptionByProvider
        self.grandTotal = grandTotal
        self.todayTokens = todayTokens
        self.thirtyDayTokens = thirtyDayTokens
        self.utilization = utilization
        self.costByModel = costByModel
    }
}

/// Formats token counts into compact human-readable strings: 81M, 8.6B, 12.3K
public enum TokenFormatter {
    public static func format(_ count: Int) -> String {
        let d = Double(count)
        switch d {
        case 1_000_000_000...:
            return String(format: "%.1fB", d / 1_000_000_000)
        case 1_000_000...:
            let m = d / 1_000_000
            return m >= 10 ? String(format: "%.0fM", m) : String(format: "%.1fM", m)
        case 1_000...:
            let k = d / 1_000
            return k >= 10 ? String(format: "%.0fK", k) : String(format: "%.1fK", k)
        default:
            return "\(count)"
        }
    }
}
