import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 6: extracted from SettingsTab.swift (pre-extraction
/// `advancedSection` + `privacyRow` helper + `showGitTrackingConsent`
/// state). Contains Startup / Background Helper / Privacy / Debug
/// sub-sections.
///
/// `launchAtLogin` and `helperEnabled` remain parent-owned (SettingsTab)
/// via `@Binding` because they pair with `LaunchAtLogin.toggle()` /
/// `HelperLogin.toggle()` services that also fire from PairingSection.
struct AdvancedSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState
    @Binding var launchAtLogin: Bool
    @Binding var helperEnabled: Bool

    @State private var showGitTrackingConsent = false
    @State private var showRemoteControlConsent = false
    @State private var rcDiagNotifAuthorized: Bool? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Startup", icon: "power")

            Toggle(isOn: $launchAtLogin) {
                Text(L10n.advanced.launchAtLogin)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: launchAtLogin) { _ in
                LaunchAtLogin.toggle()
            }

            Divider()

            SectionHeader(title: "Background Helper", icon: "arrow.triangle.2.circlepath")

            Toggle(isOn: $helperEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.advanced.backgroundSync)
                        .font(.system(size: 11))
                    Text(L10n.advanced.backgroundSyncHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .onChange(of: helperEnabled) { _ in
                HelperLogin.toggle()
            }

            if let status = HelperIPC.readStatus() {
                HStack(spacing: 4) {
                    Circle()
                        .fill(status.state == .running ? Color.green : (status.state == .error ? Color.red : Color.gray))
                        .frame(width: 6, height: 6)
                    if let lastSync = status.lastSync {
                        let ago = Int(Date().timeIntervalSince(lastSync))
                        Text(ago < 60 ? L10n.advanced.syncJustNow : L10n.advanced.syncMinutesAgo(ago / 60))
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else if let error = status.error {
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    } else {
                        Text(status.state == .running ? L10n.advanced.helperRunning : L10n.advanced.helperNotRunning)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            FolderAccessView()

            Divider()

            SectionHeader(title: L10n.settings.privacy, icon: "lock.shield")

            VStack(alignment: .leading, spacing: 6) {
                privacyRow(
                    icon: "lock.fill",
                    color: .green,
                    title: L10n.advanced.privacyKeysTitle,
                    detail: L10n.advanced.privacyKeysDetail
                )
                privacyRow(
                    icon: "internaldrive.fill",
                    color: .green,
                    title: L10n.advanced.privacyLogsTitle,
                    detail: L10n.advanced.privacyLogsDetail
                )
                privacyRow(
                    icon: "icloud.and.arrow.up.fill",
                    color: .blue,
                    title: L10n.advanced.privacyMetricsTitle,
                    detail: L10n.advanced.privacyMetricsDetail
                )
                privacyRow(
                    icon: "person.crop.circle.fill",
                    color: .blue,
                    title: L10n.advanced.privacyEmailTitle,
                    detail: L10n.advanced.privacyEmailDetail
                )
                HStack(spacing: 4) {
                    Text(L10n.advanced.fullDetails)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Link("Privacy Policy", destination: URL(string: "https://jasonyeyuhe.github.io/cli-pulse/privacy.html")!)
                        .font(.system(size: 9))
                }
                .padding(.top, 2)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Toggle(isOn: $state.hidePersonalInfo) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.hidePersonalInfo)
                        .font(.system(size: 11))
                    Text(L10n.advanced.hideEmails)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { state.gitTrackingEnabled },
                set: { newValue in
                    if newValue && !state.gitTrackingEnabled {
                        showGitTrackingConsent = true
                    } else {
                        state.gitTrackingEnabled = newValue
                        state.pushGitTrackingSettingToServer()
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.advanced.trackGit)
                        .font(.system(size: 11))
                    Text(L10n.advanced.trackGitHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .alert(L10n.advanced.gitConsentTitle, isPresented: $showGitTrackingConsent) {
                Button(L10n.common.cancel, role: .cancel) {}
                Button(L10n.advanced.enable) {
                    state.gitTrackingEnabled = true
                    state.pushGitTrackingSettingToServer()
                }
            } message: {
                Text(L10n.advanced.gitConsentBody)
            }

            // v0.27 Remote Control opt-in. Default OFF. Server-side gate is
            // enforced on every remote_helper_* RPC, so toggling off here
            // actually severs the helper end of the channel.
            //
            // iter4: route every flip through `setRemoteControlEnabled(_:)`
            // so a failed PATCH cleanly reverts the UI instead of leaving it
            // out of sync with the server-side gate.
            //
            // iter6 (post-Codex review on PR #18): the consent confirmation
            // moved from a system `.alert` to an inline card rendered
            // beneath the toggle. SwiftUI's `.alert` doesn't capture
            // clicks reliably inside `MenuBarExtra(.window)` — the same
            // class of bug `RemoteApprovalsSheet` already documented for
            // `.sheet`. Inline buttons in the popover's own SwiftUI tree
            // get clicks every time and don't dismiss the popover.
            Toggle(isOn: Binding(
                get: { state.remoteControlEnabled },
                set: { newValue in
                    if newValue && !state.remoteControlEnabled {
                        // Going ON requires consent — show the inline
                        // card. We deliberately do NOT mutate state
                        // here (otherwise the toggle flips visually
                        // before consent is given).
                        showRemoteControlConsent = true
                    } else {
                        // Going OFF (or repeated set to current value, which
                        // the entry point no-ops) — flip atomically.
                        state.setRemoteControlEnabled(newValue)
                    }
                }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(L10n.advanced.remoteControl)
                            .font(.system(size: 11))
                        if state.remoteControlSaving {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                    Text(L10n.advanced.remoteControlHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            // iter5 P1: while a PATCH is in flight, lock the toggle so a
            // double-tap (or any other re-entrant call) can't race a stale
            // request past the latest intent.
            .disabled(state.remoteControlSaving)

            if showRemoteControlConsent {
                remoteControlConsentCard
            }

            remoteControlDiagnostics

            // Machine controls M1 (DEVID-only). Off by default. Purely local:
            // gates the Machine tab's "End Process" affordance for the user's
            // OWN processes — no root, no server round-trip, and every action
            // still asks for an inline confirmation. Hidden on MAS (the
            // affordance is #if DEVID_BUILD and the App Sandbox forbids it).
            #if DEVID_BUILD
            Toggle(isOn: Binding(
                get: { state.machineControlsEnabled },
                set: { state.machineControlsEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.machine.controlsToggle)
                        .font(.system(size: 11))
                    Text(L10n.machine.controlsHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            // Remote machine control (v1.41, DEVID-only). Off by default; a SECOND
            // opt-in on top of Machine controls. When ON, this Mac's executor honors
            // fan-boost / Low Power Mode REQUESTS from the owner's other signed-in
            // devices. A cloud command is only a request — the fan hold heartbeat +
            // TTL revert stay local, and it's bounded to fan RPM + LPM (never process
            // control). Shown only when the local Machine controls opt-in is also on.
            if state.machineControlsEnabled {
                Toggle(isOn: Binding(
                    get: { state.remoteMachineControlEnabled },
                    set: { state.remoteMachineControlEnabled = $0 }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.machine.remoteControlToggle)
                            .font(.system(size: 11))
                        Text(L10n.machine.remoteControlHint)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            #endif

            Divider()

            SectionHeader(title: "Debug", icon: "ladybug")

            HStack {
                Text(L10n.advanced.token)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.storedToken.isEmpty ? "none" : "••••••••")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }

            HStack {
                Text(L10n.advanced.providersLoaded)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(providerState.providers.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.advanced.lastRefresh)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastRefresh = state.lastRefresh {
                    Text(lastRefresh, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(L10n.advanced.never)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Remote Control diagnostics — a collapsible health panel beneath the
    /// toggle so the user (and support) can see *why* RC isn't working. The
    /// disclosure label carries the overall status icon for an at-a-glance read.
    private var remoteControlDiagnostics: some View {
        let report = RemoteControlHealth.evaluate(.from(
            isPaired: state.isPaired,
            remoteControlEnabled: state.remoteControlEnabled,
            devices: state.devices,
            notificationsAuthorized: rcDiagNotifAuthorized))
        return DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                RemoteControlHealthView(report: report)
                Button(L10n.diagnostics.copy) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(report.supportText(), forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(PulseTheme.accent)
            }
            .padding(.top, 4)
            .task {
                rcDiagNotifAuthorized = await RemoteControlHealth.currentNotificationAuthorization()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: report.overall.iconName)
                    .foregroundStyle(report.overall.tint)
                    .font(.system(size: 10))
                Text(L10n.diagnostics.title)
                    .font(.system(size: 11))
            }
        }
    }

    /// Inline consent card rendered below the Remote Control toggle
    /// when the user flips it on. Replaces the previous `.alert(...)`
    /// usage which was unreliable inside `MenuBarExtra(.window)` —
    /// `.alert` and `.sheet` both have a known click-capture issue
    /// in that context (RemoteApprovalsSheet documents the same bug
    /// for the approval surface).
    ///
    /// Cancel / Enable are plain SwiftUI Buttons. They dispatch on
    /// the popover's own runloop without causing MenuBarExtra
    /// dismissal — verified manually + pinned by the build's
    /// existing snapshot of advanced-section structure.
    private var remoteControlConsentCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                Text(L10n.advanced.remoteConsentTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            Text(remoteControlConsentBody)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.common.cancel) {
                    showRemoteControlConsent = false
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
                Button(L10n.advanced.enable) {
                    // Single atomic entry point — handles optimistic
                    // set, PATCH, and revert-on-failure.
                    state.setRemoteControlEnabled(true)
                    showRemoteControlConsent = false
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.30), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .transition(.opacity.combined(with: .move(edge: .top)))
        .animation(.easeInOut(duration: 0.18), value: showRemoteControlConsent)
    }

    /// Body copy for the Remote Control consent — same content as
    /// the old `.alert` message so the consent text doesn't drift.
    ///
    /// v1.21 D7: routed through `L10n.advanced.remoteConsentBody` so the
    /// localized string catalog is the single source of truth (Mac + iOS
    /// share the same key). The iOS surface in `iOSSettingsTab.swift`
    /// reads the same key.
    private var remoteControlConsentBody: String {
        L10n.advanced.remoteConsentBody
    }

    /// v1.9.4 privacy disclosure row. Green = stays on device,
    /// blue = synced to account.
    private func privacyRow(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
