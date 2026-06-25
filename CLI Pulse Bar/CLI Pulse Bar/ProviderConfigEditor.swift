import SwiftUI
import CLIPulseCore
#if os(macOS)
import AuthenticationServices
#endif

/// Editor for per-provider settings (source mode, credentials, account label).
/// Presented in its own Window scene on macOS; dismissed via `@Environment(\.dismiss)`.
struct ProviderConfigEditor: View {
    let kind: ProviderKind
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var sourceMode: SourceType = .auto
    @State private var apiKey: String = ""
    @State private var cookieSource: CookieSource? = nil
    @State private var manualCookieHeader: String = ""
    @State private var accountLabel: String = ""
    #if os(macOS)
    @State private var isGeminiConnected: Bool = false
    @State private var isConnecting: Bool = false
    @State private var geminiError: String?
    @State private var showAPIKey: Bool = false
    @State private var testState: TestConnectionState = .idle
    /// G1: set when a `.automatic` cookie test fails so the manual-paste
    /// fallback field is revealed (animated). Reset on success / source change.
    @State private var autoImportFailed: Bool = false
    // Claude Code keychain-connect state. Mirrors Gemini OAuth pattern but the
    // "prompt" is really the macOS Security framework's cross-app keychain
    // access dialog triggered by SecItemCopyMatching — we don't need any
    // custom OAuth flow, just need the one-time Allow.
    @State private var isClaudeConnected: Bool = false
    @State private var claudeConnectError: String?
    @State private var claudeConnectedEmail: String?
    /// v1.23.0 G3 follow-on: opt-in for the dark CLI-probe fallback
    /// (shipped in PR #45). macOS-only — the probe and this state are
    /// `#if os(macOS)`; the iOS/watch build never sees it.
    @State private var geminiCliProbeFallback: Bool = false
    #endif

