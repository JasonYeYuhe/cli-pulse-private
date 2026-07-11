import SwiftUI
import CLIPulseCore

struct MenuBarView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var alertState: AlertState
    @EnvironmentObject var providerState: ProviderState
    @AppStorage("cli_pulse_menubar_height") private var storedHeight: Double = 580
    @State private var showRemoteApprovals = false
    /// iter22: observed so SwiftUI re-evaluates the body (and every
    /// `Text(L10n.*)` inside it) whenever the user picks a new
    /// language from the footer picker.
    @ObservedObject private var localeOverride = LocaleOverrideStore.shared
    /// v1.30.2 (RC-2): the MenuBarExtra(.window) popover becomes the key
    /// window when it opens. `controlActiveState` flips to `.key`/`.active`
    /// on open and `.inactive` on close, so observing it lets us re-probe the
    /// companion-CLI helper every time the popover reopens — without this the
    /// popover's one-shot `.task { refresh() }` never re-fires (the content
    /// view is reused across open/close), so a helper that came up after the
    /// user finished Installer.app keeps showing a stale "not installed".
    @Environment(\.controlActiveState) private var controlActiveState

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
        Group {
            // iter1 / iter2 review fix: previously the Remote Approvals
            // surface was presented via `.sheet(isPresented:)` attached
            // to the connected-view footer. Inside a
            // `MenuBarExtra(...).menuBarExtraStyle(.window)` popover,
            // SwiftUI renders that sheet but every click inside it —
            // including refresh / X buttons and even empty area —
            // propagated to the popover's click-outside handler,
            // dismissing the entire menubar popover before the sheet's
            // button actions could fire. The user could open the sheet
            // but couldn't interact with it.
            //
            // Render INLINE instead. The approvals view becomes a
            // full-popover replacement (taking over the same 380 ×
            // effectiveHeight frame as the main content) with normal
            // button click handling. The X button calls back through
            // the explicit `onDismiss` closure to flip our state
            // variable, which restores the main menubar content.
            if showRemoteApprovals {
                RemoteApprovalsSheet(onDismiss: {
                    showRemoteApprovals = false
                })
                .environmentObject(state)
            } else {
                VStack(spacing: 0) {
                    if !SupabaseConstants.isConfigured {
                        configurationErrorBanner
                    }
                    // iter17 (2026-04-29): route via `state.isLocalMode`
                    // even when unauthenticated — that's the new
                    // user-opt-in flag set by
                    // `AppState.continueWithoutAccount()`. Pre-iter17
                    // the very first check was `!authState.isAuthenticated
                    // → notConnectedView`, which made `isLocalMode`
                    // meaningful only for signed-in unpaired Mac users
                    // (a flow that's mostly obsolete post-iter9). Now
                    // any user — signed in or not — who has
                    // `isLocalMode = true` lands in the full tab shell
                    // and sees their local Mac collector data. The
                    // signed-in-but-unpaired-non-local-mode branch
                    // (PairingSection flow) stays in `notConnectedView`.
                    if state.isLocalMode || authState.isPaired {
                        connectedView
                    } else {
                        notConnectedView
                    }
                }
            }
        }
        .frame(width: 380, height: effectiveHeight)
        .onChange(of: controlActiveState) { newValue in
            // RC-2: re-probe the companion-CLI helper when the popover
            // (re)gains focus. `refreshIfStale` self-throttles so this is a
            // no-op for a freshly-checked / mid-install state, and the
            // network cost is one tiny hello + manifest GET at most once
            // per `maxAge` window.
            guard newValue != .inactive else { return }
            Task { await state.helperInstaller.refreshIfStale() }
            // v1.40 PR-8: feed the adaptive refresh cadence — an active popover is
            // a "recent interaction" and shortens the next auto-refresh to ~2 min.
            state.notePopoverActivated()
        }
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
            // Inner content branches by auth/onboarding state. Each
            // branch is wrapped in a `.frame(maxHeight: .infinity)`
            // container so the basic footer below sits flush against
            // the bottom of the popover, matching the connected view's
            // footer placement.
            Group {
                if !authState.isAuthenticated && !onboardingCompleted {
                    OnboardingWizardView()
                        .environmentObject(state)
                } else if !authState.isAuthenticated {
                    // iter14 hotfix (2026-04-29): signed-out + onboarding
                    // already done. Pre-iter14 this branch ignored
                    // `state.selectedTab` and always rendered SettingsTab,
                    // so a user who tapped "Continue without account" in
                    // SettingsTab.loginSection had nowhere to land — the
                    // tab switch was effectively a no-op. Route through
                    // the same tab system as `connectedView` so Overview /
                    // Providers / Sessions / Alerts each render their
                    // own empty-state when there's no data, and the user
                    // can come back to Settings to log in any time.
                    //
                    // The signed-in-but-unpaired branch below is left
                    // unchanged on purpose: that flow expects users to
                    // land directly on SettingsTab so PairingSection is
                    // immediately visible.
                    VStack(spacing: 0) {
                        tabBar
                        Group {
                            switch state.selectedTab {
                            case .overview:    OverviewTab()
                            case .machine:     MachineHealthView()
                            case .providers:   ProvidersTab()
                            case .sessions:    SessionsTab()
                            case .swarm:       SwarmTab()
                            case .alerts:      AlertsTab()
                            case .pet:         PetTab()
                            case .settings:    SettingsTab()
                            }
                        }
                        .environmentObject(state)
                        .frame(maxHeight: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        tabBar
                        SettingsTab()
                            .environmentObject(state)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            // iter15 hotfix (2026-04-29): every signed-out / onboarding
            // surface gets the same bottom power button. Pre-iter15 only
            // `connectedView` rendered the footer, so users in the
            // onboarding wizard or signed-out tab shell had no
            // bottom-right Quit affordance — the only way out of the app
            // was Cmd-Q from the menubar, which is invisible if the user
            // doesn't already know it. The basic variant strips the
            // signed-in-only widgets (provider switcher, Remote Approvals,
            // refresh) and shows version + power only.
            basicFooter
            resizeHandle
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
                    Text(L10n.menuBar.tierMigration(kept: state.subscriptionManager.maxProviders, disabled: state.providerLimitMigrationCount))
                        .font(.system(size: 9))
                        .lineLimit(3)
                    Spacer()
                    Button {
                        state.selectedTab = .settings
                    } label: {
                        Text(L10n.menuBar.edit)
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
                case .machine:
                    MachineHealthView()
                case .providers:
                    ProvidersTab()
                case .sessions:
                    SessionsTab()
                case .swarm:
                    SwarmTab()
                case .alerts:
                    AlertsTab()
                case .pet:
                    PetTab()
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

    /// Minimal footer for signed-out / onboarding surfaces.
    ///
    /// Mirrors the connected `footer`'s shape (same height, same
    /// background, same version-label centering, same power button on
    /// the trailing edge) but omits widgets that require an
    /// authenticated session: provider switcher, Remote Approvals
    /// entry, refresh button. The power button uses the same
    /// `NSApplication.shared.terminate(nil)` action so quit behavior
    /// is identical regardless of which footer is showing.
    private var basicFooter: some View {
        HStack(spacing: 6) {
            Spacer()

            Text(L10n.menuBar.appVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"))
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)

            Spacer()

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.menuBar.quit)
            .help(L10n.menuBar.quit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .separatorColor).opacity(0.1))
    }

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

            Text(L10n.menuBar.appVersion(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"))
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)

            Spacer()

            // Remote Approvals entry. Visibility logic lives in
            // CLIPulseCore.RemoteApprovalsEntryState so it can be unit-
            // tested in isolation (see RemoteApprovalsEntryStateTests).
            // Always-on entry when Remote Control is enabled — see
            // RemoteApprovalsEntryState.footer doc comment for the
            // dead-loop bug it exists to prevent.
            let approvalsEntry = RemoteApprovalsEntryState.footer(
                remoteControlEnabled: state.remoteControlEnabled,
                pendingCount: state.remotePendingApprovals.count
            )
            if approvalsEntry.isVisible {
                Button {
                    showRemoteApprovals = true
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 9))
                        if let count = approvalsEntry.badgeCount {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(
                        approvalsEntry.badgeCount == nil
                            ? PulseTheme.accent.opacity(0.55)
                            : PulseTheme.accent
                    ))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(approvalsEntry.badgeCount == nil
                    ? L10n.remoteApprovals.entryLabelNone
                    : L10n.remoteApprovals.entryLabelWithCount(approvalsEntry.badgeCount!))
                .help(approvalsEntry.badgeCount == nil
                    ? L10n.remoteApprovals.entryHelpNone
                    : L10n.remoteApprovals.entryHelpWithCount(approvalsEntry.badgeCount!))
            }

            // iter22: in-app language switcher placed immediately
            // left of the refresh button per director request.
            languagePicker

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
        // NOTE: `.sheet(isPresented: $showRemoteApprovals) { ... }`
        // used to live here. Removed because clicks inside the sheet
        // didn't capture event-wise inside a MenuBarExtra(.window)
        // popover — they were treated as "outside the popover" and
        // dismissed the whole menubar window. The approvals view is
        // now rendered INLINE at the top level of the body's Group;
        // see the `if showRemoteApprovals { ... }` branch in `body`.
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

    /// iter22: globe icon button → menu with English / 简体中文 /
    /// 日本語 / System Default. Tapping persists the choice via
    /// `LocaleOverrideStore.shared.set(...)` and forces a re-render
    /// because `localeOverride` is `@ObservedObject` on this view.
    private var languagePicker: some View {
        Menu {
            Button(action: { LocaleOverrideStore.shared.set("en") }) {
                Label("English", systemImage: localeOverride.override == "en" ? "checkmark" : "")
            }
            Button(action: { LocaleOverrideStore.shared.set("zh-Hans") }) {
                Label("简体中文", systemImage: localeOverride.override == "zh-Hans" ? "checkmark" : "")
            }
            Button(action: { LocaleOverrideStore.shared.set("zh-Hant") }) {
                Label("繁體中文", systemImage: localeOverride.override == "zh-Hant" ? "checkmark" : "")
            }
            Button(action: { LocaleOverrideStore.shared.set("ja") }) {
                Label("日本語", systemImage: localeOverride.override == "ja" ? "checkmark" : "")
            }
            Divider()
            Button(action: { LocaleOverrideStore.shared.set(nil) }) {
                Label(L10n.language.systemDefault, systemImage: localeOverride.override == nil ? "checkmark" : "")
            }
        } label: {
            Image(systemName: "globe")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.language.title)
        .help(L10n.language.title)
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
