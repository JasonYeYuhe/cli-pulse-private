import Foundation

// MARK: - Shared Formatter

/// Package-level shared ISO8601 formatter (no fractional seconds).
/// Used for outputting timestamps that other clients can round-trip
/// without needing to support fractional-second parsing.
nonisolated(unsafe) public let sharedISO8601Formatter = ISO8601DateFormatter()

/// Companion formatter that parses ISO8601 strings *with* fractional
/// seconds, which `sharedISO8601Formatter` rejects.
nonisolated(unsafe) private let sharedISO8601FormatterFractional: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let sharedISO8601ParseLock = NSLock()

/// Robust ISO-8601 parser that tolerates BOTH:
///   `2026-05-05T12:34:56Z`              (no fractional seconds)
///   `2026-05-05T12:34:56+00:00`         (timezone offset)
///   `2026-05-05T12:34:56.789012+00:00`  (Python `datetime.isoformat()`)
///   `2026-05-05T12:34:56.789Z`          (with fractional + Z)
///
/// Why: helper/system_collector.py writes
/// `datetime.now(timezone.utc).isoformat()` which always includes
/// microsecond fractionals (`+00:00` form). The default
/// `ISO8601DateFormatter()` (no `withFractionalSeconds` option)
/// returns nil for those inputs. That dropout silently broke every
/// helper-uploaded `SessionRecord` — `lastActiveDate` returned nil,
/// `SessionFreshnessFilter.filterCurrent` then evicted the row via
/// `guard let lastActive = … else { return false }`. Net effect:
/// `cloudRaw=50 cloudFresh=0` and only JSONL-synthesized rows
/// survived to the UI.
///
/// `ISO8601DateFormatter` is thread-safe per Apple docs since macOS
/// 10.12, but we keep a small `NSLock` because we mutate two
/// formatters' state via `.date(from:)` indirectly (Apple's
/// implementation is "thread-safe for parsing" but the documentation
/// is light on details for fallback chains). The lock is uncontended
/// in practice.
public func sharedISO8601Parse(_ text: String) -> Date? {
    sharedISO8601ParseLock.lock()
    defer { sharedISO8601ParseLock.unlock() }
    if let d = sharedISO8601Formatter.date(from: text) { return d }
    return sharedISO8601FormatterFractional.date(from: text)
}

