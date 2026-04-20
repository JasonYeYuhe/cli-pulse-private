import Foundation
import SwiftUI
import UserNotifications
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
public final class AppState: ObservableObject {
    // MARK: - Auth State
    @Published public var isAuthenticated = false
    @Published public var isPaired = false
    @Published public var userName: String = ""
    @Published public var userEmail: String = ""

    // MARK: - Data
    @Published public var dashboard: DashboardSummary?
    @Published public var providers: [ProviderUsage] = []
    @Published public var sessions: [SessionRecord] = []
    @Published public var devices: [DeviceRecord] = []
    @Published public var alerts: [AlertRecord] = []

    // MARK: - Subscription
    @Published public var subscriptionManager = SubscriptionManager.shared
    private var subscriptionCancellable: AnyCancellable?

    // MARK: - UI State
    @Published public var selectedTab: Tab = .overview
    @Published public var isLoading = false
    @Published public var lastError: String?
    @Published public var tierLimitWarning: String?
    @Published public var lastRefresh: Date?
    @Published public var serverOnline = false
    @Published public var isLocalMode = false
    /// Which provider the standalone "Provider Settings" window is editing, if any.
    /// Read by the Window scene in `CLIPulseBarApp`; written by Settings → gear buttons.
    @Published public var editingProviderKind: ProviderKind?

    // MARK: - Provider Management
    @Published public var providerConfigs: [ProviderConfig] = ProviderConfig.defaults()
    @Published public var providerDetails: [ProviderDetail] = []
    @Published public var costSummary: CostSummary = CostSummary()
    public var locallySupplementedProviders: Set<String> = []

    // MARK: - Local alert suppression (v1.9.3)
    /// Alert IDs (locally generated, e.g. `quota-<provider>-<tier>-<threshold>`)
    /// that the user explicitly resolved/snoozed and should not re-fire from
    /// `AlertGenerator.evaluateQuotaAlerts` until the suppression expires.
    /// `Date.distantFuture` means "never reappear unless threshold ratchets up
    /// (which produces a new ID)". Persisted in UserDefaults.
    @Published public internal(set) var suppressedAlertIDs: [String: Date] = [:]
    private static let suppressedAlertsKey = "cli_pulse_suppressed_alert_ids_v1"

    // MARK: - Cost Usage Scan (precise token data from local JSONL logs, macOS only)
    @Published public var costUsageScanResult: CostUsageScanResult?
    /// v1.9.4: true when the last cost scan returned empty AND the app is
    /// sandboxed AND no bookmark has been granted for the session-log dirs.
    /// Drives a one-shot banner in Providers tab nudging the user to grant
    /// access via `FolderAccessView`.
    @Published public var needsScannerFolderAccess: Bool = false

    /// v1.9.4: total token count for a provider, sourced from the JSONL scan
    /// result. Convention matches codexbar for parity:
    /// - Codex: `input + output` only (cached tokens tracked but not added to
    ///   "total tokens processed" — matches OpenAI billing semantics)
    ///   See codexbar `CostUsageScanner.swift:584`.
    /// - Claude: `input + cacheRead + cacheCreate + output` (Anthropic bills
    ///   cache reads/creates as distinct line items and codexbar rolls them
    ///   into the headline number) See codexbar `CostUsageScanner+Claude.swift:507`.
    /// - Other providers (non-quota): fall back to `input + output + cached`.
    public func scanTokens(for provider: String, onDate: Date? = nil) -> Int? {
        guard let scan = costUsageScanResult, !scan.entries.isEmpty else { return nil }
        let filtered: [CostUsageScanResult.DailyEntry] = {
            if let date = onDate {
                let cal = Calendar.current
                let comps = cal.dateComponents([.year, .month, .day], from: date)
                let key = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
                return scan.entries.filter { $0.provider == provider && $0.date == key }
            }
            return scan.entries.filter { $0.provider == provider }
        }()
        let total = Self.totalTokens(filtered, provider: provider)
        return total > 0 ? total : nil
    }

