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
                Text("Data source")
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
                Text("Account label")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                #if os(macOS)
                NoAutoFillTextField(placeholder: "e.g. team-A, dev-box", text: $accountLabel)
                    .frame(minHeight: 22)
                    .padding(.vertical, 1)
                #else
                TextField("e.g. team-A, dev-box", text: $accountLabel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                    .textContentType(.none)
                #endif
            }

            // API key (only if provider supports api/oauth)
            if descriptor.supportedSources.contains(.api) || descriptor.supportedSources.contains(.oauth) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("API key")
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
                        .help(showAPIKey ? "Hide key" : "Show key")
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
                        Text("Stored only in your Mac Keychain. Never uploaded.")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Cookie source (only if provider supports web)
            if descriptor.supportedSources.contains(.web) {
                HStack {
                    Text("Cookie source")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { cookieSource ?? .safari },
                        set: { cookieSource = $0 }
                    )) {
                        ForEach(CookieSource.allCases, id: \.self) { src in
                            Text(src.rawValue).tag(src)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 100)
                }

                if cookieSource == .manual {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Manual cookie header")
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
                            Text("Stored only in your Mac Keychain. Never uploaded.")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Gemini OAuth connection (macOS only)
            #if os(macOS)
            if kind == .gemini {
                geminiOAuthSection
            }
            testConnectionRow
            #endif

            // Capabilities summary
            VStack(alignment: .leading, spacing: 3) {
                Text("Capabilities")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    capBadge("Quota", active: descriptor.supportsQuota)
                    capBadge("Exact cost", active: descriptor.supportsExactCost)
                    capBadge("Credits", active: descriptor.supportsCredits)
                    capBadge("Status poll", active: descriptor.supportsStatusPolling)
                }
                if descriptor.requiresHelperBackend {
                    Text("Quota/tier data requires backend helper sync.")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            // Actions
            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
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
        if kind == .gemini {
            isGeminiConnected = GeminiOAuthManager.shared.isConnected
        }
        #endif
    }

    // MARK: - Gemini OAuth

    #if os(macOS)
    @ViewBuilder
    private var geminiOAuthSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Google OAuth")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)

            if isGeminiConnected {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("Connected")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
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
                        Text("Connect Gemini")
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
                    Text("Uses your Google account. No API key needed.")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                }
            }
        }
    }

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
                    Text("Test connection")
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
                Text("Testing…")
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
        } catch {
            testState = .failure(error.localizedDescription)
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
        state.saveProviderConfigs()
    }
}
