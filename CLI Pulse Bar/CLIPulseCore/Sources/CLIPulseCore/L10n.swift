import Foundation

/// Type-safe localization helper for CLIPulseCore.
///
/// Usage:
///     Text(L10n.tab.overview)
///     Text(L10n.dashboard.updated(timeAgo))
///
public enum L10n {
    /// Fallback bundle when the runtime override is `nil` (system default).
    private static let bundle: Bundle = {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }()

    /// iter22: route through `LocaleOverrideStore` so the in-app
    /// language switcher (footer button on macOS) can swap the
    /// `.lproj` bundle at runtime. When `override == nil` the store
    /// returns the same default bundle, preserving prior behavior.
    private static func tr(_ key: String, _ args: CVarArg...) -> String {
        let activeBundle = LocaleOverrideStore.shared.bundle
        let format = NSLocalizedString(key, bundle: activeBundle, comment: "")
        return args.isEmpty ? format : String(format: format, arguments: args)
    }

    // MARK: - Tabs

    public enum tab {
        public static var overview: String { tr("tab.overview") }
        public static var providers: String { tr("tab.providers") }
        public static var sessions: String { tr("tab.sessions") }
        public static var swarm: String { tr("tab.swarm") }
        public static var alerts: String { tr("tab.alerts") }
        public static var settings: String { tr("tab.settings") }
    }

    // MARK: - Dashboard

    public enum dashboard {
        public static var title: String { tr("dashboard.title") }
        public static func updated(_ time: String) -> String { tr("dashboard.updated", time) }
        public static var serverOnline: String { tr("dashboard.server_online") }
        public static var serverOffline: String { tr("dashboard.server_offline") }
        public static var noData: String { tr("dashboard.no_data") }
        public static var connectHelper: String { tr("dashboard.connect_helper") }
        // iter17: dedicated empty-state copy for unauthenticated
        // local mode. iter18 moved this content into a richer
        // `LocalModeGuideCard` (see `localModeGuide` enum below) that
        // shows on Overview regardless of whether data is present.
        // These two keys are kept (still localised) but no longer
        // referenced from view code — preserved as a fallback string
        // pool for any future caller and to avoid orphaning .strings
        // entries already shipped on dev builds.
        public static var localModeReadyTitle: String { tr("dashboard.local_mode_ready_title") }
        public static var localModeReadyBody: String { tr("dashboard.local_mode_ready_body") }
        public static var usageToday: String { tr("dashboard.usage_today") }
        public static var costToday: String { tr("dashboard.cost_today") }
        public static var estCost: String { tr("dashboard.est_cost") }
        public static var requests: String { tr("dashboard.requests") }
        public static var activeSessions: String { tr("dashboard.active_sessions") }
        public static var onlineDevices: String { tr("dashboard.online_devices") }
        public static var unresolvedAlerts: String { tr("dashboard.unresolved_alerts") }
        public static var costSummary: String { tr("dashboard.cost_summary") }
        public static var today: String { tr("dashboard.today") }
        public static var thirtyDayEst: String { tr("dashboard.30day_est") }
        public static var providerUsage: String { tr("dashboard.provider_usage") }
        public static var topProjects: String { tr("dashboard.top_projects") }
        public static var noProjects: String { tr("dashboard.no_projects") }
        public static var riskSignals: String { tr("dashboard.risk_signals") }
        public static var activity: String { tr("dashboard.activity") }
        public static var quickStats: String { tr("dashboard.quick_stats") }
        public static var monitor: String { tr("dashboard.monitor") }
        public static var manage: String { tr("dashboard.manage") }
        public static var noUnresolvedAlerts: String { tr("dashboard.no_unresolved_alerts") }
        public static var exportCostReport: String { tr("dashboard.export_cost_report") }
        public static var exportSessions: String { tr("dashboard.export_sessions") }
        public static var exportProviders: String { tr("dashboard.export_providers") }
        public static var exportPdf: String { tr("dashboard.export_pdf") }
        public static var export: String { tr("dashboard.export") }
        public static var subscriptions: String { tr("dashboard.subscriptions") }
        public static var subscriptionUtilization: String { tr("dashboard.subscription_utilization") }
        public static var totalMonthly: String { tr("dashboard.total_monthly") }
        public static var noEnabledWithData: String { tr("dashboard.no_enabled_with_data") }
        public static var tapReviewClaude: String { tr("dashboard.tap_review_claude") }
        public static func pendingApprovalCount(_ count: Int) -> String { tr("dashboard.pending_approval_count", count) }
    }

    // MARK: - Providers

    public enum providers {
        public static var title: String { tr("providers.title") }
        public static var showAll: String { tr("providers.show_all") }
        public static var hideDisabled: String { tr("providers.hide_disabled") }
        public static var tracked: String { tr("providers.tracked") }
        public static var noProviders: String { tr("providers.no_providers") }
        public static var noData: String { tr("providers.no_data") }
        public static var emptyHint: String { tr("providers.empty_hint") }
        public static var allHidden: String { tr("providers.all_hidden") }
        public static var showAllHint: String { tr("providers.show_all_hint") }
        public static var searchPlaceholder: String { tr("providers.search_placeholder") }
        public static var noSearchMatch: String { tr("providers.no_search_match") }
        public static var thisWeek: String { tr("providers.this_week") }
        public static var quota: String { tr("providers.quota") }
        public static var status: String { tr("providers.status") }
        public static var configureHint: String { tr("providers.configure_hint") }
        public static func sourceLabel(_ source: String) -> String { tr("providers.source_label", source) }
        public static var keySet: String { tr("providers.key_set") }
        public static var limitedFree: String { tr("providers.limited_free") }
        public static var disabledBadge: String { tr("providers.disabled_badge") }
        public static var grantAccessTitle: String { tr("providers.grant_access_title") }
        public static var grantAccessBody: String { tr("providers.grant_access_body") }
        public static var openSettings: String { tr("providers.open_settings") }
        public static var quotaDataUnavailable: String { tr("providers.quota_data_unavailable") }
    }

    // MARK: - Remote Control Diagnostics

    public enum diagnostics {
        public static var title: String { tr("diagnostics.title") }
        public static var overallOk: String { tr("diagnostics.overall_ok") }
        public static var overallAttention: String { tr("diagnostics.overall_attention") }
        public static var copy: String { tr("diagnostics.copy") }

        public static var checkPaired: String { tr("diagnostics.check_paired") }
        public static var checkRemoteControl: String { tr("diagnostics.check_remote_control") }
        public static var checkMac: String { tr("diagnostics.check_mac") }
        public static var checkHelper: String { tr("diagnostics.check_helper") }
        public static var checkNotifications: String { tr("diagnostics.check_notifications") }
        public static var checkRealtime: String { tr("diagnostics.check_realtime") }