// MARK: - Enums

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case gemini = "Gemini"
    case claude = "Claude"
    case cursor = "Cursor"
    case openCode = "OpenCode"
    case droid = "Droid"
    case antigravity = "Antigravity"
    case copilot = "Copilot"
    case zai = "z.ai"
    case minimax = "MiniMax"
    case augment = "Augment"
    case jetbrainsAI = "JetBrains AI"
    case kimiK2 = "Kimi K2"
    case amp = "Amp"
    case synthetic = "Synthetic"
    case warp = "Warp"
    case kilo = "Kilo"
    case ollama = "Ollama"
    case openRouter = "OpenRouter"
    case alibaba = "Alibaba"
    case kimi = "Kimi"
    case kiro = "Kiro"
    case vertexAI = "Vertex AI"
    case perplexity = "Perplexity"
    case volcanoEngine = "Volcano Engine"
    case glm = "GLM"
    // v1.23.0 Phase C-1 (CodexBar parity): api-key collector.
    case crof = "Crof"
    // v1.23.0 Phase C-2: api-key credits-only collector.
    case deepseek = "DeepSeek"
    // v1.23.0 Phase C-3: api-key .quota collector (xi-api-key header).
    case elevenLabs = "ElevenLabs"
    // v1.23.0 Phase C-4: api-key .credits collector (USD+DIEM dual-currency).
    case venice = "Venice"
    // v1.23.0 Phase C-5: api-key .statusOnly collector (deployment ping-validation).
    case azureOpenAI = "Azure OpenAI"
    // v1.23.0 Phase C-6: api-key .quota collector (credits cap+reset; best-effort weekly/tier).
    case codebuff = "Codebuff"
    // v1.23.0 Phase C-7: api-key .statusOnly collector (Token header; projects→usage aggregate).
    case deepgram = "Deepgram"
    // v1.23.0 Phase C-8: cookie collector (session_id→Bearer; .quota — monthly + refresh pools).
    case manus = "Manus"
    // v1.23.0 Phase C-9: cookie collector (.quota compute points; required + bounded billing).
    case abacus = "Abacus AI"
    // v1.23.0 Phase C-10: cookie collector (.statusOnly month-to-date spend; token×price aggregate).
    case mistral = "Mistral"
    // v1.23.0 Phase C-11: cookie collector (.credits USD; 4 pools + plan-catalog cap).
    case commandCode = "Command Code"
    // v1.23.0 Phase C-12: api-key collector (.statusOnly Prometheus throughput rates).
    case groq = "Groq"

    public var id: String { rawValue }

    /// Default estimated cost per 1K tokens for local process-based usage estimation.
    /// Override via ProviderConfig.costRatePerKToken for user-customizable rates.
    public var defaultCostRate: Double {
        switch self {
        case .claude: return 0.003
        case .codex: return 0.002
        case .gemini: return 0.001
        case .cursor: return 0.002
        case .copilot: return 0.001
        case .ollama: return 0
        case .openRouter: return 0.002
        case .kilo: return 0.001
        case .kimi, .kimiK2: return 0.001
        case .kiro: return 0.002
        case .vertexAI: return 0.003
        case .perplexity: return 0.002
        case .volcanoEngine: return 0.001
        case .glm: return 0.001
        default: return 0.001
        }
    }

    public var iconName: String {
        switch self {
        case .codex: return "terminal"
        case .gemini: return "sparkles"
        case .claude: return "brain.head.profile"
        case .cursor: return "cursorarrow.rays"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        case .droid: return "cpu"
        case .antigravity: return "arrow.up.circle"
        case .copilot: return "airplane"
        case .zai: return "z.circle"
        case .minimax: return "chart.bar"
        case .augment: return "plus.magnifyingglass"
        case .jetbrainsAI: return "hammer"
        case .kimiK2: return "k.circle"
        case .amp: return "bolt"
        case .synthetic: return "wand.and.stars"
        case .warp: return "arrow.right.circle"
        case .kilo: return "scalemass"
        case .ollama: return "desktopcomputer"
        case .openRouter: return "arrow.triangle.branch"
        case .alibaba: return "cloud"
        case .kimi: return "k.circle.fill"
        case .kiro: return "arrow.triangle.turn.up.right.diamond"
        case .vertexAI: return "v.circle"
        case .perplexity: return "magnifyingglass.circle"
        case .volcanoEngine: return "flame"
        case .glm: return "text.bubble"
        case .crof: return "c.circle"
        case .deepseek: return "d.circle"
        case .elevenLabs: return "waveform"
        case .venice: return "v.circle"
        case .azureOpenAI: return "a.circle"
        case .codebuff: return "b.circle"
        case .deepgram: return "waveform.path"
        case .manus: return "m.circle"
        case .abacus: return "a.square"
        case .mistral: return "wind"
        case .commandCode: return "c.square"
        case .groq: return "bolt.horizontal.circle"
        }
    }
}

public enum SessionStatus: String, Codable, Sendable {
    case running = "Running"
    case idle = "Idle"
    case failed = "Failed"
    case syncing = "Syncing"
}

public enum DeviceStatus: String, Codable, Sendable {
    case online = "Online"
    case degraded = "Degraded"
    case offline = "Offline"
}

public enum AlertType: String, Codable, Sendable {
    case quotaLow = "Quota Low"
    case usageSpike = "Usage Spike"
    case helperOffline = "Helper Offline"
    case syncFailed = "Sync Failed"
    case authExpired = "Auth Expired"
    case sessionFailed = "Session Failed"
    case sessionTooLong = "Session Too Long"
    case projectBudgetExceeded = "Project Budget Exceeded"
    case costSpike = "Cost Spike"
    case errorRateSpike = "Error Rate Spike"
    case quotaCritical = "Quota Critical"
}

public enum CollectionConfidence: String, Codable, Sendable {
    case high
    case medium
    case low
}

public enum ProviderCategory: String, Codable, Sendable {
    case cloud
    case local
    case aggregator
    case ide
}

public enum AlertSeverity: String, Codable, Sendable {
    case critical = "Critical"
    case warning = "Warning"
    case info = "Info"
}

public enum CostStatus: String, Codable, Sendable {
    case exact = "Exact"
    case estimated = "Estimated"
    case unavailable = "Unavailable"
}

public enum ProviderStatus: String, Codable, Sendable {
    case operational = "Operational"
    case degraded = "Degraded"
    case down = "Down"
}

public enum SourceType: String, Codable, CaseIterable, Sendable {
    case auto
    case web
    case cli
    case oauth
    case api
    case local
    case merged  // cloud + local collector supplemented
}

// MARK: - Auth

public struct AuthRequest: Codable, Sendable {
    public let email: String
    public let name: String

    public init(email: String, name: String) {
        self.email = email
        self.name = name
    }
}

public struct AuthResponse: Codable, Sendable {
    public let access_token: String
    public let refresh_token: String?
    public let user: UserDTO
    public let paired: Bool

    public init(access_token: String, refresh_token: String? = nil, user: UserDTO, paired: Bool) {
        self.access_token = access_token
        self.refresh_token = refresh_token
        self.user = user
        self.paired = paired
    }
}

