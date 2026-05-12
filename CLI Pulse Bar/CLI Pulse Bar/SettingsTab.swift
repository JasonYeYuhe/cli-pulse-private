import SwiftUI
import ServiceManagement
import StoreKit
import CLIPulseCore

struct SettingsTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @State private var email = ""
    @State private var otpCode = ""
    @State private var password = ""
    @State private var usePasswordLogin = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var helperEnabled = HelperLogin.isEnabled
    @State private var settingsSection: SettingsSection = .general
    // Delete-account state moved to DangerZoneSection.swift (v1.10 P2-2)
    // showGitTrackingConsent state moved to AdvancedSection (v1.10 P2-2 slice 6)
    // alertThresholds state moved to GeneralSection.swift (v1.10 P2-2 slice 5)

    enum SettingsSection: String, CaseIterable {
        case general = "General"
        case display = "Display"
        case providers = "Providers"
        case advanced = "Advanced"

        var label: String {
            switch self {
            case .general: return L10n.settings.general
            case .display: return L10n.settings.display
            case .providers: return "Providers"
            case .advanced: return L10n.settings.advanced
            }
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.settings.title)
                    .font(.system(size: 14, weight: .bold))

                if authState.isAuthenticated {
                    authenticatedSection
                } else {
                    loginSection
                }
            }
            .padding(12)
        }
    }

    // MARK: - Login

    private var loginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.settings.server, icon: "server.rack")

            SectionHeader(title: L10n.settings.signIn, icon: "person.circle")

            if usePasswordLogin {
                // Password sign-in mode
                TextField(L10n.settings.email, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                SecureField(L10n.auth.passwordLabel, text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Button {
                    Task { await state.signInWithPassword(email: email, password: password) }
                } label: {
                    HStack {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        Text(L10n.auth.passwordSignIn)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(email.isEmpty || !email.contains("@") || password.isEmpty || state.isLoading)

                Button {
                    usePasswordLogin = false
                    password = ""
                    state.lastError = nil
                } label: {
                    Text(L10n.auth.useEmailCode)
                        .font(.system(size: 10))
                }
            } else if state.otpSent {
                Text(L10n.auth.codeSentTo(state.otpEmail))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                TextField(L10n.auth.codePlaceholder, text: $otpCode)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))

                Button {
                    Task { await state.verifyOTP(code: otpCode) }
                } label: {
                    HStack {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        Text(L10n.auth.verifyCode)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoading)

                Button { otpCode = ""; state.resetOTP() } label: {
                    Text(L10n.auth.backToEmail).font(.system(size: 10))
                }
            } else {
                TextField(L10n.settings.email, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))

                Button {
                    Task { await state.sendOTP(email: email) }
                } label: {
                    HStack {
                        if state.isLoading { ProgressView().controlSize(.small) }
                        Text(L10n.auth.sendCode)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .disabled(email.isEmpty || !email.contains("@") || state.isLoading)

                Button {
                    usePasswordLogin = true
                    state.lastError = nil
                } label: {
                    Text(L10n.auth.usePassword)
                        .font(.system(size: 10))
                }
            }

            if let error = state.lastError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }

            // iter14 hotfix (2026-04-29): pre-iter14 the only way out
            // of this signed-out Settings panel was to sign in. After
            // delete-account or sign-out, users complained they were
            // "trapped" on a Sign-In form with no escape.
            //
            // iter17 (2026-04-29): the button now calls
            // `state.continueWithoutAccount()` which actually flips
            // the app into local mode (`isLocalMode = true`,
            // `selectedTab = .overview`, and triggers a refresh so
            // collector data appears immediately). The old version
            // only mutated `selectedTab` — refresh still bailed at
            // the `!isAuthenticated` gate, so users saw an empty
            // dashboard. Copy updated to "Use local mode" to match
            // the new semantics.
            Divider()
                .padding(.vertical, 2)
            Button {
                state.continueWithoutAccount()
            } label: {
                Label(L10n.auth.useLocalMode, systemImage: "arrow.right")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Text(L10n.auth.useLocalModeHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Authenticated

    private var authenticatedSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountCardView()

            if !authState.isPaired {
                Divider()
                PairingSection(helperEnabled: $helperEnabled)
            } else {
                Divider()

                SubscriptionSection()

                // v1.16: Companion CLI Helper installer surface. Visible
                // to every authenticated user (post-pairing) right above
                // the section picker so it's discoverable without
                // digging into Advanced. Renders nothing on iOS / Watch
                // builds — HelperInstaller is macOS-only.
                Divider()
                CompanionCLISection(installer: state.helperInstaller)

                // v1.19: Developer ID DMG channel updater. Only present
                // in DEVID builds — MAS users get updates via the App
                // Store. The section also surfaces a G5 banner reminding
                // beta users to disable MAS automatic updates so the
                // App Store version doesn't silently overwrite the beta.
                #if DEVID_BUILD
                Divider()
                AppUpdaterSection(
                    updater: state.appUpdater,
                    permMigration: state.permissionMigrationChecker
                )
                #endif

                Divider()

                // Section picker
                Picker("", selection: $settingsSection) {
                    ForEach(SettingsSection.allCases, id: \.self) { section in
                        Text(section.label)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                switch settingsSection {
                case .general:
                    GeneralSection()
                case .display:
                    DisplaySection()
                case .providers:
                    ProviderSettingsSection()
                case .advanced:
                    AdvancedSection(launchAtLogin: $launchAtLogin, helperEnabled: $helperEnabled)
                }
            }

            Divider()

            // Team management (Pro/Team subscription)
            TeamView()
                .environmentObject(state)

            Divider()
            DangerZoneSection()
        }
    }

    // MARK: - Pairing


    // PairingSection extracted to PairingSection.swift (v1.10 P2-2 slice 4).
    // HowItWorksCard extracted to HowItWorksCard.swift (v1.10 P2-2 slice 2).
    // AccountCardView extracted to AccountCardView.swift (v1.10 P2-2 slice 1).

    // setupStepsView, modeIndicator, copyButton, pairAndStartNativeHelper,
    // pairingInProgress/nativePairingError state all moved to PairingSection.swift
    // (v1.10 P2-2 slice 4). `setupStep<Content>` was unused dead code, deleted.

    // AccountCardView extracted to AccountCardView.swift (v1.10 P2-2)

    // SubscriptionSection extracted to SubscriptionSection.swift (v1.10 P2-2 slice 3)


}
