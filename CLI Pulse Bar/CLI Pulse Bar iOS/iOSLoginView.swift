import SwiftUI
import AuthenticationServices
import CryptoKit
import CLIPulseCore
import os

struct iOSLoginView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @State private var email = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var currentNonce: String?
    @State private var webAuthSession: ASWebAuthenticationSession?
    @FocusState private var codeFieldFocused: Bool

    private static let webAuthContextProvider = WebAuthContextProvider()

    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashed = SHA256.hash(data: inputData)
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }

    /// Preflight: prepare a fresh nonce so the SignInWithAppleButton can be
    /// enabled. If preparation fails we leave `currentNonce` nil, which keeps
    /// the button disabled — Apple auth never starts without a valid nonce.
    private func prepareNonce() {
        do {
            currentNonce = try AuthNonce.random()
        } catch {
            currentNonce = nil
            state.lastError = L10n.auth.appleNonceFailed
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    // Logo area
                    VStack(spacing: 12) {
                        Image(systemName: "waveform.path.ecg")
                            .font(.system(size: 56, weight: .light))
                            .foregroundStyle(PulseTheme.accent)

                        Text(L10n.auth.title)
                            .font(.system(size: 28, weight: .bold, design: .rounded))

                        Text(L10n.auth.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    // Sign in with Apple. Nonce is prepared in `.onAppear` and
                    // rotated after each completion; the button is disabled while
                    // `currentNonce` is nil so Apple auth never starts without one.
                    SignInWithAppleButton(.signIn) { request in
                        guard let nonce = currentNonce else { return }
                        request.requestedScopes = [.fullName, .email]
                        request.nonce = sha256(nonce)
                    } onCompletion: { result in
                        // Snapshot the nonce before `defer` rotates it — the async Task
                        // below would otherwise send the rotated value to Supabase.
                        guard let nonce = currentNonce else {
                            state.lastError = L10n.auth.appleNonceFailed
                            return
                        }
                        defer { prepareNonce() }
                        switch result {
                        case .success(let authorization):
                            if let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                               let identityTokenData = appleIDCredential.identityToken,
                               let identityToken = String(data: identityTokenData, encoding: .utf8) {
                                let fullName = [appleIDCredential.fullName?.givenName, appleIDCredential.fullName?.familyName]
                                    .compactMap { $0 }
                                    .joined(separator: " ")
                                Task {
                                    await state.signInWithApple(
                                        identityToken: identityToken,
                                        nonce: nonce,
                                        fullName: fullName.isEmpty ? nil : fullName,
                                        email: appleIDCredential.email
                                    )
                                }
                            }
                        case .failure(let error):
                            state.lastError = error.localizedDescription
                        }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(height: 50)
                    .disabled(currentNonce == nil)
                    .padding(.horizontal)

                    // Sign in with Google (via Supabase OAuth)
                    Button {
                        signInWithProvider("google")
                    } label: {
                        HStack {
                            Image(systemName: "globe")
                            Text(L10n.auth.signInGoogle)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .padding(.horizontal)

                    // Sign in with GitHub
                    Button {
                        signInWithProvider("github")
                    } label: {
                        HStack {
                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                            Text(L10n.auth.signInGithub)
                                .font(.headline)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(red: 0.14, green: 0.16, blue: 0.22))
                    .padding(.horizontal)

                    if let error = state.lastError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding(.horizontal)
                    }

                    // Divider
                    HStack {
                        Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                        Text(L10n.auth.or)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Rectangle().frame(height: 1).foregroundStyle(.quaternary)
                    }
                    .padding(.horizontal)

                    // OTP Email flow
                    if state.otpSent {
                        // Step 2: Enter verification code
                        otpVerifyView
                    } else {
                        // Step 1: Enter email
                        emailEntryView
                    }

                    // Demo mode
                    Button {
                        state.enterDemoMode()
                    } label: {
                        HStack {
                            Image(systemName: "play.circle.fill")
                            Text(L10n.auth.tryDemo)
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .padding(.horizontal)
                }
            }
            .navigationTitle(L10n.auth.welcome)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                email = ""
                password = ""
                otpCode = ""
                state.lastError = nil
                if currentNonce == nil { prepareNonce() }
            }
            .onChange(of: authState.isAuthenticated) { _, isAuth in
                if !isAuth {
                    email = ""
                    password = ""
                    otpCode = ""
                    state.resetOTP()
                }
            }
        }
    }

    // MARK: - OAuth Sign-In (Google / GitHub) via ASWebAuthenticationSession + PKCE

    private func signInWithProvider(_ provider: String) {
        Task {
            guard let (authURL, codeVerifier, expectedState) = await state.oauthURL(provider: provider) else {
                state.lastError = L10n.auth.signInFailedGeneric
                return
            }
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "clipulse"
            ) { [weak state] callbackURL, error in
                Task { @MainActor in
                    self.webAuthSession = nil
                }
                if let error {
                    if (error as NSError).code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        return
                    }
                    Task { @MainActor in state?.lastError = error.localizedDescription }
                    return
                }
                guard let callbackURL else {
                    Task { @MainActor in state?.lastError = L10n.auth.signInFailedGeneric }
                    return
                }
                switch OAuthCallbackParser.parse(url: callbackURL) {
                case .cancelled:
                    Task { @MainActor in state?.lastError = L10n.auth.signInCancelled }
                case .failed(let description):
                    // iter8 hotfix: surface the parser's description (already
                    // sanitised — raw URL/code/state are stripped server-side
                    // by OAuthCallbackParser). Helps the user (or us during
                    // smoke testing) tell apart "redirect_to mismatch" vs
                    // "state missing" vs "code missing" vs the generic case.
                    // Falls back to the generic L10n string if description
                    // is somehow empty.
                    let safeDetail = description.isEmpty
                        ? L10n.auth.signInFailedGeneric
                        : "\(L10n.auth.signInFailedGeneric) (\(description))"
                    Task { @MainActor in state?.lastError = safeDetail }
                case .success(let code, let returnedState):
                    guard returnedState == expectedState else {
                        Task { @MainActor in state?.lastError = L10n.auth.signInFailedStateMismatch }
                        return
                    }
                    Task { await state?.exchangeOAuthCode(code: code, codeVerifier: codeVerifier) }
                }
            }
            session.presentationContextProvider = Self.webAuthContextProvider
            session.prefersEphemeralWebBrowserSession = false
            self.webAuthSession = session
            session.start()
        }
    }

    // MARK: - Step 1: Email Entry

    private var emailEntryView: some View {
        VStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.settings.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.login.emailPlaceholder, text: $email)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.auth.passwordOptional)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SecureField(L10n.auth.passwordPlaceholder, text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Button {
                Task {
                    if !password.isEmpty {
                        await state.signInWithPassword(email: email, password: password)
                    } else {
                        await state.sendOTP(email: email)
                    }
                }
            } label: {
                HStack {
                    if state.isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(password.isEmpty ? L10n.auth.sendCode : L10n.settings.signIn)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(email.isEmpty || !email.contains("@") || state.isLoading)
            .padding(.horizontal)
        }
    }

    // MARK: - Step 2: OTP Verification

    private var otpVerifyView: some View {
        VStack(spacing: 16) {
            // Success indicator
            VStack(spacing: 8) {
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(PulseTheme.accent)

                Text(L10n.auth.codeSentTo(state.otpEmail))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.auth.enterCode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField(L10n.auth.codePlaceholder, text: $otpCode)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    .focused($codeFieldFocused)
                    .onAppear { codeFieldFocused = true }
            }
            .padding(.horizontal)

            Button {
                Task { await state.verifyOTP(code: otpCode) }
            } label: {
                HStack {
                    if state.isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(L10n.auth.verifyCode)
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isLoading)
            .padding(.horizontal)

            HStack(spacing: 16) {
                Button {
                    otpCode = ""
                    state.resetOTP()
                } label: {
                    Text(L10n.auth.backToEmail)
                        .font(.subheadline)
                }

                Button {
                    otpCode = ""
                    Task { await state.sendOTP(email: state.otpEmail) }
                } label: {
                    Text(L10n.auth.resendCode)
                        .font(.subheadline)
                }
            }
            .foregroundStyle(PulseTheme.accent)
        }
    }
}

// MARK: - ASWebAuthenticationSession Presentation Context

private class WebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first(where: { $0.isKeyWindow }) ?? scene.windows.first else {
            return ASPresentationAnchor()
        }
        return window
    }
}