        public static var fixPaired: String { tr("diagnostics.fix_paired") }
        public static var fixRemoteControl: String { tr("diagnostics.fix_remote_control") }
        public static var fixMac: String { tr("diagnostics.fix_mac") }
        public static var fixHelper: String { tr("diagnostics.fix_helper") }
        public static var fixNotifications: String { tr("diagnostics.fix_notifications") }
        public static var fixRealtime: String { tr("diagnostics.fix_realtime") }
    }

    // MARK: - Sessions

    public enum sessions {
        public static var title: String { tr("sessions.title") }
        public static var select: String { tr("sessions.select") }
        public static var selectHint: String { tr("sessions.select_hint") }
        public static var noSessions: String { tr("sessions.no_sessions") }
        public static var emptyHint: String { tr("sessions.empty_hint") }
        public static var running: String { tr("sessions.running") }
        public static var details: String { tr("sessions.details") }
        public static func countRunning(_ count: Int) -> String { tr("sessions.count_running", count) }
    }

    // MARK: - Swarm View (v1.22 P0)

    public enum swarm {
        public static var title: String { tr("swarm.title") }
        public static var noSwarms: String { tr("swarm.no_swarms") }
        public static var emptyHint: String { tr("swarm.empty_hint") }
        public static var disabledHint: String { tr("swarm.disabled_hint") }
        public static var stale: String { tr("swarm.stale") }
        public static var worktree: String { tr("swarm.worktree") }
        public static var blockedBadge: String { tr("swarm.blocked_badge") }
        public static func agents(_ count: Int) -> String { tr("swarm.agents", count) }
        public static func blocked(_ count: Int) -> String { tr("swarm.blocked", count) }
        public static func lastSeen(_ ago: String) -> String { tr("swarm.last_seen", ago) }
        public static func oldestBlocked(_ ago: String) -> String { tr("swarm.oldest_blocked", ago) }
        public static func summary(_ swarms: Int, _ agents: Int, _ blocked: Int) -> String {
            tr("swarm.summary", swarms, agents, blocked)
        }
    }

    // MARK: - Alerts

    public enum alerts {
        public static var title: String { tr("alerts.title") }
        public static var allClear: String { tr("alerts.all_clear") }
        public static var noAlerts: String { tr("alerts.no_alerts") }
        public static var noUnresolved: String { tr("alerts.no_unresolved") }
        public static var noMatching: String { tr("alerts.no_matching") }
        public static var open: String { tr("alerts.open") }
        public static var resolved: String { tr("alerts.resolved") }
        public static var all: String { tr("alerts.all") }
        public static var filter: String { tr("alerts.filter") }
        public static var ack: String { tr("alerts.ack") }
        public static var acknowledge: String { tr("alerts.acknowledge") }
        public static var resolve: String { tr("alerts.resolve") }
        public static var snooze: String { tr("alerts.snooze") }
        public static func snoozeMinutes(_ minutes: Int) -> String { tr("alerts.snooze_minutes", minutes) }
        public static var created: String { tr("alerts.created") }
        public static var related: String { tr("alerts.related") }
        public static var actions: String { tr("alerts.actions") }
        public static var severityCritical: String { tr("alerts.severity_critical") }
        public static var severityWarning: String { tr("alerts.severity_warning") }
        public static func unresolvedCount(_ count: Int) -> String { tr("alerts.unresolved_count", count) }
        public static var resolveAll: String { tr("alerts.resolve_all") }
    }

    // MARK: - Settings

    public enum settings {
        public static var title: String { tr("settings.title") }
        public static var account: String { tr("settings.account") }
        public static var general: String { tr("settings.general") }
        public static var server: String { tr("settings.server") }
        public static var serverName: String { tr("settings.server_name") }
        public static var status: String { tr("settings.status") }
        public static var connected: String { tr("settings.connected") }
        public static var disconnected: String { tr("settings.disconnected") }
        public static var paired: String { tr("settings.paired") }
        public static var notPaired: String { tr("settings.not_paired") }
        public static var connection: String { tr("settings.connection") }
        public static var refreshCadence: String { tr("settings.refresh_cadence") }
        public static var refreshInterval: String { tr("settings.refresh_interval") }
        public static var subscription: String { tr("settings.subscription") }
        public static var currentPlan: String { tr("settings.current_plan") }
        public static var manageSubscription: String { tr("settings.manage_subscription") }
        public static var upgradePro: String { tr("settings.upgrade_pro") }
        public static var providers: String { tr("settings.providers") }
        public static var devices: String { tr("settings.devices") }
        public static var dataRetention: String { tr("settings.data_retention") }
        public static var days: String { tr("settings.days") }
        public static var notifications: String { tr("settings.notifications") }
        public static var desktopNotifications: String { tr("settings.desktop_notifications") }
        public static var desktopNotificationsHint: String { tr("settings.desktop_notifications_hint") }
        public static var sessionQuotaNotifications: String { tr("settings.session_quota_notifications") }
        public static var sessionQuotaHint: String { tr("settings.session_quota_hint") }
        public static var alertNotifications: String { tr("settings.alert_notifications") }
        public static var sessionQuotaAlerts: String { tr("settings.session_quota_alerts") }
        public static var checkProviderStatus: String { tr("settings.check_provider_status") }
        public static var costTracking: String { tr("settings.cost_tracking") }
        public static var display: String { tr("settings.display") }
        public static var showCostEstimates: String { tr("settings.show_cost_estimates") }
        public static var compactMode: String { tr("settings.compact_mode") }
        public static var menuBarMode: String { tr("settings.menu_bar_mode") }
        public static var reorderProviders: String { tr("settings.reorder_providers") }
        public static var reorderHint: String { tr("settings.reorder_hint") }
        public static var manageProviders: String { tr("settings.manage_providers") }
        public static var advanced: String { tr("settings.advanced") }
        public static var hidePersonalInfo: String { tr("settings.hide_personal_info") }
        public static var forceRefresh: String { tr("settings.force_refresh") }
        public static var about: String { tr("settings.about") }
        public static var version: String { tr("settings.version") }
        public static var build: String { tr("settings.build") }
        public static var privacyPolicy: String { tr("settings.privacy_policy") }
        public static var termsOfUse: String { tr("settings.terms_of_use") }
        public static var github: String { tr("settings.github") }
        public static var signOut: String { tr("settings.sign_out") }
        public static var signIn: String { tr("settings.sign_in") }
        public static var signInEmail: String { tr("settings.sign_in_email") }
        public static var signInHint: String { tr("settings.sign_in_hint") }
        public static var appearance: String { tr("settings.appearance") }
        public static var appearanceSystem: String { tr("settings.appearance_system") }
        public static var appearanceLight: String { tr("settings.appearance_light") }
        public static var appearanceDark: String { tr("settings.appearance_dark") }
        public static var email: String { tr("settings.email") }
        public static var name: String { tr("settings.name") }
        public static var showCostSummary: String { tr("settings.show_cost_summary") }
        public static var showCostSummaryHint: String { tr("settings.show_cost_summary_hint") }
        public static var autoPollStatus: String { tr("settings.auto_poll_status") }
        public static var quotaAlertThresholds: String { tr("settings.quota_alert_thresholds") }
        public static var quotaAlertThresholdsHint: String { tr("settings.quota_alert_thresholds_hint") }
        public static func warningPct(_ pct: Int) -> String { tr("settings.warning_pct", pct) }
        public static func criticalPct(_ pct: Int) -> String { tr("settings.critical_pct", pct) }
        public static func warningThresholdPct(_ pct: Int) -> String { tr("settings.warning_threshold_pct", pct) }
        public static func criticalThresholdPct(_ pct: Int) -> String { tr("settings.critical_threshold_pct", pct) }
        public static var resetThresholdsDefaults: String { tr("settings.reset_thresholds_defaults") }
        public static var reset: String { tr("settings.reset") }
        public static var privacy: String { tr("settings.privacy") }
        public static var testWebhook: String { tr("settings.test_webhook") }
        public static var remoteControl: String { tr("settings.remote_control") }
        public static var remoteControlIPhoneHint: String { tr("settings.remote_control_iphone_hint") }
        public static var pendingApprovals: String { tr("settings.pending_approvals") }
        public static var privacyRedactedHint: String { tr("settings.privacy_redacted_hint") }
    }