    /// v1.9.4 (second revision): raw user + assistant log-event count for a
    /// provider, NOT deduped. Matches Claude Code's UI convention (which also
    /// counts streaming chunks and user messages). Currently only populated
    /// for Claude (Codex doesn't carry a stable per-turn id). This is the
    /// hero metric for Claude cards because Claude Code's own UI leads with
    /// messages — token numbers are dominated by ~98% cache_read noise and
    /// don't reconcile with Anthropic's dashboard.
    public func scanMessages(for provider: String, onDate: Date? = nil) -> Int? {
        guard let scan = costUsageScanResult, !scan.entries.isEmpty else { return nil }
        let filtered: [CostUsageScanResult.DailyEntry] = {
            if let date = onDate {
                let cal = Calendar.current
                let comps = cal.dateComponents([.year, .month, .day], from: date)
                let key = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
                return scan.entries.filter { $0.provider == provider && $0.date == key }
            }
            return scan.entries.filter { $0.provider == provider }
        }()
        let total = filtered.reduce(0) { $0 + $1.messageCount }
        return total > 0 ? total : nil
    }

    public func scanMessagesThisWeek(for provider: String) -> Int? {
        guard let scan = costUsageScanResult, !scan.entries.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date()
        guard let cutoff = cal.date(byAdding: .day, value: -6, to: now) else { return nil }
        let cutoffKey: String = {
            let c = cal.dateComponents([.year, .month, .day], from: cutoff)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }()
        let total = scan.entries
            .filter { $0.provider == provider && $0.date >= cutoffKey }
            .reduce(0) { $0 + $1.messageCount }
        return total > 0 ? total : nil
    }

    /// Tokens for the rolling 7-day window ending now (provider-aware).
    public func scanTokensThisWeek(for provider: String) -> Int? {
        guard let scan = costUsageScanResult, !scan.entries.isEmpty else { return nil }
        let cal = Calendar.current
        let now = Date()
        guard let cutoff = cal.date(byAdding: .day, value: -6, to: now) else { return nil }
        let cutoffKey: String = {
            let c = cal.dateComponents([.year, .month, .day], from: cutoff)
            return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        }()
        let filtered = scan.entries.filter { $0.provider == provider && $0.date >= cutoffKey }
        let total = Self.totalTokens(filtered, provider: provider)
        return total > 0 ? total : nil
    }

