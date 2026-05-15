import SwiftUI
import AuthenticationServices
import CryptoKit
import CLIPulseCore

struct iOSSettingsTab: View {
    @EnvironmentObject var state: AppState
    /// v1.10 P2-3 slice 2: observe SubscriptionManager directly.
    @EnvironmentObject var subscriptionManager: SubscriptionManager
    /// v1.10 P2-3 slice 3: observe AuthState directly.
    @EnvironmentObject var authState: AuthState
    /// v1.10 P2-3 slice 5: observe ProviderState directly.
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDeleteConfirmation = false
    // iter10 hotfix: surface delete-account failures. Previously the
    // confirm-alert called `state.deleteAccount()` and ignored the
    // outcome; if the RPC failed (most commonly: stale JWT → "Not
    // authenticated"), `state.lastError` was set but never displayed
    // anywhere on this screen, so the user thought the delete succeeded.
    @State private var deleteAccountErrorMessage: String?
    @State private var alertThresholds: AlertThresholds = AlertThresholdsStore.load()
    @State private var showRemoteControlConsent = false

    private var isIPad: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            Form {
                if authState.isAuthenticated {
                    // Account
                    Section(L10n.settings.account) {
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle.fill")
                                .font(.title)
                                .foregroundStyle(PulseTheme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(authState.userName)
                                    .font(.headline)
                                if !state.hidePersonalInfo {
                                    Text(authState.userEmail)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            StatusBadge(
                                text: authState.isPaired ? L10n.settings.paired : L10n.settings.notPaired,
                                color: authState.isPaired ? .green : .orange
                            )
                        }
                        .padding(.vertical, 4)
                    }

                    // Linked OAuth identities (Apple / Google / GitHub)
                    LinkedAccountsSection()

                    // Sync Setup Guide (shown when not synced)
                    if !authState.isPaired {
                        Section {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "cloud")
                                        .font(.title3)
                                        .foregroundStyle(PulseTheme.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L10n.onboarding.howItWorks)
                                            .font(.headline)
                                        Text(L10n.onboarding.cloudSyncDesc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Divider()

                                Text(L10n.onboarding.setupStepsTitle)
                                    .font(.subheadline.weight(.semibold))

                                iOSSetupStepRow(number: 1, icon: "desktopcomputer", text: L10n.onboarding.step1Mac)
                                iOSSetupStepRow(number: 2, icon: "terminal", text: L10n.onboarding.step2Helper)
                                iOSSetupStepRow(number: 3, icon: "iphone", text: L10n.onboarding.step3Phone)

                                Text(L10n.onboarding.notBluetooth)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 4)
                        } header: {
                            Text(L10n.settings.connection)
                        }
                    }

                    // Subscription
                    Section(L10n.settings.subscription) {
                        HStack {
                            Text(L10n.settings.currentPlan)
                            Spacer()
                            SubscriptionBadge(tier: subscriptionManager.currentTier)
                        }

                        HStack {
                            Text(L10n.settings.providers)
                            Spacer()
                            Text(subscriptionManager.maxProviders < 0 ? L10n.account.unlimited : "\(subscriptionManager.maxProviders)")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(L10n.settings.devices)
                            Spacer()
                            Text(subscriptionManager.maxDevices < 0 ? L10n.account.unlimited : "\(subscriptionManager.maxDevices)")
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(L10n.settings.dataRetention)
                            Spacer()
                            Text("\(subscriptionManager.dataRetentionDays) \(L10n.settings.days)")
                                .foregroundStyle(.secondary)
                        }

                        NavigationLink {
                            SubscriptionView(manager: subscriptionManager)
                        } label: {
                            HStack {
                                if subscriptionManager.isProOrAbove {
                                    Label(L10n.settings.manageSubscription, systemImage: "gear")
                                } else {
                                    Label(L10n.settings.upgradePro, systemImage: "star.fill")
                                        .foregroundStyle(PulseTheme.accent)
                                }
                            }
                        }
                    }

                    // General
                    Section(L10n.settings.general) {
                        HStack {
                            Text(L10n.settings.server)
                            Spacer()
                            Text(L10n.settings.serverName)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text(L10n.settings.status)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(state.serverOnline ? .green : .red)
                                    .frame(width: 8, height: 8)
                                Text(state.serverOnline ? L10n.settings.connected : L10n.settings.disconnected)
                                    .font(.caption)
                                    .foregroundStyle(state.serverOnline ? .green : .red)
                            }
                        }

                        Picker(L10n.settings.refreshInterval, selection: Binding(
                            get: { state.refreshInterval },
                            set: { state.updateRefreshInterval($0) }
                        )) {
                            Text("30s").tag(30)
                            Text("1m").tag(60)
                            Text("2m").tag(120)
                            Text("5m").tag(300)
                            Text("10m").tag(600)
                            Text("30m").tag(1800)
                        }
                    }

                    // Display
                    Section(L10n.settings.display) {
                        Picker(L10n.settings.appearance, selection: $state.appearanceModeRaw) {
                            Text(L10n.settings.appearanceSystem).tag(0)
                            Text(L10n.settings.appearanceLight).tag(1)
                            Text(L10n.settings.appearanceDark).tag(2)
                        }

                        Toggle(L10n.settings.showCostEstimates, isOn: $state.showCost)
                        Toggle(L10n.settings.compactMode, isOn: $state.compactMode)

                        Picker(L10n.settings.menuBarMode, selection: Binding(
                            get: { state.menuBarDisplayMode },
                            set: { state.menuBarDisplayMode = $0 }
                        )) {
                            ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                                Text(mode.localizedName).tag(mode)
                            }
                        }
                    }