    // MARK: - Auth

    public enum auth {
        public static var title: String { tr("auth.title") }
        public static var subtitle: String { tr("auth.subtitle") }
        public static var or: String { tr("auth.or") }
        public static var tryDemo: String { tr("auth.try_demo") }
        public static var welcome: String { tr("auth.welcome") }
        public static var watchHint: String { tr("auth.watch_hint") }
        public static var sendCode: String { tr("auth.send_code") }
        public static var verifyCode: String { tr("auth.verify_code") }
        public static var enterCode: String { tr("auth.enter_code") }
        public static var codeSent: String { tr("auth.code_sent") }
        public static func codeSentTo(_ email: String) -> String { tr("auth.code_sent_to", email) }
        public static var resendCode: String { tr("auth.resend_code") }
        public static var backToEmail: String { tr("auth.back_to_email") }
        public static var codePlaceholder: String { tr("auth.code_placeholder") }
        public static var passwordOptional: String { tr("auth.password_optional") }
        public static var passwordPlaceholder: String { tr("auth.password_placeholder") }
        public static var signInGoogle: String { tr("auth.sign_in_google") }
        public static var signInGithub: String { tr("auth.sign_in_github") }
        public static var signInCancelled: String { tr("auth.sign_in_cancelled") }
        public static var signInFailedGeneric: String { tr("auth.sign_in_failed_generic") }
        public static var signInFailedStateMismatch: String { tr("auth.sign_in_failed_state_mismatch") }
        public static var linkCancelled: String { tr("auth.link_cancelled") }
        public static var linkFailedGeneric: String { tr("auth.link_failed_generic") }
        public static var linkFailedStateMismatch: String { tr("auth.link_failed_state_mismatch") }
        public static var passwordSignIn: String { tr("auth.password_sign_in") }
        public static var useEmailCode: String { tr("auth.use_email_code") }
        public static var usePassword: String { tr("auth.use_password") }
        public static var passwordLabel: String { tr("auth.password_label") }
        // iter14: minimum-friction escape from the macOS signed-out
        // SettingsTab. iter17 renamed the keys from
        // `continue_without_account` → `use_local_mode` to match the
        // upgraded semantics: the button now actually opts the user
        // into the unauthenticated local scanner path
        // (`AppState.continueWithoutAccount()`), not just a tab switch.
        public static var useLocalMode: String { tr("auth.use_local_mode") }
        public static var useLocalModeHint: String { tr("auth.use_local_mode_hint") }
        public static var watchPhonePrompt: String { tr("auth.watch_phone_prompt") }
        public static var watchPhoneUnreachable: String { tr("auth.watch_phone_unreachable") }
        public static var watchCompleteSignIn: String { tr("auth.watch_complete_sign_in") }
        public static var watchEmailFallback: String { tr("auth.watch_email_fallback") }
        public static var appleNoToken: String { tr("auth.apple_no_token") }
        public static var appleNonceFailed: String { tr("auth.apple_nonce_failed") }
    }

    // MARK: - Subscription

    public enum subscription {
        public static var title: String { tr("subscription.title") }
        public static var proTitle: String { tr("subscription.pro_title") }
        public static var unlock: String { tr("subscription.unlock") }
        public static var monthly: String { tr("subscription.monthly") }
        public static var yearlySave: String { tr("subscription.yearly_save") }
        public static var popular: String { tr("subscription.popular") }
        public static var notAvailable: String { tr("subscription.not_available") }
        public static var restore: String { tr("subscription.restore") }
        public static var free: String { tr("subscription.free") }
        public static var pro: String { tr("subscription.pro") }
        public static var team: String { tr("subscription.team") }
        public static var freeDescription: String { tr("subscription.free_description") }
        public static var proDescription: String { tr("subscription.pro_description") }
        public static var teamDescription: String { tr("subscription.team_description") }
        public static var everythingInPro: String { tr("subscription.everything_in_pro") }
        public static var unlimitedDevices: String { tr("subscription.unlimited_devices") }
        public static var dataRetention365: String { tr("subscription.data_retention_365") }
        public static var teamDashboards: String { tr("subscription.team_dashboards") }
        public static var sharedAlerts: String { tr("subscription.shared_alerts") }
        public static var adminControls: String { tr("subscription.admin_controls") }
        public static var unlimitedProviders: String { tr("subscription.unlimited_providers") }
        public static var upTo5Devices: String { tr("subscription.up_to_5_devices") }
        public static var dataRetention90: String { tr("subscription.data_retention_90") }
        public static var priorityAlerts: String { tr("subscription.priority_alerts") }
        public static var costAnalytics: String { tr("subscription.cost_analytics") }
        public static var perYear: String { tr("subscription.per_year") }
        public static var perMonth: String { tr("subscription.per_month") }
        public static var upgradePro: String { tr("subscription.upgrade_pro") }
        public static var switchPro: String { tr("subscription.switch_pro") }
        public static var switchTeam: String { tr("subscription.switch_team") }
        public static var loadingPlans: String { tr("subscription.loading_plans") }
        public static var unavailable: String { tr("subscription.unavailable") }
        public static var retry: String { tr("subscription.retry") }
        public static var viewAllPlans: String { tr("subscription.view_all_plans") }
        public static var billing: String { tr("subscription.billing") }
        // v1.14: Pro Lifetime IAP strings
        public static var lifetime: String { tr("subscription.lifetime") }
        public static var lifetimeDescription: String { tr("subscription.lifetime_description") }
        public static var lifetimeOwned: String { tr("subscription.lifetime_owned") }
        public static var oneTime: String { tr("subscription.one_time") }
        public static var oneTimeBadge: String { tr("subscription.one_time_badge") }
        public static var buyLifetime: String { tr("subscription.buy_lifetime") }
    }