    private static func totalTokens(_ entries: [CostUsageScanResult.DailyEntry], provider: String) -> Int {
        // v1.9.4 (second revision, per Codex + Gemini 3.1 Pro review):
        // Uniform formula across providers — `input + output` only.
        // Cache tokens (read + creation) are excluded from the displayed
        // count because:
        //   - cache_read dominates the raw total (~98% for Claude) and is
        //     billed at a 10% discount — including it gives a number that
        //     doesn't reconcile with the user's actual usage intuition.
        //   - OpenAI/Codex dashboards don't include cache in headline.
        //   - Anthropic's Claude Code UI doesn't either (our empirical
        //     measurement found its displayed 46.8M is nowhere near our
        //     9.6B raw-total-including-cache).
        // Cost is computed elsewhere with full per-component pricing, so
        // excluding cache here does NOT affect cost accuracy.
        // The UI labels this "I/O tokens" so users know the scope.
        return entries.reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    // MARK: - Cost Forecast
    @Published public var costForecast: CostForecast?
    @Published public var dailyUsage: [DailyUsage] = []

    // MARK: - Yield Score
    @Published public var yieldScoreDailyRows: [YieldScoreRow] = []
    @Published public var yieldScoreRange: YieldScoreRange = .thirtyDays
    /// Server-persisted opt-in for git activity tracking. Source of truth is
    /// `user_settings.track_git_activity`. Mirrored locally for UI toggle binding.
    @Published public var gitTrackingEnabled: Bool = false

    /// Aggregated per-provider summaries over the currently-selected range.
    /// Re-derived on every access; cheap because rows is small (≤ providers × days).
    public var yieldScoreSummaries: [YieldScoreSummary] {
        YieldScoreAggregator.summarize(rows: yieldScoreDailyRows, range: yieldScoreRange)
    }

    // MARK: - Auth Flow
    @Published public var otpSent = false
    @Published public var otpEmail = ""
    @Published public var pairingInfo: PairingInfo?
    @Published public var pairingError: String?
    @AppStorage("cli_pulse_demo_mode") public var isDemoMode = false

    // MARK: - Linked Identities
    /// OAuth identities (apple/google/github/email) linked to the current user.
    @Published public var linkedIdentities: [UserIdentity] = []
    @Published public var isLinkingIdentity = false
    @Published public var linkIdentityError: String?

    // MARK: - Webhook Integration
    @AppStorage("cli_pulse_webhook_enabled") public var webhookEnabled = false
    @AppStorage("cli_pulse_webhook_url") public var webhookURL = ""
    @Published public var webhookEventFilter: WebhookEventFilter = WebhookEventFilter()

    // MARK: - Settings - General
    nonisolated static let tokenKeychainKey = "cli_pulse_token"

    public var storedToken: String {
        get { KeychainHelper.load(key: Self.tokenKeychainKey) ?? "" }
        set { Self.persistAuthTokens(access: newValue, refresh: storedRefreshToken) }
    }

    @AppStorage("cli_pulse_refresh_interval") public var refreshInterval: Int = 120
    @AppStorage("cli_pulse_show_cost") public var showCost = true
    @AppStorage("cli_pulse_notifications") public var notificationsEnabled = true
    @AppStorage("cli_pulse_compact_mode") public var compactMode = false
    @AppStorage("cli_pulse_check_provider_status") public var checkProviderStatus = true
    @AppStorage("cli_pulse_session_quota_notifications") public var sessionQuotaNotifications = true
    @AppStorage("cli_pulse_hide_personal_info") public var hidePersonalInfo = false
    @AppStorage("cli_pulse_appearance") public var appearanceModeRaw = 0

    public var appearanceMode: ColorScheme? {
        switch appearanceModeRaw {
        case 1: return .light
        case 2: return .dark
        default: return nil
        }
    }

    // MARK: - Settings - Display
    @AppStorage("cli_pulse_menubar_display_mode") public var menuBarDisplayModeRaw = MenuBarDisplayMode.icon.rawValue
    @AppStorage("cli_pulse_menubar_content_mode") public var menuBarContentModeRaw = MenuBarContentMode.usageAsUsed.rawValue
    @AppStorage("cli_pulse_merge_icons") public var mergeMenuBarIcons = true

    public var menuBarDisplayMode: MenuBarDisplayMode {
        get { MenuBarDisplayMode(rawValue: menuBarDisplayModeRaw) ?? .icon }
        set { menuBarDisplayModeRaw = newValue.rawValue }
    }

    public var menuBarContentMode: MenuBarContentMode {
        get { MenuBarContentMode(rawValue: menuBarContentModeRaw) ?? .usageAsUsed }
        set { menuBarContentModeRaw = newValue.rawValue }
    }

    public enum Tab: String, CaseIterable {
        case overview = "Overview"
        case providers = "Providers"
        case sessions = "Sessions"
        case alerts = "Alerts"
        case settings = "Settings"

        public var icon: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.33percent"
            case .providers: return "cpu"
            case .sessions: return "terminal"
            case .alerts: return "bell.badge"
            case .settings: return "gear"
            }
        }