public struct UserDTO: Codable, Sendable {
    public let id: String
    public let name: String
    public let email: String

    public init(id: String, name: String, email: String) {
        self.id = id
        self.name = name
        self.email = email
    }
}

public struct UserIdentity: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let provider: String
    public let email: String?
    public let createdAt: String?

    public init(id: String, provider: String, email: String?, createdAt: String?) {
        self.id = id
        self.provider = provider
        self.email = email
        self.createdAt = createdAt
    }
}

// MARK: - Dashboard

public struct DashboardSummary: Codable, Sendable {
    public let total_usage_today: Int
    public let total_estimated_cost_today: Double
    public let cost_status: String
    public let total_requests_today: Int
    public let active_sessions: Int
    public let online_devices: Int
    public let unresolved_alerts: Int
    public let provider_breakdown: [ProviderBreakdown]
    public let top_projects: [TopProject]
    public let trend: [UsagePoint]
    public let recent_activity: [ActivityItem]
    public let risk_signals: [String]
    public let alert_summary: AlertSummaryDTO

    public init(
        total_usage_today: Int, total_estimated_cost_today: Double,
        cost_status: String, total_requests_today: Int,
        active_sessions: Int, online_devices: Int, unresolved_alerts: Int,
        provider_breakdown: [ProviderBreakdown], top_projects: [TopProject],
        trend: [UsagePoint], recent_activity: [ActivityItem],
        risk_signals: [String], alert_summary: AlertSummaryDTO
    ) {
        self.total_usage_today = total_usage_today
        self.total_estimated_cost_today = total_estimated_cost_today
        self.cost_status = cost_status
        self.total_requests_today = total_requests_today
        self.active_sessions = active_sessions
        self.online_devices = online_devices
        self.unresolved_alerts = unresolved_alerts
        self.provider_breakdown = provider_breakdown
        self.top_projects = top_projects
        self.trend = trend
        self.recent_activity = recent_activity
        self.risk_signals = risk_signals
        self.alert_summary = alert_summary
    }
}

public struct ProviderBreakdown: Codable, Identifiable, Sendable {
    public let provider: String
    public let usage: Int
    public let estimated_cost: Double
    public let cost_status: String
    public let remaining: Int?

    public var id: String { provider }

    public var providerKind: ProviderKind? {
        ProviderKind(rawValue: provider)
    }

    public init(provider: String, usage: Int, estimated_cost: Double, cost_status: String, remaining: Int?) {
        self.provider = provider
        self.usage = usage
        self.estimated_cost = estimated_cost
        self.cost_status = cost_status
        self.remaining = remaining
    }
}

public struct TopProject: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let usage: Int
    public let estimated_cost: Double
    public let cost_status: String

    public init(id: String, name: String, usage: Int, estimated_cost: Double, cost_status: String) {
        self.id = id
        self.name = name
        self.usage = usage
        self.estimated_cost = estimated_cost
        self.cost_status = cost_status
    }
}

public struct UsagePoint: Codable, Identifiable, Sendable {
    public let timestamp: String
    public let value: Int

    public var id: String { timestamp }

    public init(timestamp: String, value: Int) {
        self.timestamp = timestamp
        self.value = value
    }
}

public struct ActivityItem: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String
    public let timestamp: String

    public init(id: String, title: String, subtitle: String, timestamp: String) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.timestamp = timestamp
    }
}

public struct AlertSummaryDTO: Codable, Sendable {
    public let critical: Int
    public let warning: Int
    public let info: Int

    public init(critical: Int, warning: Int, info: Int) {
        self.critical = critical
        self.warning = warning
        self.info = info
    }
}

// MARK: - Provider

public struct ProviderMetadata: Codable, Sendable {
    public let display_name: String
    public let category: String
    public let supports_exact_cost: Bool
    public let supports_quota: Bool
    public let default_quota: Int?

    public var providerCategory: ProviderCategory? {
        ProviderCategory(rawValue: category)
    }

    public init(display_name: String, category: String, supports_exact_cost: Bool = false, supports_quota: Bool = true, default_quota: Int? = nil) {
        self.display_name = display_name
        self.category = category
        self.supports_exact_cost = supports_exact_cost
        self.supports_quota = supports_quota
        self.default_quota = default_quota
    }
}