    // MARK: - About

    public enum about {
        public static var title: String { tr("about.title") }
        public static var description: String { tr("about.description") }
        public static var copyright: String { tr("about.copyright") }
        public static var reportIssue: String { tr("about.report_issue") }
    }

    // MARK: - Widgets

    public enum widget {
        public static var usageTitle: String { tr("widget.usage_title") }
        public static var usageDescription: String { tr("widget.usage_description") }
        public static var overviewTitle: String { tr("widget.overview_title") }
        public static var overviewDescription: String { tr("widget.overview_description") }
        public static var appName: String { tr("widget.app_name") }
        public static var noData: String { tr("widget.no_data") }
        public static var noProviderData: String { tr("widget.no_provider_data") }
        public static var used: String { tr("widget.used") }
        public static var signInToView: String { tr("widget.sign_in_to_view") }
        public static func alertsSummary(_ count: Int) -> String { tr("widget.alerts_summary", count) }
        public static func percentLeft(_ name: String, _ pct: Int) -> String { tr("widget.percent_left", name, pct) }
        public static var quotaFallback: String { tr("widget.quota_fallback") }
    }

    // MARK: - Time

    public enum time {
        public static var justNow: String { tr("time.just_now") }
        public static var ago: String { tr("time.ago") }
    }

    // MARK: - Account

    public enum account {
        public static var deleteAccount: String { tr("account.delete_account") }
        public static var deleteConfirmTitle: String { tr("account.delete_confirm_title") }
        public static var deleteConfirmMessage: String { tr("account.delete_confirm_message") }
        public static var unlimited: String { tr("account.unlimited") }
        public static var linkedAccounts: String { tr("account.linked_accounts") }
        public static var linkedAccountsFooter: String { tr("account.linked_accounts_footer") }
        public static var unlinkConfirmTitle: String { tr("account.unlink_confirm_title") }
        public static func unlinkWithProvider(_ provider: String) -> String { tr("account.unlink_with_provider", provider) }
        public static func unlinkMessage(_ provider: String) -> String { tr("account.unlink_message", provider) }
        public static var linkedStatus: String { tr("account.linked_status") }
        public static var notLinkedStatus: String { tr("account.not_linked_status") }
        public static var unlink: String { tr("account.unlink") }
        public static var link: String { tr("account.link") }
        public static var deleteLongMessage: String { tr("account.delete_long_message") }
        public static var deleteContinue: String { tr("account.delete_continue") }
        public static var deleteConfirmStepTitle: String { tr("account.delete_confirm_step_title") }
        public static var deleteConfirmPlaceholder: String { tr("account.delete_confirm_placeholder") }
        public static var deleteConfirmButton: String { tr("account.delete_confirm_button") }
        public static var deleteConfirmStepMessage: String { tr("account.delete_confirm_step_message") }
        // iter10: shown when the delete-account RPC fails on the server.
        public static var deleteFailedTitle: String { tr("account.delete_failed_title") }
        public static var deleteFailedGeneric: String { tr("account.delete_failed_generic") }
        // iter11: shown after the delete-account flow detects a dead
        // session and signs the user out. Surfaced on the login screen
        // (via state.lastError) so the user understands why they were
        // bounced and what to do next.
        public static var deleteSessionExpired: String { tr("account.delete_session_expired") }
    }

    // MARK: - Session Details

    public enum detail {
        public static var provider: String { tr("detail.provider") }
        public static var project: String { tr("detail.project") }
        public static var device: String { tr("detail.device") }
        public static var started: String { tr("detail.started") }
        public static var usage: String { tr("detail.usage") }
        public static var cost: String { tr("detail.cost") }
        public static var requests: String { tr("detail.requests") }
        public static var errors: String { tr("detail.errors") }
        public static var remaining: String { tr("detail.remaining") }
        public static func remainingValue(_ value: String) -> String { tr("detail.remaining_value", value) }
        public static func usageToday(_ value: String) -> String { tr("detail.usage_today", value) }
    }

    // MARK: - Quota Status

    public enum quota {
        public static var low: String { tr("quota.low") }
        public static var moderate: String { tr("quota.moderate") }
        public static var ok: String { tr("quota.ok") }
    }

    // MARK: - Login Placeholders

    public enum login {
        public static var emailPlaceholder: String { tr("login.email_placeholder") }
        public static var namePlaceholder: String { tr("login.name_placeholder") }
    }

    // MARK: - Display Mode

    public enum display {
        public static var icon: String { tr("display.icon") }
        public static var percent: String { tr("display.percent") }
        public static var pace: String { tr("display.pace") }
        public static var mostUsed: String { tr("display.most_used") }
        public static var mode: String { tr("display.mode") }
        public static var mergeMenuBarIcons: String { tr("display.merge_menu_bar_icons") }
        public static var mergeMenuBarHint: String { tr("display.merge_menu_bar_hint") }
        public static var contentMode: String { tr("display.content_mode") }
        public static var reorderHint: String { tr("display.reorder_hint") }
    }

    // MARK: - Status

    public enum status {
        public static var running: String { tr("status.running") }
        public static var idle: String { tr("status.idle") }
        public static var failed: String { tr("status.failed") }
        public static var syncing: String { tr("status.syncing") }
        public static var online: String { tr("status.online") }
        public static var offline: String { tr("status.offline") }
        public static var degraded: String { tr("status.degraded") }
        public static var operational: String { tr("status.operational") }
        public static var down: String { tr("status.down") }
        public static var disabled: String { tr("status.disabled") }
        public static var ended: String { tr("status.ended") }

