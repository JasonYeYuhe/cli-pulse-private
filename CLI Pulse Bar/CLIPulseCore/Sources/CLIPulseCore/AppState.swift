import Foundation
import SwiftUI
import UserNotifications
import Combine
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
public final class AppState: ObservableObject {
    // MARK: - Widget publish (app-group) — off-main + dedupe

    /// Serial off-main queue for the app-group widget write + timeline reload
    /// done by `publishWidgetData()`. `UserDefaults.set` on the file-backed
    /// app-group suite flushes to cfprefsd over synchronous XPC; doing it on
    /// the main thread was the macOS App-Hang in Sentry APPLE-MACOS-9. Serial
    /// so back-to-back refreshes can't reorder writes (last submission wins).
    static let widgetWriteQueue = DispatchQueue(
        label: "yyh.CLI-Pulse.widget-write", qos: .utility)

    /// Last payload published (incl. its timestamp), so `publishWidgetData()`
    /// can skip the cfprefsd write + timeline reload when a refresh changed
    /// nothing user-visible — the macOS helper-sync path (`observeHelperSync`)
    /// fires it on every daemon collection with no debounce.
    var lastPublishedWidgetData: PublishedWidgetData?

    // MARK: - Auth State
    //
    // v1.10 P2-3 slice 3: extracted into a child `AuthState` ObservableObject.
    // Views that only need auth/profile/pairing status observe `authState`
    // directly via `@EnvironmentObject`, so login/profile/pairing updates
    // don't invalidate the entire AppState-observing tree. The 4 computed
    // properties below preserve AppState's public API so existing internal
    // callers (AuthManager.applyAuthenticatedState, DemoDataProvider,
    // DataRefreshManager contexts) keep working.
    public let authState = AuthState()

    public var isAuthenticated: Bool {
        get { authState.isAuthenticated }
        set { authState.isAuthenticated = newValue }
    }
    public var isPaired: Bool {
        get { authState.isPaired }
        set { authState.isPaired = newValue }
    }
    public var userId: String {
        get { authState.userId }
        set { authState.userId = newValue }
    }
    public var userName: String {
        get { authState.userName }
        set { authState.userName = newValue }
    }
    public var userEmail: String {
        get { authState.userEmail }
        set { authState.userEmail = newValue }
    }

    // MARK: - Data
    @Published public var dashboard: DashboardSummary?
    @Published public var sessions: [SessionRecord] = []
    @Published public var devices: [DeviceRecord] = []

    // v1.10 P2-3 slice 5: extracted into a child ProviderState ObservableObject.
    // `providers`, `providerConfigs`, `providerDetails`, `costSummary`, and
    // `editingProviderKind` live on `providerState`; AppState exposes them as
    // computed forwarders so setProviderEnabled/toggleProvider/DemoDataProvider/
    // DataRefreshManager-payload-assign compile unchanged.
    public let providerState = ProviderState()

    public var providers: [ProviderUsage] {
        get { providerState.providers }
        set { providerState.providers = newValue }
    }

    // v1.10 P2-3 slice 4: extracted into a child AlertState ObservableObject.
    // `alerts` and `suppressedAlertIDs` now live on `alertState`; AppState
    // exposes them as computed forwarders so existing mutators (AuthManager
    // sign-out reset, DemoDataProvider, DataRefreshManager payload assign,
    // suppression helpers) compile unchanged through implicit `self`.
    public let alertState = AlertState()

    public var alerts: [AlertRecord] {
        get { alertState.alerts }
        set { alertState.alerts = newValue }
    }

    // MARK: - Subscription
    //
    // v1.10 P2-3 slice 2: exposed as `let`, not `@Published`. Views that read
    // subscription state (SubscriptionSection, TeamView, iOSSettingsTab) now
    // observe `SubscriptionManager` directly via `@ObservedObject`, so tier /
    // product changes re-render only those views instead of invalidating the
    // entire AppState tree via a blanket `objectWillChange.sink` forwarder.
    public let subscriptionManager = SubscriptionManager.shared

    // MARK: - UI State
    @Published public var selectedTab: Tab = .overview
    @Published public var isLoading = false
    @Published public var lastError: String?
    @Published public var tierLimitWarning: String?
    /// Count of providers the tier-migration just auto-disabled.
    /// When > 0, the Overview shows a dismissible one-time banner with an
    /// "Edit in Settings" deep-link. Reset to 0 by dismissProviderLimitMigrationBanner().
    @Published public var providerLimitMigrationCount: Int = 0
    @Published public var lastRefresh: Date?
    @Published public var serverOnline = false
    @Published public var isLocalMode = false
    /// v1.10 P2-3 slice 5: forwarder to `providerState.editingProviderKind`.
    public var editingProviderKind: ProviderKind? {
        get { providerState.editingProviderKind }
        set { providerState.editingProviderKind = newValue }
    }

    // MARK: - Provider Management
    /// v1.10 P2-3 slice 5: forwarders to `providerState.*`.
    public var providerConfigs: [ProviderConfig] {
        get { providerState.providerConfigs }
        set { providerState.providerConfigs = newValue }
    }
    public var providerDetails: [ProviderDetail] {
        get { providerState.providerDetails }
        set { providerState.providerDetails = newValue }
    }
    public var costSummary: CostSummary {
        get { providerState.costSummary }
        set { providerState.costSummary = newValue }
    }
    public var locallySupplementedProviders: Set<String> = []

    // MARK: - Local alert suppression (v1.9.3)
    /// Alert IDs (locally generated, e.g. `quota-<provider>-<tier>-<threshold>`)
    /// that the user explicitly resolved/snoozed and should not re-fire from
    /// `AlertGenerator.evaluateQuotaAlerts` until the suppression expires.
    /// `Date.distantFuture` means "never reappear unless threshold ratchets up
    /// (which produces a new ID)". Persisted in UserDefaults.
    ///
    /// v1.10 P2-3 slice 4: forwarder to `alertState.suppressedAlertIDs`.
    /// Preserves the original `public internal(set)` API contract — external
    /// callers can read, only this module can mutate.
    public internal(set) var suppressedAlertIDs: [String: SuppressionEntry] {
        get { alertState.suppressedAlertIDs }
        set { alertState.suppressedAlertIDs = newValue }
    }

    // v1.10 P2-3 slice 1: the concrete types + pure logic moved to
    // AlertSuppression.swift. These type aliases + static passthroughs
    // preserve the existing AppState.SuppressionEntry / AppState.prunedSuppressions
    // public API surface for all existing callers and tests.

