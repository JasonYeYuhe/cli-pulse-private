import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 4: extracted from SettingsTab.swift (pre-extraction
/// `pairingSection` + `setupStepsView` + `pairAndStartNativeHelper` +
/// `pairingInProgress` + `nativePairingError` + `modeIndicator` +
/// `copyButton` helpers). The pairing flow is one cohesive state machine
/// and must move as a single unit.
///
/// `helperEnabled` remains owned by the parent (toggle is rendered in
/// Advanced settings); we take a `Binding` so successful pairing
/// propagates the login-item state upward.
struct PairingSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @Binding var helperEnabled: Bool

    @State private var pairingInProgress = false
    @State private var nativePairingError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.settings.connection, icon: "link")

            // Current mode indicator
            if authState.isPaired {
                modeIndicator(icon: "cloud.fill", text: L10n.onboarding.syncedMode, color: PulseTheme.accent)
            } else if state.isLocalMode {
                modeIndicator(icon: "desktopcomputer", text: L10n.onboarding.localModeDesc, color: .green)
                Text(L10n.onboarding.notSyncedHint)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                modeIndicator(icon: "questionmark.circle", text: "Not Connected", color: .orange)
            }

            if !authState.isPaired {
                HowItWorksCard()

                Divider()

                if let info = state.pairingInfo {
                    setupStepsView(info: info)
                } else {
                    Button {
                        Task { await state.generatePairingCode() }
                    } label: {
                        HStack {
                            if state.isLoading { ProgressView().controlSize(.small) }
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 10))
                            Text(L10n.onboarding.setUpSync)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(PulseTheme.accent)
                    .disabled(state.isLoading)
                }
            }

            if let error = state.pairingError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
    }

    private func modeIndicator(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func setupStepsView(info: PairingInfo) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.onboarding.setupStepsTitle)
                .font(.system(size: 12, weight: .bold))

            // Native helper: one-click setup
            VStack(alignment: .leading, spacing: 8) {
                Text("The background helper syncs your usage data to the cloud so you can see it on iOS, Watch, and Android.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Button {
                    Task { await pairAndStartNativeHelper(code: info.code) }
                } label: {
                    HStack {
                        if pairingInProgress { ProgressView().controlSize(.small) }
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10))
                        Text("Set Up Background Helper")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(pairingInProgress || state.isLoading)

                if let error = nativePairingError {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                }
            }

            Divider()

            // Manual fallback for users who prefer terminal
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(info.install_command)
                            .font(.system(size: 8.5, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(3)
                        Spacer(minLength: 4)
                        copyButton(text: info.install_command)
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                    HStack {
                        Text("python3 /tmp/cli_pulse_helper.py daemon")
                            .font(.system(size: 9, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer(minLength: 4)
                        copyButton(text: "python3 /tmp/cli_pulse_helper.py daemon")
                    }
                    .padding(8)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            } label: {
                Text("Manual setup (Terminal)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            // Pairing code display
            HStack {
                Text("Your code:")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(info.code)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(PulseTheme.accent)
                Spacer()
                copyButton(text: info.code)
            }
            .padding(8)
            .background(PulseTheme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button {
                Task { await state.checkPairingStatus() }
            } label: {
                HStack {
                    if state.isLoading { ProgressView().controlSize(.small) }
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10))
                    Text(L10n.onboarding.checkSync)
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(state.isLoading)
        }
        .padding(10)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PulseTheme.accent.opacity(0.2), lineWidth: 1)
        )
    }

    /// Register the native helper via Supabase RPC, save config, and enable Login Item.
    private func pairAndStartNativeHelper(code: String) async {
        pairingInProgress = true
        nativePairingError = nil
        do {
            let client = HelperAPIClient()
            let deviceName = Host.current().localizedName ?? "Mac"
            let config = try await client.registerHelper(
                pairingCode: code,
                deviceName: deviceName,
                system: "\(ProcessInfo.processInfo.operatingSystemVersionString)"
            )
            HelperConfig.save(config)
            HelperLogin.register()
            helperEnabled = HelperLogin.isEnabled
            await state.checkPairingStatus()
        } catch {
            nativePairingError = error.localizedDescription
        }
        pairingInProgress = false
    }

    private func copyButton(text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(PulseTheme.accent)
        .help("Copy to clipboard")
    }
}