/// Usage data for a single provider, used by both cloud sync and local collectors.
///
/// **Semantic convention for `today_usage` / `week_usage`:**
/// These fields store **percentages** (0–100) representing how much of the
/// provider's quota window has been consumed. Collectors that produce
/// absolute token/request counts should convert to percentages before
/// constructing this struct. This ensures all providers are comparable in UI.
public struct ProviderUsage: Codable, Identifiable, Sendable {
    public let provider: String
    public let today_usage: Int
    public let week_usage: Int
    public let estimated_cost_today: Double
    public let estimated_cost_week: Double
    public let estimated_cost_30_day: Double
    public let cost_status_today: String
    public let cost_status_week: String
    public let quota: Int?
    public let remaining: Int?
    public let plan_type: String?
    public let reset_time: String?
    public let tiers: [TierDTO]
    public let status_text: String
    public let trend: [UsagePoint]
    public let recent_sessions: [String]
    public let recent_errors: [String]
    public let metadata: ProviderMetadata?

    public var id: String { provider }

    public var providerKind: ProviderKind? {
        ProviderKind(rawValue: provider)
    }

    public var usagePercent: Double {
        guard let quota = quota, quota > 0 else { return 0 }
        let used = quota - (remaining ?? 0)
        return min(1.0, Double(used) / Double(quota))
    }

    public init(
        provider: String, today_usage: Int, week_usage: Int,
        estimated_cost_today: Double, estimated_cost_week: Double,
        estimated_cost_30_day: Double = 0,
        cost_status_today: String, cost_status_week: String,
        quota: Int?, remaining: Int?,
        plan_type: String? = nil, reset_time: String? = nil,
        tiers: [TierDTO] = [],
        status_text: String,
        trend: [UsagePoint], recent_sessions: [String], recent_errors: [String],
        metadata: ProviderMetadata? = nil
    ) {
        self.provider = provider
        self.today_usage = today_usage
        self.week_usage = week_usage
        self.estimated_cost_today = estimated_cost_today
        self.estimated_cost_week = estimated_cost_week
        self.estimated_cost_30_day = estimated_cost_30_day
        self.cost_status_today = cost_status_today
        self.cost_status_week = cost_status_week
        self.quota = quota
        self.remaining = remaining
        self.plan_type = plan_type
        self.reset_time = reset_time
        self.tiers = tiers
        self.status_text = status_text
        self.trend = trend
        self.recent_sessions = recent_sessions
        self.recent_errors = recent_errors
        self.metadata = metadata
    }
}

public enum TierRole: String, Codable, Sendable {
    case primary       // Main window (e.g. 5h)
    case secondary     // Secondary window (e.g. Weekly)
    case modelSpecific // Per-model window (e.g. Opus, Sonnet)
    case credits       // Extra usage / credits
}

public struct TierDTO: Codable, Sendable {
    public let name: String
    public let quota: Int
    public let remaining: Int
    public let reset_time: String?
    public let windowMinutes: Int?
    public let role: TierRole?

    public init(name: String, quota: Int, remaining: Int, reset_time: String? = nil,
                windowMinutes: Int? = nil, role: TierRole? = nil) {
        self.name = name
        self.quota = quota
        self.remaining = remaining
        self.reset_time = reset_time
        self.windowMinutes = windowMinutes
        self.role = role
    }
}

// MARK: - Session