    public typealias SuppressionEntry = AlertSuppression.Entry

    internal static let suppressedAlertsKey   = AlertSuppression.legacyKey
    internal static let suppressedAlertsV2Key = AlertSuppression.currentKey

    public nonisolated static var permanentSuppressionRetentionDays: Double {
        AlertSuppression.permanentRetentionDays
    }

    /// Facade: defers to `AlertSuppression.prune(_:now:retentionDays:)`.
    public nonisolated static func prunedSuppressions(
        _ entries: [String: SuppressionEntry],
        now: Date,
        retentionDays: Double = AlertSuppression.permanentRetentionDays
    ) -> (active: Set<String>, kept: [String: SuppressionEntry]) {
        AlertSuppression.prune(entries, now: now, retentionDays: retentionDays)
    }

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
        let cutoffKey = DateRange.rollingWeekStartYMD(from: Date())
        let total = scan.entries
            .filter { $0.provider == provider && $0.date >= cutoffKey }
            .reduce(0) { $0 + $1.messageCount }
        return total > 0 ? total : nil
    }

    /// Tokens for the rolling 7-day window ending now (provider-aware).
    public func scanTokensThisWeek(for provider: String) -> Int? {
        guard let scan = costUsageScanResult, !scan.entries.isEmpty else { return nil }
        let cutoffKey = DateRange.rollingWeekStartYMD(from: Date())
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

    // MARK: - Usage-activity heatmap (v1.41, iOS)
    /// Cloud-hydrated daily archive powering the iOS usage-activity heatmap.
    /// macOS builds its own archive from the authoritative local JSONL scan
    /// (DailyUsageArchiveManager); iOS has no local scan, so this is cloud-only
    /// fidelity — the same caveat the iOS cost forecast already carries. Rebuilt
    /// from scratch on each refresh so the cloud stays authoritative (today's
    /// growing total isn't frozen by fill-only merge semantics).
    @Published public var usageArchive: DailyUsageArchive = DailyUsageArchive()
    private var usageArchiveLoadedAt: Date?

    /// Fetch up to a year of daily usage from Supabase and fold it into
    /// `usageArchive`. Cheap-cached: within `ttl` of the last successful load it
    /// no-ops (the heatmap is opened deliberately, not polled). A failed/empty
    /// fetch leaves the previous archive intact.
    public func refreshUsageArchive(days: Int = 365, ttl: TimeInterval = 300, force: Bool = false) async {
        if !force, let at = usageArchiveLoadedAt, Date().timeIntervalSince(at) < ttl { return }
        let rows = await api.fetchDailyUsage(days: days)
        guard !rows.isEmpty else { return }
        var a = DailyUsageArchive()
        let entries = rows
            .filter { $0.model != ScanEntry.messageBucketModel }
            .map { CloudEntry(date: $0.date, provider: $0.provider, model: $0.model,
                              inputTokens: $0.inputTokens, cachedTokens: $0.cachedTokens,
                              outputTokens: $0.outputTokens, cost: $0.cost) }
        a.mergeCloudDays(entries)
        usageArchive = a
        usageArchiveLoadedAt = Date()
    }

    // MARK: - Yield Score
    @Published public var yieldScoreDailyRows: [YieldScoreRow] = []
    @Published public var yieldScoreRange: YieldScoreRange = .thirtyDays
    /// Server-persisted opt-in for git activity tracking. Source of truth is
    /// `user_settings.track_git_activity`. Mirrored locally for UI toggle binding.
    @Published public var gitTrackingEnabled: Bool = false

    /// Server-persisted opt-in for Remote Agent Sessions / Remote Approvals.
    /// Source of truth is `user_settings.remote_control_enabled`. Default OFF —
    /// the same flag is enforced server-side on every helper RPC, so toggling
    /// it off here actually severs the helper end of the channel, not just
    /// the UI affordance.
    @Published public var remoteControlEnabled: Bool = false

    /// True while a `setRemoteControlEnabled` PATCH is in flight. UI binds
    /// `disabled(state.remoteControlSaving)` on the Toggle so the user can't
    /// fire a second toggle on top of the first; periodic settings refreshes
    /// also skip overwriting `remoteControlEnabled` while this is true so a
    /// stale server response can't undo the user's latest intent (Codex
    /// review iter5 P1: latest-intent-wins).
    @Published public var remoteControlSaving: Bool = false

    /// Last APNs token we successfully synced to the server, lower-case
    /// hex. Nil = no token registered yet (or just unregistered on logout).
    /// Lives in memory only — persistence is in the server's
    /// `app_push_tokens` table; we re-register on each app launch when
    /// APNs hands us a token, which costs one cheap RPC.
    @Published public var registeredPushToken: String?

    /// In-memory cache of an APNs token that was delivered BEFORE the
    /// user signed in. APNs delivers the token once per launch via the
    /// `didRegisterForRemoteNotificationsWithDeviceToken` callback; if
    /// we drop it pre-auth, the user has to relaunch the app post-login
    /// to get push notifications working. Instead we cache here, then
    /// `flushPendingPushTokenIfAvailable` replays it from
    /// `applyAuthenticatedState` so every sign-in path picks it up.
    /// Cleared after a successful server-side register.
    public var pendingPushTokenRegistration: PendingPushTokenRegistration?

    // MARK: - Remote Approvals (v0.26 — Phase 1 MVP)
    /// Pending remote permission requests pulled from
    /// `remote_app_list_pending_approvals`. Refreshed lazily — only when the
    /// approvals sheet is open or the menu-bar popover is visible AND
    /// `remoteControlEnabled` is true. We do NOT poll while the feature is
    /// disabled; that's both wasted bandwidth and an inadvertent leak signal.
    @Published public var remotePendingApprovals: [RemotePermissionRequest] = []
    @Published public var remoteApprovalsLastRefresh: Date?
    @Published public var remoteApprovalsError: String?

    // MARK: - Remote Sessions (Sessions Input iter 1)
    /// Managed Claude sessions the helper has spawned (or is about to
    /// spawn). Pulled from `remote_app_list_sessions`. Refreshed only
    /// while the Sessions UI is on screen AND `remoteControlEnabled`
    /// — same gating discipline as `remotePendingApprovals`. Cleared
    /// when Remote Control toggles off and on logout.
    @Published public var remoteSessions: [RemoteSession] = []
    @Published public var remoteSessionsLastRefresh: Date?
    @Published public var remoteSessionsError: String?

    // MARK: - Remote Swarms (v1.22 P0 — Swarm View / v0.48)
    /// Per-device edge-aggregated swarm rollups from
    /// `remote_app_list_swarms`. Same gating discipline as
    /// `remoteSessions` (refreshed only while the Swarm UI is on screen
    /// AND `remoteControlEnabled`; cleared on RC-off and logout).
    @Published public var remoteSwarms: [RemoteSwarmDevice] = []
    @Published public var remoteSwarmsLastRefresh: Date?
    @Published public var remoteSwarmsError: String?

    // MARK: - Remote Session Events (Sessions Input iter 2 — live tail)
    /// Live output tail per managed session, keyed by `RemoteSession.id`.
    /// Each list is the appended history of `stdout` / `stderr` /
    /// `status` / `info` events the helper has posted, capped at
    /// `remoteSessionEventsCap` rows so a chatty Claude run can't grow
    /// app memory unbounded.
    ///
    /// Populated only while a detail view has the user-explicit
    /// "Show output" toggle on AND `remoteControlEnabled` is true —
    /// same default-off privacy posture as the rest of Remote
    /// Control. Cleared when Remote Control toggles off and on
    /// logout.
    ///
    /// Pagination: callers track the largest event `id` they've
    /// stored locally and pass it as `afterId` on the next refresh,
    /// so we never re-fetch unbounded history.
    @Published public var remoteSessionEvents: [String: [RemoteSessionEvent]] = [:]

    /// Per-session ring-buffer cap. 500 events × ≤ 4 KB / event = ~2 MB
    /// worst case per session (in practice much less because the
    /// helper's batcher targets ~3.5 KB chunks and redaction shrinks
    /// most output).
    ///
    /// Bumped from 200 to 500 on 2026-05-08 to address a user-reported
    /// "3rd-turn output stops displaying" symptom. Claude's TUI emits
    /// many chrome / repaint events between user prompts (Processing
    /// spinners, token counters, status bar). At cap=200 a chatty Claude
    /// run could push the conversational `❯` / `⏺` markers out of the
    /// trimmed window before the user finished reading earlier turns.
    /// 500 events covers ≥ 5 minutes of typical activity at the helper's
    /// 3.5 KB / 0.5 s flush cadence.
    public static let remoteSessionEventsCap: Int = 500

    // MARK: - Local Session Control (Phase 3 Iter 1, macOS-only)
    #if os(macOS)
    /// True iff the most recent `LocalSessionControlClient.hello()`
    /// against this Mac's helper UDS socket succeeded. Drives the
    /// "helper not running" banner and the local-vs-remote routing
    /// decision in `openManagedClaudeSession`. Reset to false on any
    /// transport failure.
    @Published public var localHelperReachable: Bool = false

    /// Last known `local_control_enabled` value reported by the
    /// helper. Defaults false (privacy-default opt-out). Updated by
    /// `setLocalControlEnabled`; not refreshed automatically because
    /// reading it back from the helper would itself require the gate
    /// to be on for most methods (chicken-and-egg).
    @Published public var localControlEnabled: Bool = false

    /// Capability flags returned by the helper's `hello`. Used by the
    /// macOS UI to decide which controls to enable when local routing
    /// is in effect (iter 1: start / list / stop only).
    @Published public var localCapabilities: SessionControlCapabilities?
    /// M4.4c: the method names the socket-owner helper advertised in `hello`.
    /// Empty until the first successful hello. The tmux-wrap UI gates on these
    /// so an older helper (without the verbs) shows an update-required state
    /// instead of erroring on click.
    @Published public var localSupportedMethods: Set<String> = []

    /// Phase 4 helper-bundling: status of the embedded LaunchAgent.
    #if os(macOS)
    /// Drives the Settings → Helper status surface so users can see
    /// whether the embedded helper is running (`.registered`),
    /// missing (`.bundledBinaryMissing` — dev build before Run
    /// Script phase), or in error. Live-updated by
    /// `ensureHelperAgentRegistered()` on app launch. macOS-only —
    /// `HelperLifecycleManager.Status` is itself `#if os(macOS)`
    /// because `SMAppService` only exists on macOS.
    @Published public var helperAgentStatus: HelperLifecycleManager.Status = .notRegistered
    #endif

    #if os(macOS)
    /// Lifecycle manager for the embedded `cli_pulse_helper`
    /// LaunchAgent. macOS-only — `HelperLifecycleManager` itself is
    /// `#if os(macOS)`-guarded because `SMAppService` doesn't exist on
    /// iOS / watchOS / Widgets, and those targets have no helper to
    /// supervise. Held as an `actor` so registration / unregistration
    /// can be invoked safely from any thread without races on the
    /// SMAppService API.
    public let helperLifecycle = HelperLifecycleManager()
    #endif

    /// Helper protocol version reported by `hello`. Pinned at 1 by
    /// the iter-1 server; iter 2A may bump it.
    @Published public var localProtocolVersion: Int = 0

    /// v1.15: subset of `["claude","codex","gemini"]` the helper can
    /// actually spawn on this Mac, reported in the `hello` reply.
    /// Empty when the helper hasn't been upgraded to v1.15 yet — the
    /// spawn picker treats empty as "unknown, allow all" so users on a
    /// rolling-out helper aren't blocked from spawning Claude.
    @Published public var localProviderAvailability: [String] = []

    /// Per-provider plan-auth status ("on_plan"/"off_plan") from the helper's hello reply.
    /// A provider absent here (older helper, or status "unknown") ⇒ no warning. The spawn
    /// picker reads this to warn before launching an off-plan (billed) managed session
    /// (e.g. Codex with an api-key login that would bill the OpenAI API, not the plan).
    @Published public var localProviderPlanStatus: [String: String] = [:]

    /// v1.34 R1d: the semantic version of the helper that currently OWNS the
    /// managed-session socket, from the `hello` reply (`helper_version`). Empty
    /// when unreachable, or when an ancient helper omits the field. Drives
    /// `localHelperBelowOAuthFloor` — the Claude-on-Max safety gate. Note this
    /// is the SOCKET OWNER, which on a Mac with a stale `.pkg` helper installed
    /// is NOT necessarily the app-bundled helper (the bundled helper cedes to a
    /// live peer), so we must check whoever actually answers `hello`.
    @Published public var localHelperVersion: String = ""

    /// Last error string from any local-control call, surfaced inline
    /// in the Sessions UI when non-nil. Cleared on a successful
    /// `refreshLocalSessionControlState`.
    @Published public var localHelperError: String?

    /// Phase 3 Iter 2A: same-Mac Claude processes the helper detected
    /// via `_detect_provider` (PR #14) but does NOT own. Read-only
    /// from the macOS UI's perspective: the Sessions tab renders
    /// these in a separate "Detected on this Mac" section so users
    /// can see what's running outside CLI Pulse without believing
    /// the app can safely write to or stop them. Populated from
    /// `LocalSessionControlClient.listSessions` filtered to
    /// `controllable == false`.
    @Published public var localDetectedSessions: [SessionControlSummary] = []

    /// Companion to `localDetectedSessions` for the helper-owned
    /// managed rows the local UDS surface returned on the most recent
    /// refresh. The macOS UI continues to drive its primary list off
    /// `remoteSessions` (which already includes managed local rows
    /// via the helper's `register_session` RPC). This field exists
    /// for tests + future UI surfaces that want to render
    /// local-managed-only without waiting for Supabase freshness.
    @Published public var localManagedSessions: [SessionControlSummary] = []

    /// Diagnostic snapshot from the most recent
    /// `refreshLocalSessionControlState` tick. Surfaced in the
    /// "Diagnose" panel under Sessions so the user (and Codex) can
    /// see resolved socket / token paths + existence state in the
    /// UI rather than having to read Xcode logs.
    ///
    /// Cleared to nil on logout / sign-out, otherwise refreshed
    /// every tick the Sessions tab is on screen.
    @Published public var localDiagnostics: LocalSessionControlClient.Diagnostics?

    /// PR #18 follow-up — most recent `~/.claude/settings.json` hook
    /// wiring status. The Sessions tab uses this to show a banner
    /// when the helper advertises `capabilities.approvals = true`
    /// but Claude itself isn't routing PermissionRequest events to
    /// the helper. Without that wiring, Claude shows its native
    /// PTY prompt and the structured Approve/Reject controls in
    /// CLI Pulse never light up — exactly the diagnosis the
    /// previous manual test surfaced.
    ///
    /// Refreshed each `.task` tick of SessionsTab and on
    /// `refreshLocalSessionControlState`. `nil` while we haven't
    /// checked yet (suppresses banner during cold launch).
    @Published public var claudeApprovalHookStatus: ClaudeHookDetector.Status?

    /// M4.4c: opt-in shell-integration status (wraps future claude/codex into a
    /// CLI-Pulse tmux for full remote I/O). `nil` until first fetched.
    @Published public var shellIntegrationStatus: ShellIntegrationStatus?
    /// M4.4c: CLI-Pulse-wrapped tmux sessions discovered on this Mac (names the
    /// helper's `list_wrapped_sessions` returned) — the app offers to attach each.
    @Published public var wrappedSessions: [String] = []
    /// M4.4d: session ids of attached wrapped sessions the user opted into the
    /// cloud plane, so the phone can see and drive them. Empty by default — an
    /// external session the user launched themselves stays local-only until they
    /// say otherwise. Keyed by session id (see `WrappedSessionID`), not tmux
    /// name, because that's what the helper and the cloud row both key on.
    @Published public var wrappedCloudSharedSessionIds: Set<String> = []

    // MARK: - Local Session Control (Phase 3 Iter 2B, macOS-only)

    /// Iter 2B: structured pending approvals per managed session,
    /// keyed by session id. Populated from `subscribe_events`
    /// approval_requested frames AND from `get_pending_approvals`
    /// snapshots (the latter is the recovery path after a stream
    /// reconnect or app launch).
    ///
    /// **The Approve / Reject controls in SessionsTab MUST be gated
    /// on `localPendingApprovals[sessionId]?.isEmpty == false`.**
    /// This is the only correct way to determine whether a session
    /// has an outstanding approval — never infer from PTY output
    /// text.
    @Published public var localPendingApprovals: [String: [PendingApproval]] = [:]

    /// Iter 2B: rolling output preview per session, fed by
    /// `output_delta` events on the live stream. The macOS
    /// expanded-row view tails this string. Capped at
    /// `localOutputPreviewCap` chars per session so a chatty
    /// Claude session can't grow app memory unbounded.
    @Published public var localOutputPreview: [String: String] = [:]

    /// Per-session preview buffer cap. ~32 KB per session is plenty
    /// for the last few seconds of tail output without becoming a
    /// memory hog. The user reads this to decide when to send the
    /// next prompt; stale tail bytes don't add value.
    public static let localOutputPreviewCap: Int = 32 * 1024

    /// In-flight `subscribe_events` Tasks keyed by session id.
    /// `subscribeToLocalEvents(sessionId:)` populates this; the
    /// matching `unsubscribeFromLocalEvents` cancels the Task.
    /// Internal because the UI binds via @Published — only AppState
    /// itself reads/writes this map.
    internal var localEventTasks: [String: Task<Void, Never>] = [:]

    /// v1.16 hotfix: timestamps for optimistically-appended local
    /// session ids. The 3 s `refreshLocalSessionControlState` poll can
    /// race the helper's `register_session` write, returning a
    /// `list_sessions` response that does NOT include the just-spawned
    /// id. Without this map the next `reconcileLocalStaleSessionState`
    /// purges the live stream + preview, causing "no output" after a
    /// successful start. Entries within `localOptimisticGraceSeconds`
    /// are preserved across the merge in
    /// `refreshLocalSessionControlState`.
    internal var localOptimisticAppendedAt: [String: Date] = [:]

    /// Grace window (seconds) for `localOptimisticAppendedAt`. 30 s is
    /// conservative; helper register_session should complete in <1 s
    /// in the common case but Supabase upsert latency under poor
    /// network can push it higher.
    public static let localOptimisticGraceSeconds: TimeInterval = 30
    #endif

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

    // MARK: - v1.16 Companion CLI Helper Installer
    /// Drives the "Install / Update / Uninstall Companion CLI" UI. Lazily
    /// constructed on first access so unit tests that don't exercise this
    /// surface don't need to mock URLSession + UDS at all.
    #if os(macOS)
    @Published public var helperInstaller: HelperInstaller = HelperInstaller()
    #endif

    // MARK: - v1.19 Developer ID App Updater
    /// Drives the "Check for Updates / Install Update" UI for the
    /// Developer ID DMG distribution channel. Only present in DEVID
    /// builds (MAS users get App Store updates via appstoreagent).
    #if os(macOS) && DEVID_BUILD
    @Published public var appUpdater: AppUpdater = AppUpdater()
    #endif

    // MARK: - v1.41 Remote machine control executor
    /// Polls the helper UDS for fan/LPM REQUESTS and executes them via the root
    /// fan daemon (FanControlClient). DEVID-only (the root daemon + FanControlClient
    /// are DEVID-only); gated at runtime by `remoteMachineControlEnabled` (default
    /// OFF) && the daemon being available. Started from `init()`; the fan dead-man
    /// heartbeat + TTL revert stay local so the phone never holds a boost.
    #if os(macOS) && DEVID_BUILD
    public let remoteMachineExecutor = RemoteMachineExecutor(
        fan: FanControlClient(),
        relay: LocalSessionControlClient(),
        // v1.42: the SHARED keep-awake controller — the same IOPM assertion the
        // local Machine-tab card drives, so remote + local are one source of truth.
        keepAwake: KeepAwakeController.shared
    )
    #endif

    // MARK: - v1.19 G1 permission migration checker
    /// Detects TCC permission revocations on the MAS → DEVID migration
    /// path and surfaces a banner for re-granting. Snapshot writer runs
    /// on BOTH MAS and DEVID launches (same call); only DEVID builds
    /// trigger the comparison + nudge logic. Caller must invoke
    /// `runOnLaunch()` early in app init.
    #if os(macOS)
    @Published public var permissionMigrationChecker: AppPermissionMigrationChecker = AppPermissionMigrationChecker()
    #endif

    // MARK: - Webhook Integration
    @AppStorage("cli_pulse_webhook_enabled") public var webhookEnabled = false
    @AppStorage("cli_pulse_webhook_url") public var webhookURL = ""
    @Published public var webhookEventFilter: WebhookEventFilter = WebhookEventFilter()
    /// Iter2: kill-switch for the inline `api.sendWebhook` path. Defaults
    /// to `true` so fresh installs use the server-side `webhook_jobs`
    /// fan-out (Postgres trigger → cron → edge), which works for closed
    /// clients, Android, watchOS, and cron-generated alerts. The flag
    /// exists so we can revert the migration without leaving users with
    /// no webhook delivery at all. Once the migration has soaked for one
    /// release cycle, `sendWebhook` can be deleted entirely and this
    /// flag retired.
    @AppStorage("cli_pulse_server_side_webhook_enabled") public var serverSideWebhookEnabled: Bool = true

    // MARK: - Settings - General
    nonisolated static let tokenKeychainKey = "cli_pulse_token"

    public var storedToken: String {
        get { KeychainHelper.load(key: Self.tokenKeychainKey) ?? "" }
        set { Self.persistAuthTokens(access: newValue, refresh: storedRefreshToken) }
    }

    /// Refresh cadence in seconds. `0` = the v1.40 "Adaptive" mode (2–30 min by
    /// menu-open recency / LPM / thermal). Fresh installs default to Adaptive
    /// (see `applyAdaptiveRefreshDefaultIfFreshInstall`); existing users keep
    /// whatever they had (the stored default was 120s).
    @AppStorage("cli_pulse_refresh_interval") public var refreshInterval: Int = 120
    /// One-time guard so the Adaptive default is applied to fresh installs only.
    @AppStorage("cli_pulse_refresh_adaptive_default_applied") var refreshAdaptiveDefaultApplied = false

    /// v1.40 PR-7: display currency for costs (storage stays USD; conversion at
    /// display time via CurrencyConverter). Use `displayCurrency` / `setDisplayCurrency`.
    @AppStorage("cli_pulse_display_currency") var displayCurrencyRaw = DisplayCurrency.usd.rawValue
    public var displayCurrency: DisplayCurrency {
        DisplayCurrency(rawValue: displayCurrencyRaw) ?? .usd
    }
    public func setDisplayCurrency(_ currency: DisplayCurrency) {
        displayCurrencyRaw = currency.rawValue
        CurrencyConverter.shared.setCurrency(currency)
        objectWillChange.send()   // re-render the popover's cost labels immediately
        Task { await CurrencyConverter.shared.refreshRatesIfStale() }
    }
    @AppStorage("cli_pulse_show_cost") public var showCost = true
    @AppStorage("cli_pulse_notifications") public var notificationsEnabled = true
    @AppStorage("cli_pulse_compact_mode") public var compactMode = false
    @AppStorage("cli_pulse_check_provider_status") public var checkProviderStatus = true
    @AppStorage("cli_pulse_session_quota_notifications") public var sessionQuotaNotifications = true
    @AppStorage("cli_pulse_hide_personal_info") public var hidePersonalInfo = false
    @AppStorage("cli_pulse_appearance") public var appearanceModeRaw = 0

    // MARK: - Machine controls (M1)
    /// Off by default, DEVID-only. Gates the Machine tab's "End Process"
    /// affordance — no destructive verb is reachable until the owner opts in
    /// (mirrors the Remote Control / local-fast-path opt-in posture). Read
    /// directly via @AppStorage in MachineHealthView, so the toggle and the
    /// affordance share one UserDefaults key with no drift.
    @AppStorage("cli_pulse_machine_controls_enabled") public var machineControlsEnabled = false

    // MARK: - Remote machine control (v1.41 "Mobile Machine")
    /// Off by default, DEVID-only, SECOND opt-in on top of `machineControlsEnabled`.
    /// Gates whether this Mac's `RemoteMachineExecutor` will honor fan-boost / Low
    /// Power Mode REQUESTS from the owner's other signed-in devices (phone/watch).
    /// A cloud command is only ever a request — the fan hold heartbeat + TTL revert
    /// stay entirely local. Read directly via UserDefaults by the executor (same
    /// key, no drift), mirroring `machineControlsEnabled`.
    @AppStorage(kRemoteMachineControlEnabledKey) public var remoteMachineControlEnabled = false

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
        case machine = "Machine"
        case providers = "Providers"
        case sessions = "Sessions"
        case swarm = "Swarm"
        case alerts = "Alerts"
        case pet = "Pet"
        case settings = "Settings"

        public var icon: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.33percent"
            case .machine: return "memorychip"
            case .providers: return "cpu"
            case .sessions: return "terminal"
            case .swarm: return "square.grid.3x3.fill"
            case .alerts: return "bell.badge"
            case .pet: return "pawprint.fill"
            case .settings: return "gear"
            }
        }

        public var label: String {
            switch self {
            case .overview: return L10n.tab.overview
            case .machine: return L10n.tab.machine
            case .providers: return L10n.tab.providers
            case .sessions: return L10n.tab.sessions
            case .swarm: return L10n.tab.swarm
            case .alerts: return L10n.tab.alerts
            case .pet: return L10n.tab.pet
            case .settings: return L10n.tab.settings
            }
        }
    }

    public let api: APIClient
    let authManager: AuthManager
    let dataRefreshManager: DataRefreshManager

    private static let secretsMigratedKey = "cli_pulse_provider_secrets_migrated"
    /// v1.33 keychain-access-group migration flag. One-shot: re-homes
    /// pre-existing provider secrets into the shared app-group keychain so the
    /// LoginItem helper stops firing the recurring consent prompt.
    private static let keychainGroupMigratedKey = "cli_pulse_keychain_group_migrated"

    public init() {
        self.api = APIClient()
        self.authManager = AuthManager(api: api, persistTokens: Self.persistAuthTokens)
        self.dataRefreshManager = DataRefreshManager(api: api)
        subscriptionManager.apiClient = api
        loadProviderConfigs()
        loadSuppressedAlertIDs()
        applyAdaptiveRefreshDefaultIfFreshInstall()
        // v1.40 PR-7: sync the display currency + refresh FX rates (cached 24h).
        CurrencyConverter.shared.setCurrency(displayCurrency)
        Task { await CurrencyConverter.shared.refreshRatesIfStale() }

        // v1.10 P2-3 slice 2: the `subscriptionCancellable` forwarder that
        // re-emitted the manager's objectWillChange into AppState's has been
        // removed. Views now observe SubscriptionManager directly via
        // @ObservedObject.

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

        #if os(macOS)
        // Phase 4 helper-bundling: kick the LaunchAgent registration
        // off on launch. SMAppService.register is idempotent and
        // doesn't show user UI for LaunchAgents (only LoginItems do),
        // so calling on every launch is safe. The status updates
        // back onto MainActor so the Settings → Helper panel sees
        // the new value without a manual refresh. iOS / watchOS /
        // Widgets have no helper to register; this whole block
        // compiles out on those platforms.
        Task { [weak self] in
            guard let self else { return }
            let status = await self.helperLifecycle.ensureRegistered()
            await MainActor.run {
                self.helperAgentStatus = status
            }
            #if DEVID_BUILD
            // v1.43 controlled helper swap: `ensureRegistered()` is a no-op for
            // an already-registered KeepAlive agent, so after an in-place app
            // update launchd keeps the OLD bundled helper process alive (old
            // binary) until re-login — leaving an upgraded user nagged. Detect
            // the app-binary change via a persisted sentinel and kickstart OUR
            // LaunchAgent once per new app version so the new bundle's helper
            // takes over now. This clears the nag even for users upgrading from
            // a pre-v1.43 helper whose hello can't be identified as stale (dual
            // review codex+agy P1). No-op on same-version launches; failure-soft.
            let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
            let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            let didSwap = await self.helperLifecycle.kickstartBundledHelperIfAppUpdated(
                currentAppVersion: "\(short)/\(build)"
            )
            if didSwap {
                // Reconcile the installer UI once the respawned helper is up, so
                // a refresh that ran against the pre-swap helper can't leave a
                // stale update nag on screen (codex round-2 P2).
                await self.helperInstaller.refreshAfterHelperRespawn()
            }
            #endif
        }

        // v1.19 G1: write a TCC permission snapshot to app-group
        // UserDefaults from BOTH MAS and DEVID builds (the same call
        // path). DEVID builds additionally compare against the
        // previous snapshot and surface a banner if permissions look
        // reverted. Read-only — does not request authorization (that
        // remains owned by DataRefreshManager).
        Task { [weak self] in
            guard let self else { return }
            await self.permissionMigrationChecker.runOnLaunch()
        }

        #if DEVID_BUILD
        // v1.41: start the remote machine-control executor. It stays idle (no UDS
        // traffic) until the `remoteMachineControlEnabled` opt-in AND the fan
        // daemon are both ready, so starting unconditionally on launch is safe.
        Task { [weak self] in
            guard let self else { return }
            await self.remoteMachineExecutor.start()
        }
        #endif
        #endif
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
            // v1.23 G4: CodexBar-parity pace forecast. Prefer the
            // ultra-compact engine label ("▲12%"/"▼8%"/"≈"); fall back
            // to the prior remaining-% rendering when the engine has no
            // verdict (non-Codex/Claude top provider, or no reset
            // anchor) so behavior is unchanged for those cases.
            if let top = mostUsedProvider {
                if let paceLabel = top.paceMenuLabel() {
                    return paceLabel
                }
                if top.usagePercent > 0 {
                    return String(format: "%.0f%%", top.usagePercent * 100)
                }
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
                    // Same "CLI Pulse" disambiguation as the periodic
                    // tier-limit banner — see DataRefreshManager
                    // .tierLimitWarning. Use the localized display
                    // name ("Free", "Pro", "Team") rather than the
                    // lowercase enum rawValue ("free"/"pro"/"team").
                    let tierLabel = subscriptionManager.tierName(
                        for: subscriptionManager.currentTier
                    )
                    tierLimitWarning = "Your CLI Pulse \(tierLabel) plan allows up to \(maxProviders) providers. Upgrade to enable more."
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

    /// Auto-disables extra providers when a free-tier user has more enabled
    /// than their plan allows. Must be invoked AFTER
    /// `subscriptionManager.updateCurrentEntitlements()` has resolved — tier
    /// starts `.free` and updates asynchronously, so running in `init()`
    /// would wrongly prune paid users on cold launch (Codex review 2026-04-23).
    ///
    /// Ranking (highest-priority first):
    ///   1. Enabled configs with usage data today or this week.
    ///   2. Enabled configs with credentials set (API key / cookie).
    ///   3. First three by `ProviderKind.allCases` order (claude/codex/gemini).
    ///
    /// Idempotency: gated by `enabledCount > maxProviders`. No persisted
    /// one-shot flag — this way the migration cleanly handles subscription
    /// downgrades (Paid → Free) that push the user over limit again, and
    /// upgrades (Free → Paid) clear the lock-state badges automatically
    /// (Gemini 3.1 Pro review 2026-04-23).
    public func migrateProviderLimitsIfNeeded() {
        let disabledByTierKey = "cli_pulse_providers_disabled_by_tier"
        let maxProviders = subscriptionManager.maxProviders
        guard maxProviders >= 0 else {
            // Paid / unlimited — clear any lingering "Limited by free plan"
            // badges from a prior free-tier session so the UI reflects the
            // upgrade immediately.
            UserDefaults.standard.removeObject(forKey: disabledByTierKey)
            providerLimitMigrationCount = 0
            return
        }

        // iter9 hotfix (2026-04-29): previously the gate compared raw
        // enabled-toggle count (`providerConfigs.filter(\.isEnabled).count`)
        // against `maxProviders`. For a fresh user, `ProviderConfig.defaults()`
        // sets `isEnabled: true` for every one of the 26 ProviderKind cases,
        // so 26 > 3 always tripped the migration on free plan even when the
        // user only had 2 actually-used providers (Ollama + Claude). The
        // banner then said "Disabled 23 — edit in Settings → Providers",
        // which made it look like we silently nuked the user's setup when
        // really we just pruned defaults they'd never touched.
        //
        // The fix: gate the migration on `activeProviderCount` — the same
        // canonical "really being used" count already used by the plan-limit
        // warning (see `DataRefreshManager.activeProviderCount`). A user is
        // "active" on a provider if either the server has non-zero usage for
        // them OR they've configured credentials for that kind. Toggles
        // alone do not count.
        //
        // Behavior after the fix:
        //   - Fresh free user (0–3 active providers, 26 default toggles):
        //     no migration, no banner. Toggles remain enabled as defaults
        //     until the user activates a 4th provider.
        //   - Free user actively using 6 providers: migration runs, prunes
        //     toggles to top 3 by usage/credentials, banner shows "Disabled
        //     N actively-used providers" — accurate and actionable.
        //   - Paid user downgraded to free: same behavior — banner only if
        //     they're actively over the new limit.
        let activeCount = Self.activeKindsForMigrationBanner(
            providers: providers,
            providerConfigs: providerConfigs
        ).count
        guard activeCount > maxProviders else {
            // At or under limit by the canonical measure — nothing to
            // migrate, no banner. Clear any stale "Limited by free plan"
            // badges since the situation no longer applies.
            UserDefaults.standard.removeObject(forKey: disabledByTierKey)
            providerLimitMigrationCount = 0
            return
        }

        // Active providers exceed the plan limit. Proceed with the prune
        // body using the (still raw) enabled-toggle list as input — the
        // ranking heuristic below already prefers active providers, so
        // when we keep the top `maxProviders` we keep the actively-used
        // ones first.
        let enabledConfigs = providerConfigs.filter(\.isEnabled)

        // Rank the enabled configs.
        let usageByKind: [String: ProviderUsage] = Dictionary(
            uniqueKeysWithValues: providers.map { ($0.provider, $0) }
        )
        let fallbackOrder: [ProviderKind] = Array(ProviderKind.allCases.prefix(maxProviders))

        func rank(_ config: ProviderConfig) -> Int {
            if let u = usageByKind[config.kind.rawValue],
               u.today_usage > 0 || u.week_usage > 0 {
                return 0  // tier 1 — recent usage
            }
            if config.hasCredentials {
                return 1  // tier 2 — configured credentials
            }
            if fallbackOrder.contains(config.kind) {
                return 2  // tier 3 — default-trio fallback
            }
            return 3  // no signal
        }

        // Sort enabled configs by rank asc, then by (within same rank) usage
        // desc, then by `ProviderKind.allCases` index asc for a deterministic
        // tiebreak.
        let kindIndex: [ProviderKind: Int] = Dictionary(
            uniqueKeysWithValues: ProviderKind.allCases.enumerated().map { ($0.element, $0.offset) }
        )
        let ranked = enabledConfigs.sorted { a, b in
            let ra = rank(a); let rb = rank(b)
            if ra != rb { return ra < rb }
            let ua = usageByKind[a.kind.rawValue].map { $0.today_usage + $0.week_usage } ?? 0
            let ub = usageByKind[b.kind.rawValue].map { $0.today_usage + $0.week_usage } ?? 0
            if ua != ub { return ua > ub }
            return (kindIndex[a.kind] ?? .max) < (kindIndex[b.kind] ?? .max)
        }

        let keptKinds = Set(ranked.prefix(maxProviders).map(\.kind))
        var disabledByMigration: [ProviderKind] = []
        // iter9 hotfix: also track which of the disabled kinds were
        // *actually* in active use (had usage or credentials) so we can
        // report only the user-visible impact in the banner. Disabling 20
        // default-but-untouched toggles alongside the 3 actively-used ones
        // is implementation detail; the user's mental model says "you
        // disabled 3 things I was using", not "you disabled 23 toggles".
        var disabledActiveByMigration: [ProviderKind] = []
        let activeKinds = Self.activeKindsForMigrationBanner(
            providers: providers,
            providerConfigs: providerConfigs
        )
        for i in providerConfigs.indices where providerConfigs[i].isEnabled {
            if !keptKinds.contains(providerConfigs[i].kind) {
                let kind = providerConfigs[i].kind
                providerConfigs[i].isEnabled = false
                disabledByMigration.append(kind)
                if activeKinds.contains(kind) {
                    disabledActiveByMigration.append(kind)
                }
            }
        }

        // Record which kinds were disabled by migration (vs. user choice) so
        // Settings can show a distinct "Limited by free plan" state later.
        // Merge with any existing set so a second downgrade doesn't lose
        // providers that were disabled by an earlier migration run.
        // Note: store ALL disabled kinds (including default toggles) here
        // so the Settings UI keeps the per-row badge distinction. Only the
        // BANNER count is filtered to the active subset.
        let existingRaw = UserDefaults.standard.stringArray(forKey: disabledByTierKey) ?? []
        let mergedRaw = Set(existingRaw).union(disabledByMigration.map(\.rawValue))
        UserDefaults.standard.set(Array(mergedRaw), forKey: disabledByTierKey)

        saveProviderConfigs()
        buildProviderDetails()

        // iter9 hotfix: banner reflects the actively-used provider count
        // disabled, not the raw toggle count. If only default toggles were
        // pruned (no active provider lost), the banner stays at 0 — silent
        // tidy-up rather than a scary alert.
        providerLimitMigrationCount = disabledActiveByMigration.count
    }

    /// Set of provider kinds that count as "active" for the migration
    /// banner — server-side usage in current period OR enabled config
    /// with credentials. Both branches additionally require the
    /// corresponding `ProviderConfig` to be `isEnabled = true`.
    ///
    /// Why the `isEnabled` requirement on the usage branch (asymmetric
    /// vs `DataRefreshManager.activeProviderCount`):
    ///
    /// In production today, this helper is only invoked from
    /// `migrateProviderLimitsIfNeeded`, which itself only runs once per
    /// cold launch in `AuthManager.restoreSession()` — at which point
    /// `state.providers` is still `[]` because `refreshAll()` hasn't
    /// fired yet. So the stale-usage-row hazard is moot in the current
    /// call graph.
    ///
    /// But this helper is the migration's *gating rule*. If a future
    /// engineer adds a second call site (e.g. a "reset to plan defaults"
    /// menu item or a tier-change observer that re-fires migrate during
    /// a live session), the helper would suddenly see a populated
    /// `providers` array carrying server rows for kinds the migration
    /// previously tier-disabled. Counting those rows as "active" would
    /// re-trip the gate (`activeCount > maxProviders`), the prune loop
    /// would no-op (only 3 toggles enabled, all in keptKinds), and the
    /// banner count would resolve to 0 — so the user-facing surface is
    /// safe even today. The risk is rather that some future banner-
    /// adjacent logic (e.g. "show 'upgrade to keep all your providers'
    /// nudge while activeCount > maxProviders") could read the same
    /// gate and surface a misleading message.
    ///
    /// Requiring `isEnabled` on the usage branch resolves the asymmetry
    /// at the source: a tier-disabled provider's stale usage rows do
    /// NOT count as active. Pinned by `testStaleUsageRowsForDisabled
    /// ProvidersDoNotReactivateBanner` so this contract can't silently
    /// drift back.
    nonisolated static func activeKindsForMigrationBanner(
        providers: [ProviderUsage],
        providerConfigs: [ProviderConfig]
    ) -> Set<ProviderKind> {
        // Index enabled configs by kind so the usage-row pass can require
        // both signal AND user-enabled status in O(1) per row.
        let enabledKinds: Set<ProviderKind> = Set(
            providerConfigs.filter(\.isEnabled).map(\.kind)
        )
        var active = Set<ProviderKind>()
        for usage in providers {
            let hasUsage = usage.today_usage > 0
                || usage.week_usage > 0
                || usage.estimated_cost_today > 0
                || usage.estimated_cost_week > 0
            guard hasUsage else { continue }
            guard let kind = ProviderKind(rawValue: usage.provider) else { continue }
            // Defensive: tier-disabled providers' stale server rows must
            // NOT count toward active even if the row still carries
            // non-zero usage. See header comment for the call-graph
            // analysis behind this requirement.
            guard enabledKinds.contains(kind) else { continue }
            active.insert(kind)
        }
        for config in providerConfigs where config.isEnabled && config.hasCredentials {
            active.insert(config.kind)
        }
        return active
    }

    /// Dismiss the one-time migration banner on Overview.
    public func dismissProviderLimitMigrationBanner() {
        providerLimitMigrationCount = 0
    }

    /// Returns the set of provider kinds that were auto-disabled by the tier
    /// migration (not by user choice). Used by Settings → Providers to show
    /// a "Limited by free plan — upgrade" badge instead of a plain-off switch.
    public static func providersDisabledByTier() -> Set<ProviderKind> {
        let raw = UserDefaults.standard.stringArray(forKey: "cli_pulse_providers_disabled_by_tier") ?? []
        return Set(raw.compactMap(ProviderKind.init(rawValue:)))
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
        providerDetails = Self.computedProviderDetails(
            providers: providers,
            configs: providerConfigs,
            isLocalMode: isLocalMode,
            locallySupplementedProviders: locallySupplementedProviders
        )
    }

    /// Pure computation extracted from `buildProviderDetails()` for
    /// P1-6 characterization testing. Maps `(providers, configs,
    /// isLocalMode, locallySupplementedProviders)` to the ordered
    /// `[ProviderDetail]` that the instance-side method assigns to
    /// `self.providerDetails`.
    ///
    /// Same ordering contract: sorted by `config.sortOrder`, skipping
    /// configs with no matching provider usage.
    public nonisolated static func computedProviderDetails(
        providers: [ProviderUsage],
        configs: [ProviderConfig],
        isLocalMode: Bool,
        locallySupplementedProviders: Set<String>
    ) -> [ProviderDetail] {
        configs.sorted(by: { $0.sortOrder < $1.sortOrder }).compactMap { config in
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
                        resetTime: tier.reset_time,
                        windowMinutes: tier.windowMinutes
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

        // Must run BEFORE the loadSecrets() loop below: on macOS loadSecrets()
        // now reads from the shared app-group keychain, so any secrets still
        // living in the legacy no-group ACL must be re-homed first or the first
        // hydrate would return nil for existing users.
        migrateProviderSecretsToSharedGroup()

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

    /// One-time (macOS) migration of per-provider apiKey/cookie keychain items
    /// written before `keychain-access-groups` existed into the shared
    /// app-group keychain. This is what stops the LoginItem helper's recurring
    /// "wants to use information stored by ... in your keychain" consent prompt:
    /// once the secrets live in the shared group, the helper reads them
    /// prompt-free. Runs in the MAIN APP on its own items, so the migration
    /// reads themselves never prompt. iOS/watchOS keep secrets in the no-group
    /// keychain (no cross-process helper there), so this is macOS-only.
    private func migrateProviderSecretsToSharedGroup() {
        #if os(macOS)
        guard !UserDefaults.standard.bool(forKey: Self.keychainGroupMigratedKey) else { return }
        for kind in ProviderKind.allCases {
            KeychainHelper.migrateToSharedGroup(key: "cli_pulse_provider_\(kind.rawValue)_apiKey")
            KeychainHelper.migrateToSharedGroup(key: "cli_pulse_provider_\(kind.rawValue)_cookie")
        }
        UserDefaults.standard.set(true, forKey: Self.keychainGroupMigratedKey)
        #endif
    }
}