        /// Map a server status string to its localized display text.
        public static func localized(_ raw: String) -> String {
            switch raw {
            case "Running", "running": return running
            case "Idle", "idle": return idle
            case "Failed", "failed": return failed
            case "Syncing", "syncing": return syncing
            case "Online", "online": return online
            case "Offline", "offline": return offline
            case "Degraded", "degraded": return degraded
            case "Operational", "operational": return operational
            case "Down", "down": return down
            case "Disabled", "disabled": return disabled
            case "Ended", "ended": return ended
            default: return raw
            }
        }
    }

    // MARK: - Badges

    public enum badge {
        public static var free: String { tr("badge.free") }
        public static var pro: String { tr("badge.pro") }
        public static var team: String { tr("badge.team") }
        public static var exact: String { tr("badge.exact") }
        public static var estimated: String { tr("badge.estimated") }
        public static var unavailable: String { tr("badge.unavailable") }
        public static var high: String { tr("badge.high") }
        public static var medium: String { tr("badge.medium") }
        public static var low: String { tr("badge.low") }
        public static var cloud: String { tr("badge.cloud") }
        public static var local: String { tr("badge.local") }
        public static var aggregator: String { tr("badge.aggregator") }
        public static var ide: String { tr("badge.ide") }
    }

    // MARK: - Local Mode Guide (iter18)

    /// Shown on the macOS Overview tab when the user is in
    /// unauthenticated local mode (post-iter17 "Use local mode"
    /// entry). See `LocalModeGuideCard.swift` for the rendered view.
    public enum localModeGuide {
        public static var title: String { tr("local_mode_guide.title") }
        public static var body: String { tr("local_mode_guide.body") }
        public static var bullet1: String { tr("local_mode_guide.bullet1") }
        public static var bullet2: String { tr("local_mode_guide.bullet2") }
        public static var bullet3: String { tr("local_mode_guide.bullet3") }
        public static var signInCTA: String { tr("local_mode_guide.sign_in_cta") }
    }

    // MARK: - Welcome Mode Choice (iter19)

    /// Shown on the macOS Overview tab when the user has neither
    /// authenticated nor explicitly chosen local mode. See
    /// `WelcomeModeChoice.swift` for the rendered view.
    public enum welcomeChoice {
        public static var title: String { tr("welcome_choice.title") }
        public static var subtitle: String { tr("welcome_choice.subtitle") }
        public static var signInTitle: String { tr("welcome_choice.sign_in_title") }
        public static var signInBody: String { tr("welcome_choice.sign_in_body") }
        public static var localModeTitle: String { tr("welcome_choice.local_mode_title") }
        public static var localModeBody: String { tr("welcome_choice.local_mode_body") }
        public static var footnote: String { tr("welcome_choice.footnote") }
    }

    // MARK: - Onboarding / Sync Setup

    public enum onboarding {
        public static var howItWorks: String { tr("onboarding.how_it_works") }
        public static var cloudSyncTitle: String { tr("onboarding.cloud_sync_title") }
        public static var cloudSyncDesc: String { tr("onboarding.cloud_sync_desc") }
        public static var notBluetooth: String { tr("onboarding.not_bluetooth") }
        public static var setupStepsTitle: String { tr("onboarding.setup_steps_title") }
        public static var step1Mac: String { tr("onboarding.step1_mac") }
        public static var step2Helper: String { tr("onboarding.step2_helper") }
        public static var step3Phone: String { tr("onboarding.step3_phone") }
        public static var localModeTitle: String { tr("onboarding.local_mode_title") }
        public static var localModeDesc: String { tr("onboarding.local_mode_desc") }
        public static var cloudModeTitle: String { tr("onboarding.cloud_mode_title") }
        public static var cloudModeDesc: String { tr("onboarding.cloud_mode_desc") }
        public static var iosWaiting: String { tr("onboarding.ios_waiting") }
        public static var iosWaitingDesc: String { tr("onboarding.ios_waiting_desc") }
        public static var checkSync: String { tr("onboarding.check_sync") }
        public static var setUpSync: String { tr("onboarding.set_up_sync") }
        public static var syncedMode: String { tr("onboarding.synced_mode") }
        public static var notSyncedHint: String { tr("onboarding.not_synced_hint") }
        public static var helperNotConnectedYet: String { tr("onboarding.helper_not_connected_yet") }
    }

    // MARK: - Common

    // MARK: - Team

    public enum team {
        public static var title: String { tr("team.title") }
        public static var requiresProHint: String { tr("team.requires_pro_hint") }
        public static var noTeams: String { tr("team.no_teams") }
        public static var members: String { tr("team.members") }
        public static var pendingInvites: String { tr("team.pending_invites") }
        public static var pending: String { tr("team.pending") }
        public static var invite: String { tr("team.invite") }
        public static var makeAdmin: String { tr("team.make_admin") }
        public static var makeMember: String { tr("team.make_member") }
        public static var remove: String { tr("team.remove") }
        public static var createTeam: String { tr("team.create_team") }
        public static var teamName: String { tr("team.team_name") }
        public static var create: String { tr("team.create") }
        public static var inviteMember: String { tr("team.invite_member") }
        public static var emailAddress: String { tr("team.email_address") }
        public static var sendInvite: String { tr("team.send_invite") }
        public static func membersCount(_ count: Int) -> String { tr("team.members_count", count) }
        public static func tokensCount(_ count: Int) -> String { tr("team.tokens_count", count) }
        public static var errorLoading: String { tr("team.error_loading") }
    }

    // MARK: - Integrations

    public enum integrations {
        public static var title: String { tr("integrations.title") }
        public static var webhookNotifications: String { tr("integrations.webhook_notifications") }
        public static var webhookHint: String { tr("integrations.webhook_hint") }
        public static var webhookURLPlaceholder: String { tr("integrations.webhook_url_placeholder") }
        public static var testWebhook: String { tr("integrations.test_webhook") }
        public static var eventFilter: String { tr("integrations.event_filter") }
        public static var eventFilterHint: String { tr("integrations.event_filter_hint") }
        public static var filterSeverities: String { tr("integrations.filter_severities") }
        public static var filterTypes: String { tr("integrations.filter_types") }
        public static var filterProviders: String { tr("integrations.filter_providers") }
        public static var filterAll: String { tr("integrations.filter_all") }
    }

    // MARK: - Forecast

    public enum forecast {
        public static var title: String { tr("forecast.title") }
        public static var monthEnd: String { tr("forecast.month_end") }
        public static var soFar: String { tr("forecast.so_far") }
        public static var confidence: String { tr("forecast.confidence") }
        public static var estimate: String { tr("forecast.estimate") }
        public static var insufficientData: String { tr("forecast.insufficient_data") }
    }

    // MARK: - Common

