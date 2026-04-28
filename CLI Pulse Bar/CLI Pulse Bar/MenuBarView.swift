import SwiftUI
import CLIPulseCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @EnvironmentObject var providerState: ProviderState
    @AppStorage("cli_pulse_menubar_height") private var storedHeight: Double = 580
    @State private var showRemoteApprovals = false

    /// Adaptive max height: 85% of the screen where the status item lives, capped at 900pt.
    private static var maxMenuBarHeight: CGFloat {
        let screenHeight = NSApp.windows
            .first(where: { $0.className.contains("StatusBarWindow") || $0.className.contains("NSStatusBar") })?
            .screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? 800
        return min(screenHeight * 0.85, 900)
    }

    private var effectiveHeight: CGFloat {
        min(max(CGFloat(storedHeight), 400), Self.maxMenuBarHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !SupabaseConstants.isConfigured {
                configurationErrorBanner
            }
            if !authState.isAuthenticated {
                notConnectedView
            } else if authState.isPaired || state.isLocalMode {
                connectedView
            } else {
                notConnectedView
            }
        }
        .frame(width: 380, height: effectiveHeight)
    }

    // v1.10 P3-6: persistent, non-dismissable banner shown at the top of the
    // menu-bar popover when `SUPABASE_ANON_KEY` is missing from Info.plist +
    // env at launch. Release builds previously silently fell through to an
    // empty key, leaving the user with a blank dashboard and no hint why.
    private var configurationErrorBanner: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 10))
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.a11y.configurationErrorTitle)
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.a11y.configurationErrorBody)
                    .font(.system(size: 9))
                    .lineLimit(2)
            }
            Spacer()
        }
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.12))
        // v1.10 P3-3: combine so VoiceOver reads the icon + heading + body
        // as one element, but DON'T override with a hardcoded label —
        // let the actual Text content drive the readout so any future
        // localization/body changes propagate.
        .accessibilityElement(children: .combine)
    }

    // MARK: - Not Connected

    @AppStorage("cli_pulse_onboarding_completed") private var onboardingCompleted = false

    private var notConnectedView: some View {
        VStack(spacing: 0) {
            if !authState.isAuthenticated && !onboardingCompleted {
                OnboardingWizardView()
                    .environmentObject(state)
            } else {
                tabBar
                SettingsTab()
                    .environmentObject(state)
            }
        }
    }

    // MARK: - Connected

    private var connectedView: some View {
        VStack(spacing: 0) {
            // Error banner
            if let error = state.lastError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(error)
                        .font(.system(size: 9))
                        .lineLimit(1)
                    Spacer()
                    Button {
                        state.lastError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.a11y.dismissError)
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.08))
            }

            // One-time migration banner: "We disabled N providers to fit your
            // free plan." Shown after migrateProviderLimitsIfNeeded() ran on
            // an over-limit free user. Different color (blue, informational)
            // from the tier-limit warning (purple, over-limit) so users see
            // an action, not a failure.
            if state.providerLimitMigrationCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 9))
                    Text("Kept your \(state.subscriptionManager.maxProviders) most-used providers to fit the free plan. Disabled \(state.providerLimitMigrationCount) — edit in Settings → Providers.")
                        .font(.system(size: 9))
                        .lineLimit(3)
                    Spacer()
                    Button {
                        state.selectedTab = .settings
                    } label: {
                        Text("Edit")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    Button {
                        state.dismissProviderLimitMigrationBanner()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.a11y.dismissTierWarning)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.blue.opacity(0.08))
            }

            // Tier limit warning banner
            if let warning = state.tierLimitWarning {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90")
                        .font(.system(size: 9))
                    Text(warning)
                        .font(.system(size: 9))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        state.tierLimitWarning = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.a11y.dismissTierWarning)
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color.purple.opacity(0.08))
            }

            tabBar

            // Tab Content
            Group {
                switch state.selectedTab {
                case .overview:
                    OverviewTab()
                case .providers:
                    ProvidersTab()
                case .sessions:
                    SessionsTab()
                case .alerts:
                    AlertsTab()
                case .settings:
                    SettingsTab()
                }
            }
            .environmentObject(state)
            .frame(maxHeight: .infinity)

            // Footer
            footer

            // Resize handle
            resizeHandle
        }
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppState.Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .separatorColor).opacity(0.1))
    }

    private func tabButton(_ tab: AppState.Tab) -> some View {
        Button {
            state.selectedTab = tab
        } label: {
            VStack(spacing: 2) {
                ZStack {
                    Image(systemName: tab.icon)
                        .font(.system(size: 12))

                    // Alert badge
                    if tab == .alerts {
                        let count = alertState.alerts.filter { !$0.is_resolved }.count
                        if count > 0 {
                            Text("\(min(count, 99))")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .background(Capsule().fill(.red))
                                .offset(x: 8, y: -6)
                        }
                    }
                }
                Text(tab.label)
                    .font(.system(size: 8))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .foregroundStyle(state.selectedTab == tab ? PulseTheme.accent : .secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            if state.isLoading {
                ProgressView()
                    .controlSize(.mini)
            }

            // Provider switcher (compact icons)
            if state.mergeMenuBarIcons {
                providerSwitcher
            }

            Spacer()

            Text("CLI Pulse v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)

            Spacer()

            // v0.26 Phase 1: pending-approvals pill. Only visible when the
            // user has opted into Remote Control AND there is at least one
            // pending request, so the footer stays uncluttered for everyone
            // else. Tapping opens RemoteApprovalsSheet.
            if state.remoteControlEnabled && !state.remotePendingApprovals.isEmpty {
                Button {
                    showRemoteApprovals = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 9))
                        Text("\(state.remotePendingApprovals.count)")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(PulseTheme.accent))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Remote Approvals")
            }

            Button {
                state.requestRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(state.isLoading)
            .accessibilityLabel(L10n.common.refresh)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .separatorColor).opacity(0.1))
        .sheet(isPresented: $showRemoteApprovals) {
            RemoteApprovalsSheet()
                .environmentObject(state)
        }
    }

    // MARK: - Resize Handle

    /// Draggable bar at the bottom edge; vertical drag changes the stored height.
    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 6)
            .overlay(
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color(nsColor: .separatorColor).opacity(0.35))
                    .frame(width: 36, height: 3)
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let newHeight = CGFloat(storedHeight) + value.translation.height
                        let clamped = min(max(newHeight, 400), Self.maxMenuBarHeight)
                        storedHeight = Double(clamped)
                    }
            )
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeUpDown.push()
                } else {
                    NSCursor.pop()
                }
            }
    }

    private var providerSwitcher: some View {
        let enabled = Array(providerState.providerConfigs.filter(\.isEnabled))
        let visible = Array(enabled.prefix(5))
        return HStack(spacing: 2) {
            ForEach(visible) { config in
                let hasData = providerState.providers.contains { $0.provider == config.kind.rawValue }
                Image(systemName: config.kind.iconName)
                    .font(.system(size: 7))
                    .foregroundStyle(hasData ? PulseTheme.providerColor(config.kind.rawValue) : Color.gray.opacity(0.3))
            }
            if enabled.count > 5 {
                Text("+\(enabled.count - 5)")
                    .font(.system(size: 7))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