public struct SessionRecord: Codable, Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let provider: String
    public let project: String
    public let project_hash: String?  // HMAC-SHA256 of absolute path; nil if path unknown
    public let device_name: String
    public let started_at: String
    public let last_active_at: String
    public let status: String
    public let total_usage: Int
    public let estimated_cost: Double
    public let cost_status: String
    public let requests: Int
    public let error_count: Int
    public let collection_confidence: String?

    public var providerKind: ProviderKind? {
        ProviderKind(rawValue: provider)
    }

    public var sessionStatus: SessionStatus? {
        SessionStatus(rawValue: status)
    }

    public var confidence: CollectionConfidence? {
        guard let collection_confidence else { return nil }
        return CollectionConfidence(rawValue: collection_confidence)
    }

    public var startedDate: Date? {
        sharedISO8601Parse(started_at)
    }

    public var lastActiveDate: Date? {
        sharedISO8601Parse(last_active_at)
    }

    /// Whether the row's `requests` metric reflects real assistant-turn
    /// counting. `CostUsageScanner.buildCodexCandidates` currently
    /// hard-codes `messageCount: 0` for Codex JSONL candidates, which
    /// `synthesizeSessions` then floors to `max(1, 0) = 1`. Showing
    /// "1 requests" next to "26.3M I/O tokens" is misleading — the row
    /// has clearly seen many turns. The UI uses this flag to suppress
    /// the requests metric for those rows specifically; Claude JSONL
    /// rows count correctly, helper-emitted process rows compute a
    /// duration-based estimate, and remote/cloud rows trust the
    /// uploader. Proper Codex turn counting is a separate follow-up
    /// that requires extending the parser's CodexParseResult and the
    /// per-file cache schema.
    public var hasMeaningfulRequestCount: Bool {
        if hasProcessHeuristicMetrics { return false }
        return !(id.hasPrefix("jsonl-codex-") && requests <= 1)
    }

    /// Whether the row's `total_usage` / `estimated_cost` / `requests`
    /// fields are derived from heuristics rather than parsed usage.
    /// True for helper-emitted `proc-{pid}` rows, where:
    ///   total_usage = max(500, elapsed_seconds * (1.5 + cpu))
    ///   requests    = max(1, elapsed_seconds // 45)
    /// Both grow monotonically with how long the process has been
    /// alive, with no relationship to actual API/token usage. Showing
    /// "86038 requests" next to a Claude Code session that's been
    /// running 8+ hours is technically what the formula produces, but
    /// it's noise to the user.
    ///
    /// The UI uses this flag to suppress the `usage / cost / requests`
    /// trio for proc-* rows; the green "running" status pill plus the
    /// row's provider/project label is enough to convey "this is alive."
    public var hasProcessHeuristicMetrics: Bool {
        id.hasPrefix("proc-")
    }

    /// Display name for the Sessions panel row. Helper-emitted proc-*
    /// rows have `name = command line truncated to 48 chars`, which
    /// surfaces unfriendly strings like `/Users/jason/Library/Application Support/C...`
    /// or `./Codex Computer Use.app/Contents/Shar...`. Replace with
    /// "{provider} · {project}" when we have provider info, falling
    /// back to "{provider} process" if project is empty/generic.
    /// JSONL-synthesized rows already carry friendly names like
    /// "Claude session" — leave those alone.
    public var displayName: String {
        guard hasProcessHeuristicMetrics else { return name }
        let cleanProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanProject.isEmpty {
            return "\(provider) · \(cleanProject)"
        }
        return "\(provider) process"
    }

    public init(
        id: String, name: String, provider: String, project: String,
        device_name: String, started_at: String, last_active_at: String,
        status: String, total_usage: Int, estimated_cost: Double,
        cost_status: String, requests: Int, error_count: Int,
        collection_confidence: String? = nil,
        project_hash: String? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.project = project
        self.project_hash = project_hash
        self.device_name = device_name
        self.started_at = started_at
        self.last_active_at = last_active_at
        self.status = status
        self.total_usage = total_usage
        self.estimated_cost = estimated_cost
        self.cost_status = cost_status
        self.requests = requests
        self.error_count = error_count
        self.collection_confidence = collection_confidence
    }
}

// MARK: - Device

public struct DeviceRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let type: String
    public let system: String
    public let status: String
    public let last_sync_at: String?
    public let helper_version: String
    public let current_session_count: Int
    public let cpu_usage: Int?
    public let memory_usage: Int?

    public var deviceStatus: DeviceStatus? {
        DeviceStatus(rawValue: status)
    }

    public init(
        id: String, name: String, type: String, system: String,
        status: String, last_sync_at: String?, helper_version: String,
        current_session_count: Int, cpu_usage: Int?, memory_usage: Int?
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.system = system
        self.status = status
        self.last_sync_at = last_sync_at
        self.helper_version = helper_version
        self.current_session_count = current_session_count
        self.cpu_usage = cpu_usage
        self.memory_usage = memory_usage
    }
}

public extension DeviceRecord {
    /// Remote managed-session support is version-gated because paired
    /// Macs before helper 1.15 only know how to spawn Claude. Sending
    /// Codex/Gemini start commands to those helpers creates pending
    /// cloud rows that can never become running.
    func supportsManagedSessionProvider(_ provider: String) -> Bool {
        let normalized = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "claude":
            return !helper_version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "codex", "gemini":
            return helperVersionAtLeast(major: 1, minor: 15, patch: 0)
        default:
            return false
        }
    }

    var supportsMultiCLIManagedSessions: Bool {
        helperVersionAtLeast(major: 1, minor: 15, patch: 0)
    }

    private func helperVersionAtLeast(major requiredMajor: Int, minor requiredMinor: Int, patch requiredPatch: Int) -> Bool {
        guard let version = Self.firstSemanticVersion(in: helper_version) else { return false }
        if version.major != requiredMajor { return version.major > requiredMajor }
        if version.minor != requiredMinor { return version.minor > requiredMinor }
        return version.patch >= requiredPatch
    }

    private static func firstSemanticVersion(in raw: String) -> (major: Int, minor: Int, patch: Int)? {
        let pattern = #"(\d+)\.(\d+)(?:\.(\d+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = regex.firstMatch(in: raw, range: range),
              let majorRange = Range(match.range(at: 1), in: raw),
              let minorRange = Range(match.range(at: 2), in: raw),
              let major = Int(raw[majorRange]),
              let minor = Int(raw[minorRange])
        else { return nil }

        let patch: Int
        if let patchRange = Range(match.range(at: 3), in: raw),
           let parsedPatch = Int(raw[patchRange]) {
            patch = parsedPatch
        } else {
            patch = 0
        }
        return (major, minor, patch)
    }
}

