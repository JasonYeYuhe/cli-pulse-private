import SwiftUI
import CLIPulseCore

struct iOSMainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            if !SupabaseConstants.isConfigured {
                configurationErrorBanner
            }
            Group {
                if !authState.isAuthenticated {
                    iOSLoginView()
                        .environmentObject(state)
                        .environmentObject(authState)
                        .environmentObject(alertState)
                        .environmentObject(providerState)
                } else if horizontalSizeClass == .regular {
                    iPadSplitView()
                        .environmentObject(state)
                        .environmentObject(authState)
                        .environmentObject(alertState)
                        .environmentObject(providerState)
                } else {
                    iPhoneTabView
                }
            }
        }
        .preferredColorScheme(state.appearanceMode)
        // iter8 hotfix: do NOT call requestNotificationPermission() here.
        // The previous unconditional .task fired BEFORE sign-in could
        // complete, which made syncPushToken hit the server without a JWT
        // and surface "Failed to register for push notifications: Session
        // expired" right on the login screen. The permission prompt is
        // now triggered at the right product moments instead:
        //   1. setRemoteControlEnabled(true) — the user explicitly opts in
        //   2. refreshYieldScore — when a returning user signs in and the
        //      server reports remote_control_enabled = true
        // Both gate on `isAuthenticated`, so the system permission alert
        // never appears on the login screen.
    }

    // v1.10 P3-6: persistent banner shown when `SUPABASE_ANON_KEY` is missing
    // at launch. Release builds silently fell through to an empty key,
    // leaving the user with a non-functional app and no hint why.
    private var configurationErrorBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.a11y.configurationErrorTitle)
                    .font(.footnote.weight(.semibold))
                Text(L10n.a11y.configurationErrorBody)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.12))
        // v1.10 P3-3: combine so VoiceOver reads the icon + heading + body
        // as one element, but DON'T override with a hardcoded label —
        // let the actual Text content drive the readout so any future
        // localization/body changes propagate.
        .accessibilityElement(children: .combine)
    }

    private var iPhoneTabView: some View {
        TabView(selection: $state.selectedTab) {
            iOSOverviewTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.overview, systemImage: "gauge.with.dots.needle.33percent")
                }
                .tag(AppState.Tab.overview)

            iOSProvidersTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.providers, systemImage: "cpu")
                }
                .tag(AppState.Tab.providers)

            iOSSessionsTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.sessions, systemImage: "terminal")
                }
                .tag(AppState.Tab.sessions)

            iOSAlertsTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.alerts, systemImage: "bell.badge")
                }
                .badge(alertState.alerts.filter { !$0.is_resolved }.count)
                .tag(AppState.Tab.alerts)

            iOSSettingsTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
                .tabItem {
                    Label(L10n.tab.settings, systemImage: "gear")
                }
                .tag(AppState.Tab.settings)
        }
        .tint(PulseTheme.accent)
    }
}

// MARK: - iPad Split View

struct iPadSplitView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @EnvironmentObject var providerState: ProviderState
    @State private var selectedSection: AppState.Tab = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            detailView
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .environmentObject(providerState)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(PulseTheme.accent)
        .keyboardShortcut(.init("1"), modifiers: .command)
    }

    private var sidebar: some View {
        List {
            Section(L10n.dashboard.monitor) {
                sidebarButton(.overview)
                sidebarButton(.providers)
                sidebarButton(.sessions)
            }
            Section(L10n.dashboard.manage) {
                sidebarButton(.alerts, badge: alertState.alerts.filter { !$0.is_resolved }.count)
                sidebarButton(.settings)
            }

            Section(L10n.dashboard.quickStats) {
                if let dash = state.dashboard {
                    HStack {
                        Text(L10n.dashboard.usageToday)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(CostFormatter.formatUsage(dash.total_usage_today))
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                    if state.showCost {
                        HStack {
                            Text(L10n.dashboard.costToday)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(CostFormatter.format(dash.total_estimated_cost_today))
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.green)
                        }
                    }
                    HStack {
                        Text(L10n.dashboard.activeSessions)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(dash.active_sessions)")
                            .font(.caption.weight(.bold).monospacedDigit())
                    }
                }
            }
        }
        .navigationTitle("CLI Pulse")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.requestRefresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(state.isLoading)
                .accessibilityLabel(L10n.common.refresh)
            }
        }
    }

    private func sidebarButton(_ tab: AppState.Tab, badge: Int = 0) -> some View {
        Button {
            selectedSection = tab
        } label: {
            HStack {
                Label(tab.label, systemImage: tab.icon)
                    .foregroundStyle(selectedSection == tab ? PulseTheme.accent : .primary)
                Spacer()
                if badge > 0 {
                    Text("\(badge)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.red))
                }
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedSection {
        case .overview:
            iOSOverviewTab()
        case .providers:
            iOSProvidersTab()
        case .sessions:
            iOSSessionsTab()
        case .alerts:
            iOSAlertsTab()
        case .settings:
            iOSSettingsTab()
        }
    }
}
