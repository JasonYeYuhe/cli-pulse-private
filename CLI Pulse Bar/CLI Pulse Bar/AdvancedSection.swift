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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Startup", icon: "power")

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login")
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
                    Text("Enable background sync")
                        .font(.system(size: 11))
                    Text("Syncs usage data to cloud for iOS/Watch/Android")
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
                        Text(ago < 60 ? "Synced just now" : "Synced \(ago / 60)m ago")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    } else if let error = status.error {
                        Text(error)
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    } else {
                        Text(status.state == .running ? "Running" : "Not running")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            FolderAccessView()

            Divider()

            SectionHeader(title: "Privacy", icon: "lock.shield")

            VStack(alignment: .leading, spacing: 6) {
                privacyRow(
                    icon: "lock.fill",
                    color: .green,
                    title: "Provider API keys & cookies",
                    detail: "Stored only in macOS Keychain · never uploaded"
                )
                privacyRow(
                    icon: "internaldrive.fill",
                    color: .green,
                    title: "Session logs (~/.codex/sessions, ~/.claude/projects)",
                    detail: "Scanned on-device via the folders you grant above"
                )
                privacyRow(
                    icon: "icloud.and.arrow.up.fill",
                    color: .blue,
                    title: "Usage metrics (token counts, cost, model names)",
                    detail: "Synced to your CLI Pulse account for iPhone / Watch"
                )
                privacyRow(
                    icon: "person.crop.circle.fill",
                    color: .blue,
                    title: "Your login email",
                    detail: "Sent to our auth backend so you can sign in"
                )
                HStack(spacing: 4) {
                    Text("Full details:")
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
                    Text("Hide email addresses in the UI")
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
                    Text("Track git activity (Yield Score)")
                        .font(.system(size: 11))
                    Text("Hashed commit metadata only — no message, diff, or path uploaded")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .alert("Enable git activity tracking?", isPresented: $showGitTrackingConsent) {
                Button("Cancel", role: .cancel) {}
                Button("Enable") {
                    state.gitTrackingEnabled = true
                    state.pushGitTrackingSettingToServer()
                }
            } message: {
                Text("CLI Pulse will scan git logs in projects where AI sessions are active. Only the commit hash, an HMAC of the project path, the commit timestamp, and a merge-commit flag leave your device. Commit messages, diffs, file paths, and author identity are never uploaded.")
            }

            Divider()

            SectionHeader(title: "Debug", icon: "ladybug")

            HStack {
                Text("Token")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(state.storedToken.isEmpty ? "none" : "••••••••")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }

            HStack {
                Text("Providers loaded")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(providerState.providers.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text("Last refresh")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastRefresh = state.lastRefresh {
                    Text(lastRefresh, style: .time)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text("Never")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
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