// MARK: - Alert

public struct AlertRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let type: String
    public let severity: String
    public let title: String
    public let message: String
    public let created_at: String
    public let is_read: Bool
    public let is_resolved: Bool
    public let acknowledged_at: String?
    public let snoozed_until: String?
    public let related_project_id: String?
    public let related_project_name: String?
    public let related_session_id: String?
    public let related_session_name: String?
    public let related_provider: String?
    public let related_device_name: String?
    public let source_kind: String?
    public let source_id: String?
    public let grouping_key: String?
    public let suppression_key: String?

    public var alertSeverity: AlertSeverity? {
        AlertSeverity(rawValue: severity)
    }

    public var alertType: AlertType? {
        AlertType(rawValue: type)
    }

    public var createdDate: Date? {
        sharedISO8601Parse(created_at)
    }

    public init(
        id: String, type: String, severity: String, title: String,
        message: String, created_at: String, is_read: Bool, is_resolved: Bool,
        acknowledged_at: String?, snoozed_until: String?,
        related_project_id: String?, related_project_name: String?,
        related_session_id: String?, related_session_name: String?,
        related_provider: String?, related_device_name: String?,
        source_kind: String? = nil, source_id: String? = nil,
        grouping_key: String? = nil, suppression_key: String? = nil
    ) {
        self.id = id
        self.type = type
        self.severity = severity
        self.title = title
        self.message = message
        self.created_at = created_at
        self.is_read = is_read
        self.is_resolved = is_resolved
        self.acknowledged_at = acknowledged_at
        self.snoozed_until = snoozed_until
        self.related_project_id = related_project_id
        self.related_project_name = related_project_name
        self.related_session_id = related_session_id
        self.related_session_name = related_session_name
        self.related_provider = related_provider
        self.related_device_name = related_device_name
        self.source_kind = source_kind
        self.source_id = source_id
        self.grouping_key = grouping_key
        self.suppression_key = suppression_key
    }
}

// MARK: - Pairing

public struct PairingInfo: Codable, Sendable {
    public let code: String
    public let install_command: String

    public init(code: String, install_command: String) {
        self.code = code
        self.install_command = install_command
    }
}

// MARK: - Helper

public struct SuccessResponse: Codable, Sendable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
    }
}

// MARK: - Settings

public struct SettingsSnapshot: Codable, Sendable {
    public let notifications_enabled: Bool
    public let push_policy: String
    public let digest_enabled: Bool
    public let digest_interval_hours: Int
    public let usage_spike_threshold: Int
    public let project_budget_threshold_usd: Double
    public let session_too_long_threshold_minutes: Int
    public let offline_grace_period_minutes: Int
    public let repeated_failure_threshold: Int
    public let alert_cooldown_minutes: Int
    public let data_retention_days: Int
    public let track_git_activity: Bool
    public let remote_control_enabled: Bool

    public init(
        notifications_enabled: Bool, push_policy: String,
        digest_enabled: Bool, digest_interval_hours: Int,
        usage_spike_threshold: Int, project_budget_threshold_usd: Double,
        session_too_long_threshold_minutes: Int, offline_grace_period_minutes: Int,
        repeated_failure_threshold: Int, alert_cooldown_minutes: Int,
        data_retention_days: Int,
        track_git_activity: Bool = false,
        remote_control_enabled: Bool = false
    ) {
        self.notifications_enabled = notifications_enabled
        self.push_policy = push_policy
        self.digest_enabled = digest_enabled
        self.digest_interval_hours = digest_interval_hours
        self.usage_spike_threshold = usage_spike_threshold
        self.project_budget_threshold_usd = project_budget_threshold_usd
        self.session_too_long_threshold_minutes = session_too_long_threshold_minutes
        self.offline_grace_period_minutes = offline_grace_period_minutes
        self.repeated_failure_threshold = repeated_failure_threshold
        self.alert_cooldown_minutes = alert_cooldown_minutes
        self.data_retention_days = data_retention_days
        self.track_git_activity = track_git_activity
        self.remote_control_enabled = remote_control_enabled
    }
}

// MARK: - Webhook Event Filter

public struct WebhookEventFilter: Codable, Sendable, Equatable {
    public var severities: [String]
    public var types: [String]
    public var providers: [String]

    public init(severities: [String] = [], types: [String] = [], providers: [String] = []) {
        self.severities = severities
        self.types = types
        self.providers = providers
    }

    public var isEmpty: Bool {
        severities.isEmpty && types.isEmpty && providers.isEmpty
    }
}