        public var label: String {
            switch self {
            case .overview: return L10n.tab.overview
            case .providers: return L10n.tab.providers
            case .sessions: return L10n.tab.sessions
            case .alerts: return L10n.tab.alerts
            case .settings: return L10n.tab.settings
            }
        }
    }

    public let api: APIClient
    let authManager: AuthManager
    let dataRefreshManager: DataRefreshManager

    private static let secretsMigratedKey = "cli_pulse_provider_secrets_migrated"

    public init() {
        self.api = APIClient()
        self.authManager = AuthManager(api: api, persistTokens: Self.persistAuthTokens)
        self.dataRefreshManager = DataRefreshManager(api: api)
        subscriptionManager.apiClient = api
        loadProviderConfigs()
        loadSuppressedAlertIDs()

        subscriptionCancellable = subscriptionManager.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }

        if let legacyToken = UserDefaults.standard.string(forKey: "cli_pulse_token"), !legacyToken.isEmpty {
            Self.persistAuthTokens(access: legacyToken, refresh: KeychainHelper.load(key: AuthManager.refreshTokenKeychainKey))
        }
        UserDefaults.standard.removeObject(forKey: "cli_pulse_token")

        Task {
            await api.setTokenRefreshHandler { newAccess, newRefresh in
                Self.persistAuthTokens(access: newAccess, refresh: newRefresh)
            }
            await restoreSession()
        }
    }

    // MARK: - Menu Bar

    public var menuBarLabel: String {
        guard isAuthenticated, isPaired else { return "" }
        let unresolvedCount = alerts.filter { !$0.is_resolved }.count
        if unresolvedCount > 0 {
            return "\(unresolvedCount)"
        }
        switch menuBarDisplayMode {
        case .percent:
            if let top = mostUsedProvider, top.usagePercent > 0 {
                return "\(Int((1.0 - top.usagePercent) * 100))%"
            }
            return ""
        case .mostUsed:
            return mostUsedProvider?.provider ?? ""
        case .pace:
            if let top = mostUsedProvider, top.usagePercent > 0 {
                return String(format: "%.0f%%", top.usagePercent * 100)
            }
            return ""
        case .icon:
            return ""
        }
    }

    public var menuBarIcon: String {
        guard isAuthenticated, isPaired else { return "waveform.path.ecg" }
        let unresolvedCount = alerts.filter { !$0.is_resolved }.count
        if unresolvedCount > 0 { return "exclamationmark.triangle.fill" }
        if !serverOnline { return "wifi.slash" }
        if menuBarDisplayMode == .mostUsed, let top = mostUsedProvider, let kind = top.providerKind {
            return kind.iconName
        }
        return "waveform.path.ecg"
    }

    public var mostUsedProvider: ProviderUsage? {
        providers
            .filter { enabledProviderNames.contains($0.provider) }
            .max(by: { $0.usagePercent < $1.usagePercent })
    }

    public var enabledProviderNames: Set<String> {
        Set(providerConfigs.filter(\.isEnabled).map(\.kind.rawValue))
    }

    // MARK: - Provider Config Management

    public func toggleProvider(_ kind: ProviderKind) {
        guard let idx = providerConfigs.firstIndex(where: { $0.kind == kind }) else { return }
        setProviderEnabled(kind, isEnabled: !providerConfigs[idx].isEnabled)
    }

    /// Explicitly set a provider's enabled flag. v1.9.3: the Toggle binding
    /// should prefer this over `toggleProvider` so the user's intended value
    /// (not a blind flip) is applied even under rapid-tap / SwiftUI reconciliation.
    public func setProviderEnabled(_ kind: ProviderKind, isEnabled: Bool) {
        guard let idx = providerConfigs.firstIndex(where: { $0.kind == kind }) else { return }
        if providerConfigs[idx].isEnabled == isEnabled { return }
        if isEnabled {
            let maxProviders = subscriptionManager.maxProviders
            if maxProviders >= 0 {
                let currentEnabled = providerConfigs.filter(\.isEnabled).count
                if currentEnabled >= maxProviders {
                    tierLimitWarning = "Your \(subscriptionManager.currentTier.rawValue) plan allows up to \(maxProviders) providers. Upgrade to enable more."
                    return
                }
            }
        }
        providerConfigs[idx].isEnabled = isEnabled
        saveProviderConfigs()
        // v1.9.3: rebuild provider details synchronously so the SwiftUI
        // Toggle bound to `detail.config.isEnabled` flips in the same frame
        // instead of waiting for the next data refresh cycle.
        buildProviderDetails()
    }

    public func moveProvider(from source: IndexSet, to destination: Int) {
        providerConfigs.move(fromOffsets: source, toOffset: destination)
        for index in providerConfigs.indices {
            providerConfigs[index].sortOrder = index
        }
        saveProviderConfigs()
        // Rebuild so re-ordered providers reflect immediately in the UI.
        buildProviderDetails()
    }

    public func saveProviderConfigs() {
        if let data = try? JSONEncoder().encode(providerConfigs) {
            UserDefaults.standard.set(data, forKey: "cli_pulse_provider_configs")
            UserDefaults(suiteName: HelperIPC.suiteName)?.set(data, forKey: HelperIPC.providerConfigsKey)
        }
        for config in providerConfigs {
            config.saveSecrets()
        }
    }

    public func buildProviderDetails() {
        providerDetails = providerConfigs.sorted(by: { $0.sortOrder < $1.sortOrder }).compactMap { config in
            guard let usage = providers.first(where: { $0.provider == config.kind.rawValue }) else { return nil }

            // Tier rendering rule (v1.9.3):
            // 1. Prefer per-tier data when the collector populated it (Claude
            //    weekly/session/sonnet, Codex session/weekly, etc.).
            // 2. Synthesise a single "Default" bar only for non-Claude
            //    providers that ship an overall quota but no per-tier data
            //    (e.g. Cursor monthly bucket). For Claude, an empty tier list
            //    means "data unavailable" — surface that, don't fake a bar.
            let tiers: [UsageTier]
            if !usage.tiers.isEmpty {
                tiers = usage.tiers.compactMap { tier in
                    guard tier.quota > 0 else { return nil }
                    return UsageTier(
                        name: tier.name,
                        usage: tier.quota - tier.remaining,
                        quota: tier.quota,
                        remaining: tier.remaining,
                        resetTime: tier.reset_time
                    )
                }
            } else if let quota = usage.quota,
                      quota > 0,
                      let remaining = usage.remaining,
                      usage.provider != ProviderKind.claude.rawValue {
                tiers = [
                    UsageTier(
                        name: "Default",
                        usage: usage.today_usage,
                        quota: quota,
                        remaining: remaining,
                        resetTime: usage.reset_time
                    )
                ]
            } else {
                tiers = []
            }

            let effectiveSource: SourceType
            if config.sourceMode != .auto {
                effectiveSource = config.sourceMode
            } else if isLocalMode {
                effectiveSource = .local
            } else if locallySupplementedProviders.contains(usage.provider) {
                effectiveSource = .merged
            } else {
                effectiveSource = .api
            }

            return ProviderDetail(
                provider: usage,
                config: config,
                tiers: tiers,
                operationalStatus: .operational,
                accountEmail: config.accountLabel,
                planType: usage.plan_type,
                sourceType: effectiveSource
            )
        }
    }

    private func loadProviderConfigs() {
        guard let data = UserDefaults.standard.data(forKey: "cli_pulse_provider_configs") else { return }

        if !UserDefaults.standard.bool(forKey: Self.secretsMigratedKey) {
            migrateLegacySecrets(from: data)
            UserDefaults.standard.set(true, forKey: Self.secretsMigratedKey)
        }

        if let configs = try? JSONDecoder().decode([ProviderConfig].self, from: data) {
            providerConfigs = configs
            let existingKinds = Set(configs.map(\.kind))
            for kind in ProviderKind.allCases where !existingKinds.contains(kind) {
                providerConfigs.append(ProviderConfig(kind: kind, isEnabled: true, sortOrder: providerConfigs.count))
            }
        }

        for index in providerConfigs.indices {
            providerConfigs[index].loadSecrets()
        }
    }

    private func migrateLegacySecrets(from data: Data) {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for entry in array {
            guard let kindRaw = entry["kind"] as? String, let kind = ProviderKind(rawValue: kindRaw) else { continue }
            if let apiKey = entry["apiKey"] as? String, !apiKey.isEmpty {
                KeychainHelper.save(key: "cli_pulse_provider_\(kind.rawValue)_apiKey", value: apiKey)
            }
            if let cookie = entry["manualCookieHeader"] as? String, !cookie.isEmpty {
                KeychainHelper.save(key: "cli_pulse_provider_\(kind.rawValue)_cookie", value: cookie)
            }
        }

        if let configs = try? JSONDecoder().decode([ProviderConfig].self, from: data),
           let cleanData = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(cleanData, forKey: "cli_pulse_provider_configs")
        }
    }
}
