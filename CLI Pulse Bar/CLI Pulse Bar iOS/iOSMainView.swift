import SwiftUI
import CLIPulseCore

struct iOSMainView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if !authState.isAuthenticated {
                iOSLoginView()
                    .environmentObject(state)
                    .environmentObject(authState)
                    .environmentObject(alertState)
            } else if horizontalSizeClass == .regular {
                iPadSplitView()
                    .environmentObject(state)
                    .environmentObject(authState)
                    .environmentObject(alertState)
            } else {
                iPhoneTabView
            }
        }
        .preferredColorScheme(state.appearanceMode)
        .task {
            state.requestNotificationPermission()
        }
    }

    private var iPhoneTabView: some View {
        TabView(selection: $state.selectedTab) {
            iOSOverviewTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .tabItem {
                    Label(L10n.tab.overview, systemImage: "gauge.with.dots.needle.33percent")
                }
                .tag(AppState.Tab.overview)

            iOSProvidersTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .tabItem {
                    Label(L10n.tab.providers, systemImage: "cpu")
                }
                .tag(AppState.Tab.providers)

            iOSSessionsTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .tabItem {
                    Label(L10n.tab.sessions, systemImage: "terminal")
                }
                .tag(AppState.Tab.sessions)

            iOSAlertsTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
                .tabItem {
                    Label(L10n.tab.alerts, systemImage: "bell.badge")
                }
                .badge(alertState.alerts.filter { !$0.is_resolved }.count)
                .tag(AppState.Tab.alerts)

            iOSSettingsTab()
                .environmentObject(state)
                .environmentObject(authState)
                .environmentObject(alertState)
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