    #if os(macOS)
    enum TestConnectionState: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }
    #endif

    private var descriptor: ProviderDescriptor {
        ProviderRegistry.descriptor(for: kind)
    }

    /// G1: `.automatic` browser auto-import is macOS-only (no browser cookie
    /// stores on iOS/watchOS). On other platforms it is hidden so a synced
    /// `.automatic` config simply falls back to manual.
    private var availableCookieSources: [CookieSource] {
        #if os(macOS)
        return CookieSource.allCases
        #else
        return CookieSource.allCases.filter { $0 != .automatic }
        #endif
    }

    #if os(macOS)
    /// True when running inside the App Sandbox (MAS build). The G3
    /// CLI-probe fallback toggle is hidden here: the probe's
    /// subprocess + filesystem OAuth-client discovery is sandbox-
    /// blocked, so the opt-in only has effect on direct-download
    /// (Developer ID) builds (Gemini G3-R1 Q4). Matches the codebase
    /// sandbox idiom (cf. ClaudeSourceStrategy `/Library/Containers/`).
    private var isAppSandboxed: Bool {
        NSHomeDirectory().contains("/Library/Containers/")
    }
    #endif

    /// Manual cookie-header paste field + Keychain notice. Shared by the
    /// `.manual` source and the `.automatic` failure-fallback reveal.
    @ViewBuilder
    private func manualCookieField(label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            #if os(macOS)
            NoAutoFillTextField(placeholder: "session=abc123; ...", text: $manualCookieHeader)
                .frame(minHeight: 22)
                .padding(.vertical, 1)
            #else
            TextField("session=abc123; ...", text: $manualCookieHeader)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 10))
                .textContentType(.none)
            #endif
            HStack(spacing: 3) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green.opacity(0.8))
                Text(L10n.providerConfig.keychainNotice)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: kind.iconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PulseTheme.providerColor(kind.rawValue))
                VStack(alignment: .leading, spacing: 2) {
                    Text(descriptor.displayName)
                        .font(.system(size: 13, weight: .bold))
                    Text(descriptor.category.rawValue)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Divider()

            // Source mode
            HStack {
                Text(L10n.providerConfig.dataSource)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $sourceMode) {
                    ForEach(descriptor.supportedSources, id: \.self) { src in
                        Text(src.rawValue).tag(src)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 100)
            }

            // Account label
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.providerConfig.accountLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                #if os(macOS)
                NoAutoFillTextField(placeholder: "e.g. team-A, dev-box", text: $accountLabel)
                    .frame(minHeight: 22)
                    .padding(.vertical, 1)
                #else
                TextField(L10n.providerConfig.accountPlaceholder, text: $accountLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .textContentType(.none)
                #endif
            }

            // API key (only if provider supports api/oauth)
            if descriptor.supportedSources.contains(.api) || descriptor.supportedSources.contains(.oauth) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.providerConfig.apiKey)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    #if os(macOS)
                    HStack(spacing: 4) {
                        if showAPIKey {
                            NoAutoFillTextField(placeholder: "sk-...", text: $apiKey)
                                .frame(minHeight: 22)
                        } else {
                            NoAutoFillSecureField(placeholder: "sk-...", text: $apiKey)
                                .frame(minHeight: 22)
                        }
                        Button {
                            showAPIKey.toggle()
                        } label: {
                            Image(systemName: showAPIKey ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(showAPIKey ? L10n.providerConfig.hideKey : L10n.providerConfig.showKey)
                    }
                    .padding(.vertical, 1)
                    #else
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 10))
                        .textContentType(.none)
                    #endif
                    // v1.9.4: surface the privacy guarantee at the exact
                    // moment the user is about to paste a secret. Matches
                    // the public "API keys stay on device" claim.
                    HStack(spacing: 3) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.green.opacity(0.8))
                        Text(L10n.providerConfig.keychainNotice)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Cookie source (only if provider supports web)
            if descriptor.supportedSources.contains(.web) {
                HStack {
                    Text(L10n.providerConfig.cookieSource)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { cookieSource ?? .safari },
                        set: { cookieSource = $0 }
                    )) {
                        ForEach(availableCookieSources, id: \.self) { src in
                            Text(src.rawValue).tag(src)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 100)
                }

                if cookieSource == .automatic {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 3) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 8))
                                .foregroundStyle(PulseTheme.accent)
                            Text(L10n.providerConfig.autoImportNote)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if autoImportFailed {
                            manualCookieField(label: L10n.providerConfig.autoImportFailed)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                if cookieSource == .manual {
                    manualCookieField(label: L10n.providerConfig.manualCookieHeader)
                }
            }

            // Gemini OAuth connection (macOS only)
            #if os(macOS)
            if kind == .gemini {
                geminiOAuthSection
            }
            // Claude Code keychain bootstrap (macOS only). The sandbox can't
            // read Claude Code's keychain item on its own — it needs the user
            // to click Allow on the system prompt. This button surfaces the
            // prompt deliberately instead of hoping it fires during a silent
            // OAuth-strategy attempt.
            if kind == .claude {
                claudeConnectSection
            }
            testConnectionRow
            #endif

            // Capabilities summary
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.providerConfig.capabilities)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    capBadge(L10n.providerConfig.capQuota, active: descriptor.supportsQuota)
                    capBadge(L10n.providerConfig.capExactCost, active: descriptor.supportsExactCost)
                    capBadge(L10n.providerConfig.capCredits, active: descriptor.supportsCredits)
                    capBadge(L10n.providerConfig.capStatusPoll, active: descriptor.supportsStatusPolling)
                }
                if descriptor.requiresHelperBackend {
                    Text(L10n.providerConfig.requiresHelperSync)
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Actions
            HStack {
                Button(L10n.common.cancel) { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.common.save) {
                    save()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
                .controlSize(.small)
            }
        }
        .padding(16)
        .onAppear { loadFromConfig() }
        #if os(macOS)
        .onChange(of: apiKey) { _ in testState = .idle }
        .onChange(of: manualCookieHeader) { _ in testState = .idle }
        .onChange(of: sourceMode) { _ in testState = .idle }
        .onChange(of: cookieSource) { _ in
            testState = .idle
            withAnimation { autoImportFailed = false }
        }
        #endif
    }

    private func capBadge(_ label: String, active: Bool) -> some View {
        Text(label)
            .font(.system(size: 7, weight: .medium))
            .foregroundColor(active ? .green : .gray)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background((active ? Color.green : Color.gray).opacity(0.1))
            .clipShape(Capsule())
    }

    private func loadFromConfig() {
        guard let idx = state.providerConfigs.firstIndex(where: { $0.kind == kind }) else { return }
        let config = state.providerConfigs[idx]
        sourceMode = config.sourceMode
        apiKey = config.apiKey ?? ""
        cookieSource = config.cookieSource
        manualCookieHeader = config.manualCookieHeader ?? ""
        accountLabel = config.accountLabel ?? ""
        #if os(macOS)
        // Cursor auto-imports its browser session cookie by default. Surface
        // that as an explicit `.automatic` selection when the user has never
        // chosen a source, so the picker, the auto-import note, and Test
        // Connection all reflect the real (default-ON) behavior. The user can
        // still pick Manual/Safari/etc. to turn auto-import off.
        if kind == .cursor, config.cookieSource == nil {
            cookieSource = .automatic
        }
        if kind == .gemini {
            isGeminiConnected = GeminiOAuthManager.shared.isConnected
            geminiCliProbeFallback = config.geminiCliProbeFallback ?? false
        }
        if kind == .claude {
            loadClaudeConnectState()
        }
        #endif
    }

    // MARK: - Gemini OAuth

    #if os(macOS)
    @ViewBuilder
    private var geminiOAuthSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.providerConfig.googleOAuth)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if isGeminiConnected {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text(L10n.settings.connected)
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Spacer()
                    Button(L10n.providerConfig.disconnect) {
                        GeminiOAuthManager.shared.clearTokens()
                        isGeminiConnected = false
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.system(size: 10))
                }
            } else {
                Button {
                    isConnecting = true
                    geminiError = nil
                    Task { @MainActor in
                        defer { isConnecting = false }
                        do {
                            _ = try await GeminiOAuthManager.shared.authorize()
                            isGeminiConnected = true
                        } catch is CancellationError {
                            // User cancelled — ignore
                        } catch let e as ASWebAuthenticationSessionError
                                    where e.code == .canceledLogin {
                            // User dismissed the browser sheet — ignore
                        } catch {
                            geminiError = error.localizedDescription
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "link")
                        }
                        Text(L10n.providerConfig.connectGemini)
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .controlSize(.small)
                .disabled(isConnecting)

                if let err = geminiError {
                    Text(err)
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                } else {
                    Text(L10n.providerConfig.geminiUsesGoogle)
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }
            }

            // v1.23.0 G3 follow-on: surface the CLI-probe fallback
            // opt-in (shipped dark in PR #45). Hidden on sandboxed/MAS
            // builds — the probe's subprocess + filesystem OAuth-client
            // discovery is sandbox-blocked, so this only has effect on
            // direct-download (Developer ID) builds (Gemini G3-R1 Q4),
            // and a visible-but-dead switch on MAS would be misleading.
            if !isAppSandboxed {
                Divider().padding(.vertical, 2)
                Toggle(isOn: $geminiCliProbeFallback) {
                    Text(L10n.providerConfig.geminiCliFallback)
                        .font(.system(size: 10))
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                Text(L10n.providerConfig.geminiCliFallbackNote)
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    #if os(macOS)
    private var claudeConnectSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.providerConfig.claudeCode)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if isClaudeConnected {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.settings.connected)
                            .font(.system(size: 10))
                            .foregroundStyle(.green)
                        if let email = claudeConnectedEmail {
                            Text(email)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Button(L10n.providerConfig.disconnect) {
                        ClaudeCredentials.clearCachedKeychainCredentials()
                        isClaudeConnected = false
                        claudeConnectedEmail = nil
                        claudeConnectError = nil
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .font(.system(size: 10))
                }
            } else {
                Button {
                    isConnecting = true
                    claudeConnectError = nil
                    // `readKeychainCredentials` triggers the macOS system
                    // prompt when the app hasn't yet been allowed to read
                    // the cross-app keychain item. SecItemCopyMatching is
                    // SYNCHRONOUSLY blocking while the user decides on the
                    // dialog — must be off the main actor or the UI
                    // beach-balls (Gemini 3.1 Pro review 2026-04-23).
                    // Read the credentials on a detached task and hop back
                    // to the main actor only for the @State mutations.
                    Task.detached {
                        // User-initiated Connect — bypass the cross-app read
                        // cooldown so a reconnect/re-auth is never blocked by a
                        // cooldown a background 401 may have armed.
                        let creds = ClaudeCredentials.readKeychainCredentials(bypassCooldown: true)
                        await MainActor.run {
                            isConnecting = false
                            if let creds, !creds.accessToken.isEmpty {
                                isClaudeConnected = true
                                claudeConnectedEmail = nil  // email not in credentials; will populate on next fetch
                                claudeConnectError = nil
                            } else {
                                claudeConnectError = L10n.providerConfig.claudeReadFailed
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isConnecting {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "key.fill")
                        }
                        Text(L10n.providerConfig.connectClaudeCode)
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                .disabled(isConnecting)

                if let err = claudeConnectError {
                    Text(err)
                        .font(.system(size: 8))
                        .foregroundStyle(.red)
                } else {
                    Text(L10n.providerConfig.claudeKeychainHint)
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }
            }
        }
    }

    /// Refresh the "connected" visual based on the app-keychain cache.
    /// We only show "Connected" when the cache is populated — if the cache
    /// is empty but the cross-app keychain would succeed on prompt, we still
    /// show the Connect button so the user knows they need to click once.
    /// Uses the cache-only peek so this never triggers a prompt.
    private func loadClaudeConnectState() {
        guard kind == .claude else { return }
        if let creds = ClaudeCredentials.readCachedKeychainCredentials(),
           !creds.accessToken.isEmpty {
            isClaudeConnected = true
        } else {
            isClaudeConnected = false
        }
    }
    #endif

    // MARK: - Test connection

    @ViewBuilder
    private var testConnectionRow: some View {
        HStack(spacing: 6) {
            Button {
                testState = .testing
                Task { await runTest() }
            } label: {
                HStack(spacing: 3) {
                    if case .testing = testState {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                    }
                    Text(L10n.providerConfig.testConnection)
                        .font(.system(size: 10, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(testState == .testing)

            switch testState {
            case .idle:
                EmptyView()
            case .testing:
                Text(L10n.providerConfig.testing)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            case .success(let msg):
                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 10))
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                        .lineLimit(2)
                }
            case .failure(let msg):
                HStack(spacing: 3) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 10))
                    Text(msg)
                        .font(.system(size: 9))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            Spacer()
        }
        .padding(.top, 2)
    }

    @MainActor
    private func runTest() async {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let probeConfig = ProviderConfig(
            kind: kind,
            isEnabled: true,
            sourceMode: sourceMode,
            apiKey: trimmedKey.isEmpty ? nil : trimmedKey,
            cookieSource: cookieSource,
            manualCookieHeader: manualCookieHeader.isEmpty ? nil : manualCookieHeader,
            accountLabel: accountLabel.isEmpty ? nil : accountLabel
        )

        guard let collector = CollectorRegistry.collector(for: kind, config: probeConfig) else {
            testState = .failure("No collector available. Check credentials or source mode.")
            return
        }

        let start = Date()
        do {
            let result = try await collector.collect(config: probeConfig)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            let summary: String
            switch result.dataKind {
            case .quota:
                let rem = result.usage.remaining.map { "\($0)" } ?? "—"
                summary = "OK (\(ms)ms) remaining: \(rem)"
            case .credits:
                summary = "OK (\(ms)ms) credits fetched"
            case .statusOnly:
                summary = "OK (\(ms)ms) status reachable"
            }
            testState = .success(summary)
            withAnimation { autoImportFailed = false }
        } catch {
            testState = .failure(error.localizedDescription)
            if cookieSource == .automatic {
                withAnimation { autoImportFailed = true }
            }
        }
    }
    #endif

    private func save() {
        guard let idx = state.providerConfigs.firstIndex(where: { $0.kind == kind }) else { return }
        state.providerConfigs[idx].sourceMode = sourceMode
        state.providerConfigs[idx].accountLabel = accountLabel.isEmpty ? nil : accountLabel
        state.providerConfigs[idx].cookieSource = cookieSource
        state.providerConfigs[idx].apiKey = apiKey.isEmpty ? nil : apiKey
        state.providerConfigs[idx].manualCookieHeader = manualCookieHeader.isEmpty ? nil : manualCookieHeader
        #if os(macOS)
        // v1.23.0 G3 follow-on: persist nil when off / non-Gemini so
        // legacy configs stay byte-identical (dark-safe; Gemini G3-R1
        // HIGH — encodeIfPresent omits the key). Wrapped #if os(macOS)
        // because `geminiCliProbeFallback` @State is macOS-only —
        // keeps the iOS/watch build green (Gemini G3-R1 CRITICAL).
        state.providerConfigs[idx].geminiCliProbeFallback =
            (kind == .gemini && geminiCliProbeFallback) ? true : nil
        #endif
        state.saveProviderConfigs()
    }
}
