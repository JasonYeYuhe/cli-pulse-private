import Foundation

// MARK: - Auth Notification Names

public extension Notification.Name {
    /// Posted when the user successfully authenticates. UserInfo contains access_token, refresh_token, email, name.
    static let cliPulseDidAuthenticate = Notification.Name("cliPulseDidAuthenticate")
    /// Posted when the user signs out.
    static let cliPulseDidSignOut = Notification.Name("cliPulseDidSignOut")
    /// Posted by AppState after `refreshAll()` finishes. Listeners (e.g. the
    /// iOS WCSession bridge) can forward the freshly-loaded dashboard state to
    /// the paired Apple Watch. No userInfo — observers pull from AppState.
    static let cliPulseDidRefresh = Notification.Name("cliPulseDidRefresh")
}

public struct AuthSessionState {
    public let userId: String
    public let userName: String
    public let userEmail: String
    public let isPaired: Bool
}

public struct OTPFlowState {
    public let otpSent: Bool
    public let otpEmail: String
    public let lastError: String?
}

public enum RestoreSessionResult {
    case demoMode
    case restored(AuthSessionState)
    case unavailable
    case failed
}

@MainActor
public final class AuthManager {
    nonisolated static let refreshTokenKeychainKey = "cli_pulse_refresh_token"

    private let api: APIClient
    private let persistTokens: (String, String?) -> Void

    public init(api: APIClient, persistTokens: @escaping (String, String?) -> Void) {
        self.api = api
        self.persistTokens = persistTokens
    }

    public func sendOTP(email: String) async throws -> String {
        try await api.sendOTP(email: email)
        return email
    }

    public func verifyOTP(email: String, code: String) async throws -> AuthSessionState {
        let response = try await api.verifyOTP(email: email, code: code)
        storeAuthTokens(access: response.access_token, refresh: response.refresh_token)
        return authSessionState(from: response)
    }

    func signInWithApple(identityToken: String, nonce: String?, fullName: String?, email: String?) async throws -> AuthSessionState {
        let response = try await api.signInWithApple(identityToken: identityToken, nonce: nonce, fullName: fullName, email: email)
        storeAuthTokens(access: response.access_token, refresh: response.refresh_token)
        return authSessionState(from: response)
    }

    func signInWithPassword(email: String, password: String) async throws -> AuthSessionState {
        let response = try await api.signInWithPassword(email: email, password: password)
        storeAuthTokens(access: response.access_token, refresh: response.refresh_token)
        return authSessionState(from: response)
    }

    public func resetOTP() -> OTPFlowState {
        OTPFlowState(otpSent: false, otpEmail: "", lastError: nil)
    }

    public func restoreSession(isDemoMode: Bool, accessToken: String, refreshToken: String?) async -> RestoreSessionResult {
        if isDemoMode {
            return .demoMode
        }

        guard !accessToken.isEmpty else {
            return .unavailable
        }

        await api.updateToken(accessToken)
        await api.updateRefreshToken(refreshToken)

        do {
            let response = try await api.me()
            storeAuthTokens(access: response.access_token, refresh: response.refresh_token)
            return .restored(authSessionState(from: response))
        } catch {
            storeAuthTokens(access: "", refresh: nil)
            await api.updateToken(nil)
            await api.updateRefreshToken(nil)
            return .failed
        }
    }

    public func signOut(currentAccessToken: String) async {
        // Attempt server-side token revocation
        await api.signOutServer()
        // Only clear tokens if they haven't been replaced by a new sign-in
        let storedToken = KeychainHelper.load(key: AppState.tokenKeychainKey)
        if storedToken == nil || storedToken == currentAccessToken || storedToken?.isEmpty == true {
            storeAuthTokens(access: "", refresh: nil)
        }
    }

    func deleteAccount() async throws {
        try await api.deleteAccount()
        storeAuthTokens(access: "", refresh: nil)
    }

    func signInWithGoogle(idToken: String, name: String?, email: String?) async throws -> AuthSessionState {
        let response = try await api.signInWithGoogle(idToken: idToken, name: name, email: email)
        storeAuthTokens(access: response.access_token, refresh: response.refresh_token)
        return authSessionState(from: response)
    }

    func exchangeOAuthCode(code: String, codeVerifier: String) async throws -> AuthSessionState {
        let response = try await api.exchangeOAuthCode(code: code, codeVerifier: codeVerifier)
        storeAuthTokens(access: response.access_token, refresh: response.refresh_token)
        return authSessionState(from: response)
    }

    func storeAuthTokens(access: String, refresh: String?) {
        persistTokens(access, refresh)
    }