// MARK: - Daily Usage (from CostUsageScanner)

public struct DailyUsage: Codable, Identifiable, Sendable {
    public var id: String { "\(date)-\(provider)-\(model)" }
    public let date: String           // "2026-04-07"
    public let provider: String       // "Codex", "Claude"
    public let model: String          // "gpt-5", "claude-sonnet-4-5"
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let cost: Double

    public init(date: String, provider: String, model: String, inputTokens: Int, cachedTokens: Int, outputTokens: Int, cost: Double) {
        self.date = date
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
        self.cost = cost
    }
}

// MARK: - Teams

public struct TeamDTO: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let owner_id: String
    public let created_at: String
    public let member_count: Int?
    public let role: String?  // caller's role in this team
}

public struct TeamMemberDTO: Codable, Identifiable, Sendable {
    public var id: String { user_id }
    public let user_id: String
    public let name: String
    public let email: String
    public let role: String  // "owner", "admin", "member"
    public let joined_at: String
}

public struct TeamInviteDTO: Codable, Identifiable, Sendable {
    public let id: String
    public let email: String
    public let role: String
    public let created_at: String
    public let expires_at: String
}

public struct TeamDetailDTO: Codable, Sendable {
    public let team: TeamDTO
    public let members: [TeamMemberDTO]
    public let invites: [TeamInviteDTO]
}

public struct TeamUsageSummaryDTO: Codable, Sendable {
    public let team_id: String
    public let total_usage: Int
    public let total_cost: Double
    public let member_count: Int
    public let provider_breakdown: [ProviderBreakdown]?
}

// MARK: - Remote Agent Sessions (v0.26)

/// Provider for a remote agent session. Mirrors the SQL CHECK constraint.
public enum RemoteSessionProvider: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case shell
}

/// Lifecycle state of a remote session as the helper sees it.
public enum RemoteSessionStatus: String, Codable, Sendable {
    case pending
    case running
    case stopped
    case errored
}

/// Risk classification attached to a remote permission request. UI uses this
/// to decide whether to show a stronger confirm flow before approving.
public enum RemotePermissionRisk: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

/// Decision scope for a permission request. `alwaysSession` is only honoured
/// for Claude in Phase 1; Codex requests are silently downgraded to `once`
/// server-side because Codex updatedPermissions is not exposed yet.
public enum RemotePermissionScope: String, Codable, Sendable {
    case once
    case alwaysSession
}

/// Kind of decision passed to `remote_app_decide_permission`.
public enum RemotePermissionDecisionAction: String, Codable, Sendable {
    case approve
    case deny
}

/// Kind of command queued via `remote_app_send_command`.
public enum RemoteCommandKind: String, Codable, Sendable {
    case prompt
    case stop
    case interrupt
}

/// One Claude / Codex / shell session running under the helper.
/// Snake-case to match the SQL → JSONB → REST shape. No transcript / API
/// keys / cookies are ever included.
///
/// `device_name` was introduced in iter 1 of Sessions Input — the new
/// `remote_app_list_sessions` RPC joins `devices.name`. Optional so the
/// model still decodes responses from older servers (during rollout) and
/// from the existing Phase-1 paths that don't carry the join.
public struct RemoteSession: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let device_id: String
    public let device_name: String?
    public let provider: String
    public let cwd_basename: String
    public let cwd_hmac: String?
    public let status: String
    public let client_label: String?
    public let created_at: String
    public let last_event_at: String?

    public init(
        id: String, device_id: String, device_name: String? = nil,
        provider: String, cwd_basename: String,
        cwd_hmac: String? = nil, status: String, client_label: String? = nil,
        created_at: String, last_event_at: String? = nil
    ) {
        self.id = id; self.device_id = device_id; self.device_name = device_name
        self.provider = provider
        self.cwd_basename = cwd_basename; self.cwd_hmac = cwd_hmac
        self.status = status; self.client_label = client_label
        self.created_at = created_at; self.last_event_at = last_event_at
    }

    /// Convenience: pending or running. Used by Sessions UI to filter
    /// out terminal-state rows that the server still returns until the
    /// retention cron prunes them.
    public var isManaged: Bool {
        let s = (RemoteSessionStatus(rawValue: status) ?? .errored)
        return s == .pending || s == .running
    }

    /// v1.16 §2.3: a session shown as "running" but with no `last_event_at`
    /// bump in `staleAfterSeconds` is likely stuck because the helper
    /// process died or got SIGSTOP'd. UI surfaces a "stale" badge and
    /// disables Send/Stop until the user restarts the helper.
    /// Default 60s matches the typical helper heartbeat interval.
    public func isStale(staleAfterSeconds: TimeInterval = 60, now: Date = Date()) -> Bool {
        guard isManaged else { return false }
        // Parse last_event_at; if absent, fall back to created_at since
        // a "running" session that's never bumped last_event_at is still
        // proportionally stale relative to its creation time.
        let timestamp = last_event_at ?? created_at
        guard let ts = ISO8601DateFormatter.cliPulseFlexible.date(from: timestamp) else {
            return false
        }
        return now.timeIntervalSince(ts) > staleAfterSeconds
    }
}