    public enum common {
        public static var online: String { tr("common.online") }
        public static var offline: String { tr("common.offline") }
        public static var refreshAll: String { tr("common.refresh_all") }
        public static var cancel: String { tr("common.cancel") }
        public static var done: String { tr("common.done") }
        public static var save: String { tr("common.save") }
        public static var delete: String { tr("common.delete") }
        public static var enabled: String { tr("common.enabled") }
        public static var today: String { tr("common.today") }
        public static var noData: String { tr("common.no_data") }
        public static var navigation: String { tr("common.navigation") }
        public static var data: String { tr("common.data") }
        public static var refresh: String { tr("common.refresh") }
        // iter10: dismiss button on simple notice/error alerts.
        public static var ok: String { tr("common.ok") }
        public static var retry: String { tr("common.retry") }
        public static var close: String { tr("common.close") }
        public static var disconnect: String { tr("common.disconnect") }
        public static var noProviderSelected: String { tr("common.no_provider_selected") }
    }

    // MARK: - Cost Section (iter22)

    public enum cost {
        public static var exact: String { tr("cost.exact") }
        public static var estimated: String { tr("cost.estimated") }
        public static func tokensSuffix(_ value: String) -> String { tr("cost.tokens_suffix", value) }
        public static func tokensShortSuffix(_ value: String) -> String { tr("cost.tokens_short_suffix", value) }
        public static var thirtyDayPrecise: String { tr("cost.thirty_day_precise") }
        public static func tokensValue(_ value: String) -> String { tr("cost.tokens_value", value) }
        public static func dayProgress(_ current: Int, _ total: Int) -> String { tr("cost.day_progress", current, total) }
        public static var byModel: String { tr("cost.by_model") }
    }

    // MARK: - PDF Report (CLIPulseCore shared generator)

    public enum pdf {
        public static var title: String { tr("pdf.title") }
        public static func generated(_ date: String) -> String { tr("pdf.generated", date) }
        public static var summary: String { tr("pdf.summary") }
        public static var todayUsage: String { tr("pdf.today_usage") }
        public static var todayEstimatedCost: String { tr("pdf.today_estimated_cost") }
        public static var activeSessions: String { tr("pdf.active_sessions") }
        public static var onlineDevices: String { tr("pdf.online_devices") }
        public static var unresolvedAlerts: String { tr("pdf.unresolved_alerts") }
        public static var costForecast: String { tr("pdf.cost_forecast") }
        public static var monthEndEstimate: String { tr("pdf.month_end_estimate") }
        public static var spentSoFar: String { tr("pdf.spent_so_far") }
        public static var confidenceRange: String { tr("pdf.confidence_range") }
        public static var progress: String { tr("pdf.progress") }
        public static func progressValue(_ current: Int, _ total: Int) -> String { tr("pdf.progress_value", current, total) }
        public static var providerBreakdown: String { tr("pdf.provider_breakdown") }
        public static var hProvider: String { tr("pdf.h_provider") }
        public static var hWeekUsage: String { tr("pdf.h_week_usage") }
        public static var hEstCost: String { tr("pdf.h_est_cost") }
        public static var hRemaining: String { tr("pdf.h_remaining") }
        public static var hQuota: String { tr("pdf.h_quota") }
        public static var na: String { tr("pdf.na") }
        public static var topSessions: String { tr("pdf.top_sessions") }
        public static var hProject: String { tr("pdf.h_project") }
        public static var hCost: String { tr("pdf.h_cost") }
        public static var hUsage: String { tr("pdf.h_usage") }
        public static var hStatus: String { tr("pdf.h_status") }
        public static var dailyTrend: String { tr("pdf.daily_trend") }
        public static func footer(_ version: String, _ date: String) -> String { tr("pdf.footer", version, date) }
    }

    // MARK: - Folder Access (CLIPulseCore FolderAccessView)

    public enum folderAccess {
        public static var title: String { tr("folder_access.title") }
        public static var intro: String { tr("folder_access.intro") }
        public static var granted: String { tr("folder_access.granted") }
        public static var notInstalled: String { tr("folder_access.not_installed") }
        public static var grant: String { tr("folder_access.grant") }
        public static var grantAll: String { tr("folder_access.grant_all") }
        public static var rescanTitle: String { tr("folder_access.rescan_title") }
        public static var rescanDetail: String { tr("folder_access.rescan_detail") }
        public static var forceRescan: String { tr("folder_access.force_rescan") }
        public static var panelMessage: String { tr("folder_access.panel_message") }
        public static var panelPrompt: String { tr("folder_access.panel_prompt") }
        // v1.28: prominent Overview banner shown to SIGNED-IN users whose local
        // usage scan is empty because the App Store sandbox lacks a folder grant.
        public static var bannerTitle: String { tr("folder_access.banner_title") }
        public static var bannerBody: String { tr("folder_access.banner_body") }
    }

    // MARK: - Provider Configuration

    public enum providerConfig {
        public static var dataSource: String { tr("provider_config.data_source") }
        public static var accountLabel: String { tr("provider_config.account_label") }
        public static var accountPlaceholder: String { tr("provider_config.account_placeholder") }
        public static var apiKey: String { tr("provider_config.api_key") }
        public static var showKey: String { tr("provider_config.show_key") }
        public static var hideKey: String { tr("provider_config.hide_key") }
        public static var keychainNotice: String { tr("provider_config.keychain_notice") }
        public static var cookieSource: String { tr("provider_config.cookie_source") }
        public static var manualCookieHeader: String { tr("provider_config.manual_cookie_header") }
        public static var autoImportNote: String { tr("provider_config.auto_import_note") }
        public static var autoImportFailed: String { tr("provider_config.auto_import_failed") }
        public static var capabilities: String { tr("provider_config.capabilities") }
        public static var capQuota: String { tr("provider_config.cap_quota") }
        public static var capExactCost: String { tr("provider_config.cap_exact_cost") }
        public static var capCredits: String { tr("provider_config.cap_credits") }
        public static var capStatusPoll: String { tr("provider_config.cap_status_poll") }
        public static var requiresHelperSync: String { tr("provider_config.requires_helper_sync") }
        public static var googleOAuth: String { tr("provider_config.google_oauth") }
        public static var disconnect: String { tr("provider_config.disconnect") }
        public static var connectGemini: String { tr("provider_config.connect_gemini") }
        public static var geminiUsesGoogle: String { tr("provider_config.gemini_uses_google") }
        // v1.23.0 G3 follow-on — CLI-probe fallback opt-in (macOS,
        // non-MAS). en/ja/zh-Hans coverage matches the rest of the
        // provider_config editor section (Phase-A G1 convention).
        public static var geminiCliFallback: String { tr("provider_config.gemini_cli_fallback") }
        public static var geminiCliFallbackNote: String { tr("provider_config.gemini_cli_fallback_note") }
        public static var claudeCode: String { tr("provider_config.claude_code") }
        public static var connectClaudeCode: String { tr("provider_config.connect_claude_code") }
        public static var claudeKeychainHint: String { tr("provider_config.claude_keychain_hint") }
        public static var claudeReadFailed: String { tr("provider_config.claude_read_failed") }
        public static var testConnection: String { tr("provider_config.test_connection") }
        public static var testing: String { tr("provider_config.testing") }
    }