    private func authSessionState(from response: AuthResponse) -> AuthSessionState {
        AuthSessionState(
            userId: response.user.id,
            userName: response.user.name,
            userEmail: response.user.email,
            isPaired: response.paired
        )
    }
}

extension AppState {
    public func sendOTP(email: String) async {
        isLoading = true
        lastError = nil
        do {
            otpEmail = try await authManager.sendOTP(email: email)
            otpSent = true
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    public func verifyOTP(code: String) async {
        isLoading = true
        lastError = nil
        do {
            let session = try await authManager.verifyOTP(email: otpEmail, code: code)
            applyAuthenticatedState(session)
            otpSent = false
            otpEmail = ""
            startRefreshLoop()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    public func signInWithPassword(email: String, password: String) async {
        isLoading = true
        lastError = nil
        do {
            let session = try await authManager.signInWithPassword(email: email, password: password)
            applyAuthenticatedState(session)
            startRefreshLoop()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    public func resetOTP() {
        let state = authManager.resetOTP()
        otpSent = state.otpSent
        otpEmail = state.otpEmail
        lastError = state.lastError
    }

    public func signInWithApple(identityToken: String, nonce: String? = nil, fullName: String?, email: String?) async {
        isLoading = true
        lastError = nil
        do {
            let session = try await authManager.signInWithApple(
                identityToken: identityToken,
                nonce: nonce,
                fullName: fullName,
                email: email
            )
            applyAuthenticatedState(session)
            startRefreshLoop()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// Sign in with a Google ID token (from Google Sign-In SDK or Credential Manager).
    public func signInWithGoogle(idToken: String, name: String?, email: String?) async {
        isLoading = true
        lastError = nil
        do {
            let session = try await authManager.signInWithGoogle(idToken: idToken, name: name, email: email)
            applyAuthenticatedState(session)
            startRefreshLoop()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// Exchange an OAuth authorization code (from GitHub ASWebAuthenticationSession) for a session.
    public func exchangeOAuthCode(code: String, codeVerifier: String) async {
        isLoading = true
        lastError = nil
        do {
            let authState = try await authManager.exchangeOAuthCode(code: code, codeVerifier: codeVerifier)
            applyAuthenticatedState(authState)
            startRefreshLoop()
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
        isLoading = false
    }

    /// Build an OAuth URL for a given provider (PKCE flow).
    /// Returns (url, codeVerifier).
    ///
    /// CSRF protection comes from the PKCE `code_verifier` — only the client
    /// that generated the verifier can complete the token exchange. The
    /// `state` query param was removed in the iter8 hotfix because it
    /// conflicted with Supabase's server-side PKCE flow_state management.
    /// See `APIClient.oauthAuthorizeURL` for the full rationale.
    public func oauthURL(provider: String) async -> (URL, String)? {
        let redirectTo = "clipulse://auth/callback"
        return await api.oauthAuthorizeURL(provider: provider, redirectTo: redirectTo)
    }

    // MARK: - Identity Linking

    /// Refresh the list of identities linked to the current user.
    public func refreshLinkedIdentities() async {
        guard isAuthenticated, !isDemoMode else {
            linkedIdentities = []
            return
        }
        do {
            linkedIdentities = try await api.userIdentities()
        } catch {
            // Non-fatal — just log; UI will show empty list
            linkIdentityError = error.localizedDescription
        }
    }

    /// Build a link-identity OAuth authorization URL (PKCE) for Google/GitHub.
    /// Returns (url, codeVerifier). Caller opens in ASWebAuthenticationSession,
    /// then calls `completeLinkIdentity(code:codeVerifier:)`. The `code_verifier`
    /// alone provides CSRF protection — see `APIClient.linkIdentityAuthorizeURL`
    /// for the iter8 rationale on dropping client-side `state`.
    public func linkIdentityURL(provider: String) async -> (URL, String)? {
        do {
            let redirectTo = "clipulse://auth/callback"
            return try await api.linkIdentityAuthorizeURL(provider: provider, redirectTo: redirectTo)
        } catch {
            linkIdentityError = error.localizedDescription
            return nil
        }
    }

    /// Complete a link-identity flow by exchanging the returned PKCE code.
    public func completeLinkIdentity(code: String, codeVerifier: String) async {
        isLinkingIdentity = true
        linkIdentityError = nil
        do {
            try await api.exchangeOAuthCodeForLink(code: code, codeVerifier: codeVerifier)
            await refreshLinkedIdentities()
        } catch {
            linkIdentityError = error.localizedDescription
        }
        isLinkingIdentity = false
    }

    /// Link an Apple identity using an Apple identity token.
    public func linkAppleIdentity(identityToken: String, nonce: String?) async {
        isLinkingIdentity = true
        linkIdentityError = nil
        do {
            try await api.linkAppleIdentity(identityToken: identityToken, nonce: nonce)
            await refreshLinkedIdentities()
        } catch {
            linkIdentityError = error.localizedDescription
        }
        isLinkingIdentity = false
    }

    /// Unlink an identity. Supabase refuses to unlink the only remaining identity.
    public func unlinkIdentity(_ identity: UserIdentity) async {
        isLinkingIdentity = true
        linkIdentityError = nil
        do {
            try await api.unlinkIdentity(identityId: identity.id)
            await refreshLinkedIdentities()
        } catch {
            linkIdentityError = error.localizedDescription
        }
        isLinkingIdentity = false
    }

    public func generatePairingCode() async {
        isLoading = true
        pairingError = nil
        do {
            pairingInfo = try await api.pairingCode()
        } catch {
            pairingError = error.localizedDescription
        }
        isLoading = false
    }

    public func checkPairingStatus() async {
        isLoading = true
        pairingError = nil
        do {
            let response = try await api.me()
            isPaired = response.paired
            if isPaired {
                pairingInfo = nil
                startRefreshLoop()
                await refreshAll()
            } else {
                pairingError = L10n.onboarding.helperNotConnectedYet
            }
        } catch {
            pairingError = error.localizedDescription
        }
        isLoading = false
    }

    public func signOut() {
        stopRefreshLoop()
        dataRefreshManager.cancelInFlightRefresh()
        // Best-effort: drop the user's APNs token from app_push_tokens so
        // their pending requests stop pushing to this device after logout.
        // Server-side ON CONFLICT(token) on the next user's
        // register_app_push_token would transfer ownership anyway, but
        // that only protects same-device-different-user; explicit unregister
        // also handles "user logs out and never logs back in".
        // No-op when registeredPushToken is nil; never blocks logout
        // because the implementation just spawns a Task and swallows errors.
        unregisterPushTokenOnLogout()
        // Capture current token so async logout only clears the right session
        let currentToken = storedToken
        Task { await authManager.signOut(currentAccessToken: currentToken) }
        // Clear local state immediately — don't block on network
        isDemoMode = false
        applySignedOutState()
        // Notify iOS companion to forward logout to watch
        NotificationCenter.default.post(name: .cliPulseDidSignOut, object: nil)
    }

    /// Delete the user's account. Returns `true` on confirmed server-side
    /// success, `false` if the API call failed. On failure, the caller
    /// MUST inspect `lastError` and surface it — the previous version of
    /// this method silently swallowed errors and called `signOut()` even
    /// in the catch branch, which made the user think the delete worked
    /// when it hadn't (iter10 user feedback: "delete account 无效").
    ///
    /// iter11 hotfix (2026-04-29): split the failure handling into two
    /// branches via `DeleteAccountFailure.classify`:
    ///   - `.sessionExpired`: the eager pre-RPC refresh failed (or any
    ///     downstream call surfaced `tokenExpired`). The APIClient has
    ///     already nil'd its in-memory tokens at this point, so the UI
    ///     state ("you're signed in") no longer matches the API state
    ///     ("you have no tokens"). We reconcile by signing out, then
    ///     stash a clear "Session expired during account deletion"
    ///     message into `lastError` *after* `signOut` clears it — so
    ///     the login screen explains what happened.
    ///   - `.other`: the server actively refused the delete (HTTP 4xx,
    ///     RLS violation, FK conflict, network failure). Session is
    ///     intact (or recoverable on next refresh). Show the error in
    ///     place; user can retry without re-authenticating.
    @discardableResult
    public func deleteAccount() async -> Bool {
        isLoading = true
        lastError = nil
        do {
            try await authManager.deleteAccount()
            // Server confirmed deletion. Now safe to clear local state.
            isLoading = false
            signOut()
            return true
        } catch {
            switch DeleteAccountFailure.classify(error) {
            case .sessionExpired:
                // Refresh failed → APIClient tokens already nil. Reconcile
                // UI: sign out (clears in-memory state) and then re-set
                // `lastError` so the login screen surfaces the reason.
                isLoading = false
                signOut()
                lastError = L10n.account.deleteSessionExpired
                return false
            case .other(let message):
                // Server side did NOT confirm. Surface the error and keep
                // the session intact so the user can retry without first
                // having to sign in again. (Pre-iter10 this still fell
                // through to a local signOut, which was misleading: the
                // account row was intact server-side but the user was
                // signed out.)
                lastError = message
                isLoading = false
                return false
            }
        }
    }

    public func restoreSession() async {
        switch await authManager.restoreSession(
            isDemoMode: isDemoMode,
            accessToken: storedToken,
            refreshToken: storedRefreshToken
        ) {
        case .demoMode:
            enterDemoMode()
        case .restored(let session):
            isLoading = true
            applyAuthenticatedState(session)
            serverOnline = true
            isLoading = false
            await subscriptionManager.updateCurrentEntitlements()
            // Tier is now known — safe to run the one-shot free-tier provider
            // migration. See `migrateProviderLimitsIfNeeded` for ranking logic.
            migrateProviderLimitsIfNeeded()
            startRefreshLoop()
            await refreshAll()
        case .unavailable:
            break
        case .failed:
            applySignedOutState()
        }
    }

    var storedRefreshToken: String? {
        KeychainHelper.load(key: AuthManager.refreshTokenKeychainKey)
    }

    nonisolated static func persistAuthTokens(access: String, refresh: String?) {
        if access.isEmpty {
            KeychainHelper.delete(key: Self.tokenKeychainKey)
        } else {
            KeychainHelper.save(key: Self.tokenKeychainKey, value: access)
        }

        if let refresh, !refresh.isEmpty {
            KeychainHelper.save(key: AuthManager.refreshTokenKeychainKey, value: refresh)
        } else {
            KeychainHelper.delete(key: AuthManager.refreshTokenKeychainKey)
        }

        UserDefaults.standard.removeObject(forKey: "cli_pulse_token")
    }

    // v1.10 P2-3 slice 3: parameter renamed from `authState` to `session` to
    // avoid shadowing `self.authState` (the newly-extracted AuthState child
    // ObservableObject). The LHS assignments below now route through
    // AppState's computed forwarders to the child.
    func applyAuthenticatedState(_ session: AuthSessionState) {
        userId = session.userId
        userName = session.userName
        userEmail = session.userEmail
        isPaired = session.isPaired
        isAuthenticated = true
        serverOnline = true

        // iter8 hotfix: replay any APNs push token the iOS app cached
        // before sign-in completed. APNs delivers the token once per
        // launch via didRegister; if the user signed in AFTER that
        // delivery, syncPushToken would otherwise wait for a relaunch
        // before reaching the server. flushPendingPushTokenIfAvailable
        // is idempotent + no-ops when nothing's cached.
        flushPendingPushTokenIfAvailable()

        // Notify iOS companion to forward auth to watch
        NotificationCenter.default.post(
            name: .cliPulseDidAuthenticate,
            object: nil,
            userInfo: [
                "access_token": storedToken,
                "refresh_token": storedRefreshToken,
                "email": session.userEmail,
                "name": session.userName,
            ]
        )
    }

    func applySignedOutState() {
        isLoading = false
        isAuthenticated = false
        isPaired = false
        isLocalMode = false
        serverOnline = false
        userId = ""
        userName = ""
        userEmail = ""
        dashboard = nil
        providers = []
        sessions = []
        devices = []
        alerts = []
        providerDetails = []
        costSummary = CostSummary()
        tierLimitWarning = nil
        lastRefresh = nil
        locallySupplementedProviders = []
        // iter16 hotfix (2026-04-29): signed-out + onboarding-completed
        // users used to land on `.overview` after a sign-out / delete-
        // account, which renders an empty "No Data Yet" state — a
        // confusing first impression that gives no hint about what to
        // do next. The intended UX is to land on `.settings` so the
        // user sees the Sign-In form, the password / OAuth buttons,
        // and the iter14 "Continue without account" escape. Users who
        // intentionally browse to Overview / Providers / Sessions /
        // Alerts during the same popover session keep that selection
        // — only sign-out / restoreSession-failed paths reset.
        //
        // For signed-IN users this reset doesn't matter at the surface
        // level: by the time they land in `connectedView`, they've
        // already gone through `applyAuthenticatedState`, which leaves
        // `selectedTab` alone (so they keep whatever tab they had,
        // typically the AppState init default of `.overview`).
        selectedTab = .settings
        // Clear account-scoped auth/account UI state so a different account
        // signing in on the same device doesn't briefly inherit the previous
        // user's linked identities, pairing artifacts, or stale errors.
        linkedIdentities = []
        isLinkingIdentity = false
        linkIdentityError = nil
        otpSent = false
        otpEmail = ""
        pairingInfo = nil
        pairingError = nil
        lastError = nil
        // Clear tier-migration state so a different account signing in on
        // the same device starts clean — otherwise they'd see the prior
        // user's "Disabled N providers" banner and stale "Limited by free
        // plan" lock badges (Gemini 3.1 Pro review 2026-04-23).
        providerLimitMigrationCount = 0
        UserDefaults.standard.removeObject(forKey: "cli_pulse_providers_disabled_by_tier")
    }
}