extension ISO8601DateFormatter {
    /// v1.16 §2.3: shared formatter that accepts both bare ISO ("2026-05-09T10:00:00Z")
    /// and fractional ("2026-05-09T10:00:00.123Z") forms emitted by Postgres.
    static let cliPulseFlexible: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

/// Append-only terminal-output / status row. Capped to 4 KB server-side.
public struct RemoteSessionEvent: Codable, Sendable, Identifiable {
    public let id: Int
    public let session_id: String
    public let seq: Int
    public let kind: String
    public let payload: String
    public let created_at: String
}

/// App→helper command queued via `remote_app_send_command`.
public struct RemoteSessionCommand: Codable, Sendable, Identifiable {
    public let id: String
    public let session_id: String?
    public let kind: String
    public let payload: String
    public let status: String
    public let created_at: String
    public let picked_up_at: String?
    public let completed_at: String?
}

/// One pending or decided remote permission request.
///
/// `device_name` was added in v0.32 (the list_pending_approvals RPC now
/// joins `devices.name`). It's optional because (a) older server versions
/// won't return the field during rollout and (b) the device row may have
/// been deleted between request creation and listing. UI falls back to a
/// generic label when nil.
public struct RemotePermissionRequest: Codable, Sendable, Identifiable {
    public let id: String
    public let session_id: String?
    public let device_id: String
    public let device_name: String?
    public let provider: String
    public let tool_name: String
    public let summary: String
    public let risk: String
    public let status: String
    public let created_at: String
    public let expires_at: String

    public init(
        id: String, session_id: String?, device_id: String, device_name: String? = nil,
        provider: String, tool_name: String, summary: String, risk: String, status: String,
        created_at: String, expires_at: String
    ) {
        self.id = id; self.session_id = session_id; self.device_id = device_id
        self.device_name = device_name
        self.provider = provider; self.tool_name = tool_name; self.summary = summary
        self.risk = risk; self.status = status
        self.created_at = created_at; self.expires_at = expires_at
    }
}

// MARK: - Remote Swarms (v1.22 P0 — Swarm View / backend v0.48)

/// One device's swarm heartbeat, as returned by `remote_app_list_swarms()`.
/// `swarms` is the per-swarm rollup the helper edge-aggregated (~30s
/// beat — R1-A4). `stale == true` ⇒ past the 90s live-TTL (RK8/R2-2):
/// the UI greys the card and shows "last seen", it is NOT dropped.
/// Verbatim snake_case to match the project's default `JSONDecoder()`
/// (no keyDecodingStrategy) — see APIClient.decode.
public struct RemoteSwarmDevice: Codable, Sendable, Identifiable {
    public var id: String { device_id }
    public let device_id: String
    public let updated_at: String
    public let age_s: Double
    public let stale: Bool
    public let swarms: [RemoteSwarm]

    public init(
        device_id: String, updated_at: String, age_s: Double,
        stale: Bool, swarms: [RemoteSwarm]
    ) {
        self.device_id = device_id; self.updated_at = updated_at
        self.age_s = age_s; self.stale = stale; self.swarms = swarms
    }
}

/// One swarm (a git repo+branch grouping of sibling agents) within a
/// device heartbeat. `handle` is the opaque `swarm-<6hex>` — NO repo or
/// branch name ever crosses the wire (RK7). P0 carries NO `$` figure;
/// the headline burn metric is agents/blocked (tokens/$ are P1).
public struct RemoteSwarm: Codable, Sendable, Identifiable {
    public var id: String { swarm_key }
    public let swarm_key: String
    public let handle: String
    public let is_linked_worktree: Bool
    public let providers: [String]
    public let agents: Int
    public let blocked: Int
    public let oldest_blocked_age_s: Double
    public let last_seen_s_ago: Double

    public init(
        swarm_key: String, handle: String, is_linked_worktree: Bool,
        providers: [String], agents: Int, blocked: Int,
        oldest_blocked_age_s: Double, last_seen_s_ago: Double
    ) {
        self.swarm_key = swarm_key; self.handle = handle
        self.is_linked_worktree = is_linked_worktree
        self.providers = providers; self.agents = agents
        self.blocked = blocked
        self.oldest_blocked_age_s = oldest_blocked_age_s
        self.last_seen_s_ago = last_seen_s_ago
    }
}