    // MARK: - Onboarding Wizard

    public enum onboardingWizard {
        public static var welcomeTitle: String { tr("onboarding_wizard.welcome_title") }
        public static var welcomeSubtitle: String { tr("onboarding_wizard.welcome_subtitle") }
        public static var getStarted: String { tr("onboarding_wizard.get_started") }
        public static var whatDoes: String { tr("onboarding_wizard.what_does") }
        public static var `continue`: String { tr("onboarding_wizard.continue") }
        public static var back: String { tr("onboarding_wizard.back") }
        public static var privacyTitle: String { tr("onboarding_wizard.privacy_title") }
        public static var privacyBody: String { tr("onboarding_wizard.privacy_body") }
        public static var signInTitle: String { tr("onboarding_wizard.sign_in_title") }
        public static var signInSubtitle: String { tr("onboarding_wizard.sign_in_subtitle") }
        public static var skip: String { tr("onboarding_wizard.skip") }
        public static func codeSentTo(_ email: String) -> String { tr("onboarding_wizard.code_sent_to", email) }
        public static var verify: String { tr("onboarding_wizard.verify") }
        public static var backToEmail: String { tr("onboarding_wizard.back_to_email") }
        public static var allSetTitle: String { tr("onboarding_wizard.all_set_title") }
        public static var allSetBody: String { tr("onboarding_wizard.all_set_body") }
        public static var helperHint: String { tr("onboarding_wizard.helper_hint") }
        public static var done: String { tr("onboarding_wizard.done") }
        public static var close: String { tr("onboarding_wizard.close") }
        public static var privacyKeysTitle: String { tr("onboarding_wizard.privacy_keys_title") }
        public static var privacyKeysDetail: String { tr("onboarding_wizard.privacy_keys_detail") }
        public static var privacyLogsTitle: String { tr("onboarding_wizard.privacy_logs_title") }
        public static var privacyLogsDetail: String { tr("onboarding_wizard.privacy_logs_detail") }
        public static var privacyMetricsTitle: String { tr("onboarding_wizard.privacy_metrics_title") }
        public static var privacyMetricsDetail: String { tr("onboarding_wizard.privacy_metrics_detail") }
    }

    // MARK: - Advanced Settings

    public enum advanced {
        public static var launchAtLogin: String { tr("advanced.launch_at_login") }
        public static var backgroundSync: String { tr("advanced.background_sync") }
        public static var backgroundSyncHint: String { tr("advanced.background_sync_hint") }
        public static var fullDetails: String { tr("advanced.full_details") }
        public static var hideEmails: String { tr("advanced.hide_emails") }
        public static var trackGit: String { tr("advanced.track_git") }
        public static var trackGitHint: String { tr("advanced.track_git_hint") }
        public static var gitConsentTitle: String { tr("advanced.git_consent_title") }
        public static var enable: String { tr("advanced.enable") }
        public static var gitConsentBody: String { tr("advanced.git_consent_body") }
        public static var remoteControl: String { tr("advanced.remote_control") }
        public static var remoteControlHint: String { tr("advanced.remote_control_hint") }
        public static var remoteConsentTitle: String { tr("advanced.remote_consent_title") }
        // v1.21 D7: privacy-critical consent body — promises about what data
        // leaves the device when Remote Control is on. Per Gemini round 1
        // this MUST be human-translated before ASC re-submit; do not machine
        // translate non-en keys. en + zh-Hans landed in v1.21; es/ja/ko
        // intentionally still emit English (fallback) pending review.
        public static var remoteConsentBody: String { tr("advanced.remote_consent_body") }
        public static var token: String { tr("advanced.token") }
        public static var providersLoaded: String { tr("advanced.providers_loaded") }
        public static var lastRefresh: String { tr("advanced.last_refresh") }
        public static var never: String { tr("advanced.never") }
        public static var syncJustNow: String { tr("advanced.sync_just_now") }
        public static func syncMinutesAgo(_ minutes: Int) -> String { tr("advanced.sync_minutes_ago", minutes) }
        public static var helperRunning: String { tr("advanced.helper_running") }
        public static var helperNotRunning: String { tr("advanced.helper_not_running") }
        public static var privacyKeysTitle: String { tr("advanced.privacy_keys_title") }
        public static var privacyKeysDetail: String { tr("advanced.privacy_keys_detail") }
        public static var privacyLogsTitle: String { tr("advanced.privacy_logs_title") }
        public static var privacyLogsDetail: String { tr("advanced.privacy_logs_detail") }
        public static var privacyMetricsTitle: String { tr("advanced.privacy_metrics_title") }
        public static var privacyMetricsDetail: String { tr("advanced.privacy_metrics_detail") }
        public static var privacyEmailTitle: String { tr("advanced.privacy_email_title") }
        public static var privacyEmailDetail: String { tr("advanced.privacy_email_detail") }
    }

    // MARK: - Remote Approvals

    public enum remoteApprovals {
        public static var title: String { tr("remote_approvals.title") }
        public static var disabledHint: String { tr("remote_approvals.disabled_hint") }
        public static var refresh: String { tr("remote_approvals.refresh") }
        public static var close: String { tr("remote_approvals.close") }
        public static var offTitle: String { tr("remote_approvals.off_title") }
        public static var offBodyMac: String { tr("remote_approvals.off_body_mac") }
        public static var offBodyIos: String { tr("remote_approvals.off_body_ios") }
        public static var openSettings: String { tr("remote_approvals.open_settings") }
        public static var noPending: String { tr("remote_approvals.no_pending") }
        public static var updatedPrefix: String { tr("remote_approvals.updated_prefix") }
        public static var perRequestNoteMac: String { tr("remote_approvals.per_request_note_mac") }
        public static var perRequestNoteIos: String { tr("remote_approvals.per_request_note_ios") }
        public static var deny: String { tr("remote_approvals.deny") }
        public static var approve: String { tr("remote_approvals.approve") }
        public static var highRiskWarning: String { tr("remote_approvals.high_risk_warning") }
        public static func pendingCount(_ count: Int) -> String { tr("remote_approvals.pending_count", count) }
        public static var unknownTool: String { tr("remote_approvals.unknown_tool") }
        public static var noSummary: String { tr("remote_approvals.no_summary") }
        public static func expires(_ value: String) -> String { tr("remote_approvals.expires", value) }
        public static var entryLabelNone: String { tr("remote_approvals.entry_label_none") }
        public static func entryLabelWithCount(_ count: Int) -> String { tr("remote_approvals.entry_label_with_count", count) }
        public static var entryHelpNone: String { tr("remote_approvals.entry_help_none") }
        public static func entryHelpWithCount(_ count: Int) -> String { tr("remote_approvals.entry_help_with_count", count) }
    }