                    // Provider Management - inline grid
                    Section {
                        let columns: [GridItem] = isIPad
                            ? [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]
                            : [GridItem(.flexible()), GridItem(.flexible())]

                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(providerState.providerConfigs) { config in
                                providerToggleCell(config)
                            }
                        }
                        .padding(.vertical, 4)

                        NavigationLink {
                            ProviderManagementView()
                                .environmentObject(state)
                                .environmentObject(providerState)
                        } label: {
                            HStack {
                                Text(L10n.settings.reorderProviders)
                                Spacer()
                                let enabled = providerState.providerConfigs.filter(\.isEnabled).count
                                Text("\(enabled)/\(providerState.providerConfigs.count)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text(L10n.settings.providers)
                    }

                    // Notifications
                    Section(L10n.settings.notifications) {
                        Toggle(L10n.settings.alertNotifications, isOn: $state.notificationsEnabled)
                        Toggle(L10n.settings.sessionQuotaAlerts, isOn: $state.sessionQuotaNotifications)
                        Toggle(L10n.settings.checkProviderStatus, isOn: $state.checkProviderStatus)

                        Stepper(value: Binding(
                            get: { alertThresholds.warning },
                            set: { newValue in
                                alertThresholds = AlertThresholds.clamped(
                                    warning: newValue, critical: alertThresholds.critical
                                )
                                AlertThresholdsStore.save(alertThresholds)
                            }
                        ), in: AlertThresholds.warningRange, step: 5) {
                            Text(L10n.settings.warningThresholdPct(alertThresholds.warning))
                                .monospacedDigit()
                        }
                        Stepper(value: Binding(
                            get: { alertThresholds.critical },
                            set: { newValue in
                                alertThresholds = AlertThresholds.clamped(
                                    warning: alertThresholds.warning, critical: newValue
                                )
                                AlertThresholdsStore.save(alertThresholds)
                            }
                        ), in: (alertThresholds.warning + 1)...AlertThresholds.criticalUpperBound, step: 5) {
                            Text(L10n.settings.criticalThresholdPct(alertThresholds.critical))
                                .monospacedDigit()
                        }
                        if alertThresholds != .defaults {
                            Button(L10n.settings.resetThresholdsDefaults) {
                                alertThresholds = .defaults
                                AlertThresholdsStore.save(.defaults)
                            }
                        }
                    }

                    // Integrations (Webhook)
                    Section(L10n.integrations.title) {
                        Toggle(L10n.integrations.webhookNotifications, isOn: Binding(
                            get: { state.webhookEnabled },
                            set: { state.webhookEnabled = $0; state.pushSettingsToServer() }
                        ))

                        if state.webhookEnabled {
                            TextField(L10n.integrations.webhookURLPlaceholder, text: Binding(
                                get: { state.webhookURL },
                                set: { state.webhookURL = $0 }
                            ))
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit { state.pushSettingsToServer() }

                            Button {
                                state.pushSettingsToServer()
                                Task { await state.testWebhook() }
                            } label: {
                                HStack {
                                    Image(systemName: "paperplane")
                                    Text(L10n.integrations.testWebhook)
                                }
                            }
                            .disabled(state.webhookURL.isEmpty)
                        }
                    }

                    // Remote Control (v0.26 Phase 1) — privacy-first opt-in.
                    // Server-side gate on every helper RPC, so toggling off
                    // here actually severs the helper end of the channel.
                    Section {
                        // iter4: every flip goes through
                        // `setRemoteControlEnabled(_:)` so a failed PATCH
                        // reverts the UI rather than desyncing from the
                        // server-side gate.
                        Toggle(isOn: Binding(
                            get: { state.remoteControlEnabled },
                            set: { newValue in
                                if newValue && !state.remoteControlEnabled {
                                    // Going ON — wait for consent.
                                    showRemoteControlConsent = true
                                } else {
                                    state.setRemoteControlEnabled(newValue)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(L10n.settings.remoteControl)
                                    if state.remoteControlSaving {
                                        ProgressView()
                                            .controlSize(.small)
                                    }
                                }
                                Text(L10n.settings.remoteControlIPhoneHint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        // iter5 P1: lock the toggle while a PATCH is in
                        // flight so re-entrant taps can't race the request.
                        .disabled(state.remoteControlSaving)

                        // Always-visible NavigationLink when Remote Control
                        // is on, even at zero pending — that's how the user
                        // opens the screen to start active polling. See the
                        // RemoteApprovalsEntryState helper docstring in
                        // CLIPulseCore for the dead-loop bug this prevents.
                        let pendingEntry = RemoteApprovalsEntryState.footer(
                            remoteControlEnabled: state.remoteControlEnabled,
                            pendingCount: state.remotePendingApprovals.count
                        )
                        if pendingEntry.isVisible {
                            NavigationLink {
                                iOSRemoteApprovalsView()
                                    .environmentObject(state)
                            } label: {
                                HStack {
                                    Image(systemName: "checkmark.shield")
                                    Text(L10n.settings.pendingApprovals)
                                    Spacer()
                                    if let count = pendingEntry.badgeCount {
                                        Text("\(count)")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(PulseTheme.accent))
                                    }
                                }
                            }
                        }
                    } header: {
                        Text(L10n.settings.privacy)
                    } footer: {
                        Text(L10n.settings.privacyRedactedHint)
                            .font(.caption)
                    }
                    .alert(L10n.advanced.remoteConsentTitle, isPresented: $showRemoteControlConsent) {
                        Button(L10n.common.cancel, role: .cancel) {}
                        Button(L10n.advanced.enable) {
                            // Atomic entry point — see DataRefreshManager.
                            state.setRemoteControlEnabled(true)
                        }
                    } message: {
                        // v1.21 D7: privacy-critical consent body, now in the
                        // localized string catalog (single shared key with the
                        // Mac AdvancedSection surface). en + zh-Hans translated
                        // in v1.21; es/ja/ko still emit the English fallback
                        // pending native-speaker review (do not machine-translate
                        // — Gemini round 1 ASC 4.0 rejection risk).
                        Text(L10n.advanced.remoteConsentBody)
                    }

                    // Advanced
                    Section(L10n.settings.advanced) {
                        Toggle(L10n.settings.hidePersonalInfo, isOn: $state.hidePersonalInfo)

                        Button {
                            state.requestRefresh()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text(L10n.settings.forceRefresh)
                            }
                        }
                        .disabled(state.isLoading)
                    }

                    // Teams
                    Section(L10n.team.title) {
                        TeamView()
                            .environmentObject(state)
                    }

                    // About
                    Section(L10n.settings.about) {
                        HStack {
                            Text(L10n.settings.version)
                            Spacer()
                            Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            Text(L10n.settings.build)
                            Spacer()
                            Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                                .foregroundStyle(.secondary)
                        }
                        Link(destination: URL(string: "https://github.com/jasonyeyuhe/cli-pulse")!) {
                            HStack {
                                Text(L10n.settings.github)
                                Spacer()
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                        }
                        Link(destination: URL(string: "https://jasonyeyuhe.github.io/cli-pulse/privacy.html")!) {
                            HStack {
                                Text(L10n.settings.privacyPolicy)
                                Spacer()
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                        }
                        Link(destination: URL(string: "https://jasonyeyuhe.github.io/cli-pulse/terms.html")!) {
                            HStack {
                                Text(L10n.settings.termsOfUse)
                                Spacer()
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.caption)
                            }
                        }
                    }

                    // Sign Out & Delete Account
                    Section {
                        Button(role: .destructive) {
                            state.signOut()
                        } label: {
                            HStack {
                                Image(systemName: "arrow.right.square")
                                Text(L10n.settings.signOut)
                            }
                        }

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text(L10n.account.deleteAccount)
                            }
                        }
                        .alert(L10n.account.deleteConfirmTitle, isPresented: $showDeleteConfirmation) {
                            Button(L10n.common.cancel, role: .cancel) { }
                            Button(L10n.common.delete, role: .destructive) {
                                // iter10 hotfix: inspect the result so we
                                // can show an alert when the server-side
                                // RPC fails. On `false` the user is still
                                // signed in (account intact server-side),
                                // and we surface `state.lastError` via
                                // `deleteAccountErrorMessage` so the user
                                // knows to retry.
                                Task {
                                    let succeeded = await state.deleteAccount()
                                    if !succeeded {
                                        deleteAccountErrorMessage = state.lastError
                                            ?? L10n.account.deleteFailedGeneric
                                    }
                                }
                            }
                        } message: {
                            Text(L10n.account.deleteConfirmMessage)
                        }
                        .alert(
                            L10n.account.deleteFailedTitle,
                            isPresented: Binding(
                                get: { deleteAccountErrorMessage != nil },
                                set: { if !$0 { deleteAccountErrorMessage = nil } }
                            )
                        ) {
                            Button(L10n.common.ok, role: .cancel) {
                                deleteAccountErrorMessage = nil
                            }
                        } message: {
                            Text(deleteAccountErrorMessage ?? L10n.account.deleteFailedGeneric)
                        }
                    }
                } else {
                    Section {
                        Text(L10n.settings.signInHint)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(L10n.settings.title)
        }
    }

    private func providerToggleCell(_ config: ProviderConfig) -> some View {
        VStack(spacing: 6) {
            Image(systemName: config.kind.iconName)
                .font(.title3.weight(.semibold))
                .foregroundStyle(config.isEnabled
                    ? PulseTheme.providerColor(config.kind.rawValue)
                    : .gray
                )
                .frame(width: 36, height: 36)
                .background(
                    (config.isEnabled
                        ? PulseTheme.providerColor(config.kind.rawValue)
                        : Color.gray
                    ).opacity(0.12)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(config.kind.rawValue)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(config.isEnabled ? .primary : .secondary)

            Toggle("", isOn: Binding(
                get: { config.isEnabled },
                set: { _ in state.toggleProvider(config.kind) }
            ))
            .labelsHidden()
            .scaleEffect(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Management View

struct ProviderManagementView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState

    var body: some View {
        List {
            Section {
                ForEach(providerState.providerConfigs) { config in
                    HStack(spacing: 12) {
                        Image(systemName: config.kind.iconName)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(PulseTheme.providerColor(config.kind.rawValue))
                            .frame(width: 28)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(config.kind.rawValue)
                                .font(.body)
                            if let usage = providerState.providers.first(where: { $0.provider == config.kind.rawValue }) {
                                Text(L10n.detail.usageToday(CostFormatter.formatUsage(usage.today_usage)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(L10n.common.noData)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { config.isEnabled },
                            set: { _ in state.toggleProvider(config.kind) }
                        ))
                        .labelsHidden()
                    }
                }
                .onMove { from, to in
                    state.moveProvider(from: from, to: to)
                }
            } header: {
                Text(L10n.settings.reorderHint)
            }
        }
        .navigationTitle(L10n.settings.manageProviders)
        .environment(\.editMode, .constant(.active))
    }
}

// MARK: - Setup Step Row

struct iOSSetupStepRow: View {
    let number: Int
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(PulseTheme.accent)
                .clipShape(Circle())

            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
        }
    }
}

// MARK: - Linked Accounts Section

/// Section for the iOS Settings screen that lets a signed-in user link
/// additional OAuth identities (Apple / Google / GitHub) to their account.
///
/// Backed by Supabase's `/auth/v1/user/identities/authorize` (OAuth providers)
/// and `/auth/v1/token?grant_type=id_token` with `link_identity: true` (Apple).
struct LinkedAccountsSection: View {
    @EnvironmentObject var state: AppState
    @State private var currentAppleNonce: String?
    @State private var webAuthSession: ASWebAuthenticationSession?
    @State private var pendingUnlink: UserIdentity?
    @State private var localError: String?

    private static let webAuthContextProvider = LinkedAccountsWebAuthContextProvider()

    private struct ProviderOption: Identifiable {
        let id: String
        let label: String
        let iconName: String
        let tint: Color
    }

    private let providerOptions: [ProviderOption] = [
        ProviderOption(id: "apple",  label: "Apple",  iconName: "apple.logo", tint: .primary),
        ProviderOption(id: "google", label: "Google", iconName: "globe",      tint: .blue),
        ProviderOption(id: "github", label: "GitHub", iconName: "chevron.left.forwardslash.chevron.right", tint: Color(red: 0.14, green: 0.16, blue: 0.22)),
    ]

    var body: some View {
        Section {
            ForEach(providerOptions) { provider in
                row(for: provider)
            }
            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        } header: {
            Text(L10n.account.linkedAccounts)
        } footer: {
            Text(L10n.account.linkedAccountsFooter)
        }
        .task { await state.refreshLinkedIdentities() }
        .confirmationDialog(
            L10n.account.unlinkConfirmTitle,
            isPresented: Binding(
                get: { pendingUnlink != nil },
                set: { if !$0 { pendingUnlink = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingUnlink
        ) { identity in
            Button(L10n.account.unlinkWithProvider(providerLabel(identity.provider)), role: .destructive) {
                Task {
                    localError = nil
                    await state.unlinkIdentity(identity)
                    pendingUnlink = nil
                }
            }
            Button(L10n.common.cancel, role: .cancel) { pendingUnlink = nil }
        } message: { identity in
            Text(L10n.account.unlinkMessage(providerLabel(identity.provider)))
        }
    }

    // MARK: Row

    @ViewBuilder
    private func row(for provider: ProviderOption) -> some View {
        let linked = linkedIdentity(for: provider.id)
        HStack(spacing: 12) {
            Image(systemName: provider.iconName)
                .font(.title3)
                .foregroundStyle(provider.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(provider.label)
                    .font(.body)
                if let email = linked?.email, !email.isEmpty, !state.hidePersonalInfo {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if linked != nil {
                    Text(L10n.account.linkedStatus)
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text(L10n.account.notLinkedStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            actionButton(for: provider, linked: linked)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func actionButton(for provider: ProviderOption, linked: UserIdentity?) -> some View {
        if let linked {
            Button(role: .destructive) {
                localError = nil
                pendingUnlink = linked
            } label: {
                Text(L10n.account.unlink).font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(state.isLinkingIdentity || !canUnlink(linked))
        } else {
            if provider.id == "apple" {
                appleLinkButton()
            } else {
                Button {
                    linkOAuthProvider(provider.id)
                } label: {
                    Text(L10n.account.link).font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(provider.tint)
                .disabled(state.isLinkingIdentity)
            }
        }
    }

    // MARK: Apple link

    @ViewBuilder
    private func appleLinkButton() -> some View {
        // Nonce is prepared in `.onAppear` and rotated after each completion;
        // the button is disabled while `currentAppleNonce` is nil so Apple auth
        // never starts without one.
        SignInWithAppleButton(.continue) { request in
            guard let nonce = currentAppleNonce else { return }
            localError = nil
            request.requestedScopes = [.email]
            request.nonce = sha256(nonce)
        } onCompletion: { result in
            // Snapshot the nonce before `defer` rotates it — the async Task below
            // would otherwise send the rotated value to Supabase.
            guard let nonce = currentAppleNonce else {
                localError = L10n.auth.appleNonceFailed
                return
            }
            defer { prepareAppleNonce() }
            switch result {
            case .success(let authorization):
                guard
                    let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                    let tokenData = credential.identityToken,
                    let token = String(data: tokenData, encoding: .utf8)
                else {
                    localError = L10n.auth.appleNoToken
                    return
                }
                Task {
                    await state.linkAppleIdentity(identityToken: token, nonce: nonce)
                }
            case .failure(let error):
                let ns = error as NSError
                if ns.code == ASAuthorizationError.canceled.rawValue { return }
                localError = error.localizedDescription
            }
        }
        .signInWithAppleButtonStyle(.whiteOutline)
        .frame(width: 110, height: 30)
        .disabled(state.isLinkingIdentity || currentAppleNonce == nil)
        .onAppear {
            if currentAppleNonce == nil { prepareAppleNonce() }
        }
    }

    /// Preflight: prepare a fresh nonce so the link-Apple button can be
    /// enabled. If preparation fails the button stays disabled — Apple auth
    /// never starts without a valid nonce.
    private func prepareAppleNonce() {
        do {
            currentAppleNonce = try AuthNonce.random()
        } catch {
            currentAppleNonce = nil
            localError = L10n.auth.appleNonceFailed
        }
    }

    // MARK: Google / GitHub link

    private func linkOAuthProvider(_ provider: String) {
        localError = nil
        Task {
            // iter8 hotfix (2026-04-29): mirror the sign-in flow change —
            // PKCE `code_verifier` is the CSRF anchor; client-side `state`
            // is no longer round-tripped because Supabase manages PKCE
            // flow_state server-side.
            guard let (authURL, codeVerifier) = await state.linkIdentityURL(provider: provider) else {
                localError = state.linkIdentityError ?? L10n.auth.linkFailedGeneric
                return
            }
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "clipulse"
            ) { callbackURL, error in
                Task { @MainActor in self.webAuthSession = nil }
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    // Surface the system error description (already user-facing, no callback URL).
                    Task { @MainActor in self.localError = error.localizedDescription }
                    return
                }
                guard let callbackURL else {
                    Task { @MainActor in self.localError = L10n.auth.linkFailedGeneric }
                    return
                }
                switch OAuthCallbackParser.parse(url: callbackURL) {
                case .cancelled:
                    Task { @MainActor in self.localError = L10n.auth.linkCancelled }
                case .failed:
                    // The parser has already stripped raw URL/code from the description,
                    // but for link-flow we still keep messaging generic — mirroring sign-in.
                    Task { @MainActor in self.localError = L10n.auth.linkFailedGeneric }
                case .success(let code):
                    Task {
                        await state.completeLinkIdentity(code: code, codeVerifier: codeVerifier)
                    }
                }
            }
            session.presentationContextProvider = Self.webAuthContextProvider
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
    }

    // MARK: Helpers

    private func linkedIdentity(for provider: String) -> UserIdentity? {
        state.linkedIdentities.first { $0.provider == provider }
    }

    private var errorMessage: String? {
        if let local = localError, !local.isEmpty { return local }
        return state.linkIdentityError
    }

    /// Prevent leaving the account with zero sign-in methods. Email (password + OTP)
    /// counts as a valid sign-in method on CLI Pulse, so the guard is on total count.
    private func canUnlink(_ identity: UserIdentity) -> Bool {
        state.linkedIdentities.count > 1
    }

    private func providerLabel(_ provider: String) -> String {
        switch provider {
        case "apple": return "Apple"
        case "google": return "Google"
        case "github": return "GitHub"
        case "email": return "Email"
        default: return provider.capitalized
        }
    }

    private func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

private final class LinkedAccountsWebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}