    // MARK: - Language Switcher (iter22)

    public enum language {
        public static var title: String { tr("language.title") }
        public static var systemDefault: String { tr("language.system_default") }
    }

    // MARK: - Yield Score

    public enum yield {
        public static var title: String { tr("yield.title") }
        public static var helpEstimated: String { tr("yield.help_estimated") }
        public static var emptyBody: String { tr("yield.empty_body") }
        public static var emptyEnableHint: String { tr("yield.empty_enable_hint") }
        public static var viewDetail: String { tr("yield.view_detail") }
        public static var detailTitle: String { tr("yield.detail_title") }
        public static var detailBody: String { tr("yield.detail_body") }
        public static var noCommits: String { tr("yield.no_commits") }
        public static var estimatedBadge: String { tr("yield.estimated_badge") }
        public static var rangePicker: String { tr("yield.range_picker") }
        public static var emptyNoAttribution: String { tr("yield.empty_no_attribution") }
        public static func detailSubtitle(_ rangeLabel: String) -> String { tr("yield.detail_subtitle", rangeLabel) }
        public static func commitsCount(_ count: Int) -> String { tr("yield.commits_count", count) }
        public static func commitsCountDecimal(_ count: Double) -> String { tr("yield.commits_count_decimal", count) }
        public static func ambiguousCount(_ count: Int) -> String { tr("yield.ambiguous_count", count) }
    }

    // MARK: - Menu Bar

    public enum menuBar {
        public static func tierMigration(kept: Int, disabled: Int) -> String {
            tr("menu_bar.tier_migration", kept, disabled)
        }
        public static var edit: String { tr("menu_bar.edit") }
        public static func appVersion(_ version: String) -> String { tr("menu_bar.app_version", version) }
        public static var quit: String { tr("menu_bar.quit") }
        public static var quitFull: String { tr("menu_bar.quit_full") }
    }

    // MARK: - Pairing

    public enum pairing {
        public static var helperIntro: String { tr("pairing.helper_intro") }
        public static var setUpHelper: String { tr("pairing.set_up_helper") }
        public static var manualSetup: String { tr("pairing.manual_setup") }
        public static var yourCode: String { tr("pairing.your_code") }
        public static var copy: String { tr("pairing.copy") }
    }

    // MARK: - Watch

    public enum watch {
        public static var couldntLoadData: String { tr("watch.couldnt_load_data") }
        public static var couldntLoadProviders: String { tr("watch.couldnt_load_providers") }
        public static var retry: String { tr("watch.retry") }
        public static var pullToRefresh: String { tr("watch.pull_to_refresh") }
        public static func unreadCount(_ count: Int) -> String { tr("watch.unread_count", count) }
        public static var snooze15: String { tr("watch.snooze_15") }
        public static var snooze30: String { tr("watch.snooze_30") }
        public static var snooze60: String { tr("watch.snooze_60") }
        // Redesign — Pulse home (P1)
        public static var pulseLabel: String { tr("watch.pulse_label") }
        public static func todayTokens(_ value: String) -> String { tr("watch.today_tokens", value) }
        public static var toggleCostHint: String { tr("watch.toggle_cost_hint") }
        public static func sessionsCount(_ count: Int) -> String { tr("watch.sessions_count", count) }
        public static func devicesCount(_ count: Int) -> String { tr("watch.devices_count", count) }
        public static func alertsCount(_ count: Int) -> String { tr("watch.alerts_count", count) }
        // Redesign — Quota rings (P2)
        public static func providerLeft(_ name: String) -> String { tr("watch.provider_left", name) }
        public static func activeCount(_ count: Int) -> String { tr("watch.active_count", count) }
        public static var remaining: String { tr("watch.remaining") }
        public static var errors: String { tr("watch.errors") }
        // Redesign — Live sessions (P3)
        public static var live: String { tr("watch.live") }
        // Quota countdown tier bars (5h / Weekly)
        public static func percentLeft(_ pct: Int) -> String { tr("watch.percent_left", pct) }
    }

    /// v1.10 P3-2: accessibility labels for icon-only controls and
    /// compound views. Kept in a dedicated namespace so the P3-3
    /// accessibility pass has a single place to add VoiceOver strings
    /// without polluting `common` or per-screen namespaces.
    public enum a11y {
        public static var dismissError: String { tr("a11y.dismiss_error") }
        public static var dismissTierWarning: String { tr("a11y.dismiss_tier_warning") }
        public static func configureProvider(_ name: String) -> String {
            tr("a11y.configure_provider", name)
        }
        public static var configurationErrorTitle: String { tr("a11y.configuration_error_title") }
        public static var configurationErrorBody: String { tr("a11y.configuration_error_body") }
    }

    // CodexBar-parity Phase A / G4 — pace/forecast text. en-only this
    // train (D2); other locales land with the UI consumer follow-on.
    public enum usagePace {
        public static var onTrack: String { tr("usage_pace.on_track") }
        public static func inDeficit(_ delta: String) -> String { tr("usage_pace.in_deficit", delta) }
        public static func inReserve(_ delta: String) -> String { tr("usage_pace.in_reserve", delta) }
        public static var lastsUntilReset: String { tr("usage_pace.lasts_until_reset") }
        public static var runsOutNow: String { tr("usage_pace.runs_out_now") }
        public static func runsOutIn(_ duration: String) -> String { tr("usage_pace.runs_out_in", duration) }
        public static var projectedEmptyNow: String { tr("usage_pace.projected_empty_now") }
        public static func projectedEmptyIn(_ duration: String) -> String { tr("usage_pace.projected_empty_in", duration) }
        public static func runOutRisk(_ percent: String) -> String { tr("usage_pace.run_out_risk", percent) }
        public static func summaryWithRight(_ left: String, _ right: String) -> String {
            tr("usage_pace.summary_with_right", left, right)
        }
        public static func summaryLeftOnly(_ left: String) -> String {
            tr("usage_pace.summary_left_only", left)
        }
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
