import Foundation
import WatchConnectivity
import CLIPulseCore

/// Manages WatchConnectivity on the iPhone side.
/// Sends auth tokens and dashboard data to the paired Apple Watch.
final class PhoneSessionManager: NSObject, ObservableObject {
    static let shared = PhoneSessionManager()

    @Published var isWatchReachable = false

    /// The AppState whose refreshes we forward to the watch. Set once from
    /// the SwiftUI scene; we hold a weak reference so we never extend its
    /// lifetime.
    weak var appState: AppState?

    /// Auth payload / dashboard snapshot we tried to send before WCSession
    /// activation completed. Replayed in `activationDidCompleteWith`. Without
    /// this, the very first auth event on a cold launch is silently dropped
    /// and the watch never receives credentials until the user re-triggers
    /// auth somehow.
    private var pendingAuthPayload: [String: Any]?
    private var pendingContext: [String: Any]?
    private var pendingLogout = false
    private let pendingLock = NSLock()

    private override init() {
        super.init()
        // Observe CLIPulseCore notifications eagerly — the observers must be
        // registered BEFORE AppState.init posts `cliPulseDidAuthenticate`
        // during its Task-launched restoreSession. Registering in `activate()`
        // (previously called from `.onAppear`) was losing the very first auth
        // event on cold launch.
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidAuthenticate(_:)),
                                                name: .cliPulseDidAuthenticate, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidSignOut),
                                                name: .cliPulseDidSignOut, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidRefresh(_:)),
                                                name: .cliPulseDidRefresh, object: nil)
    }

    /// Activate the WCSession if supported (iPhone only).
    func activate(appState: AppState? = nil) {
        if let appState { self.appState = appState }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    @objc private func handleDidAuthenticate(_ notification: Notification) {
        guard let info = notification.userInfo,
              let token = info["access_token"] as? String, !token.isEmpty else { return }
        sendAuthToWatch(
            accessToken: token,
            refreshToken: info["refresh_token"] as? String,
            email: info["email"] as? String ?? "",
            name: info["name"] as? String ?? ""
        )
    }

    @objc private func handleDidSignOut() {
        sendLogoutToWatch()
    }

    @objc private func handleDidRefresh(_ notification: Notification) {
        // Forward the most recent snapshot to the paired watch. Without this,
        // the watch's `updateApplicationContext` fallback cache stays empty
        // and if the watch's own direct API call fails (token, network) the
        // user sees "Pull to refresh" forever.
        guard let state = (notification.object as? AppState) ?? appState else { return }
        Task { @MainActor in
            self.sendDashboardToWatch(
                dashboard: state.dashboard,
                providers: state.providers,
                sessions: state.sessions,
                alerts: state.alerts,
                devices: state.devices
            )
        }
    }

    // MARK: - Send Auth to Watch

    /// Transfer auth tokens to the watch after successful login.
    /// Uses `transferUserInfo` for guaranteed delivery (queued, survives app exit).
    func sendAuthToWatch(accessToken: String, refreshToken: String?, email: String, name: String) {
        var payload: [String: Any] = [
            "cli_pulse_auth": true,
            "access_token": accessToken,
            "email": email,
            "name": name,
        ]
        if let rt = refreshToken {
            payload["refresh_token"] = rt
        }

        guard WCSession.isSupported() else { return }
        if WCSession.default.activationState == .activated, WCSession.default.isPaired {
            WCSession.default.transferUserInfo(payload)
        } else {
            // Queue until activation completes so we don't drop the first
            // auth event on cold launch.
            pendingLock.lock()
            pendingAuthPayload = payload
            pendingLogout = false
            pendingLock.unlock()
        }
    }

    /// Send logout signal to watch.
    func sendLogoutToWatch() {
        guard WCSession.isSupported() else { return }
        if WCSession.default.activationState == .activated, WCSession.default.isPaired {
            WCSession.default.transferUserInfo(["cli_pulse_logout": true])
        } else {
            pendingLock.lock()
            pendingAuthPayload = nil
            pendingLogout = true
            pendingLock.unlock()
        }
    }

    // MARK: - Send Dashboard Data

    /// Update application context with fresh dashboard data.
    func sendDashboardToWatch(dashboard: DashboardSummary?, providers: [ProviderUsage],
                               sessions: [SessionRecord], alerts: [AlertRecord],
                               devices: [DeviceRecord] = []) {
        let encoder = JSONEncoder()
        var context: [String: Any] = [:]

        if let dash = dashboard, let data = try? encoder.encode(dash) {
            context["dashboard"] = data
        }
        if !providers.isEmpty, let data = try? encoder.encode(providers) {
            context["providers"] = data
        }
        if !sessions.isEmpty, let data = try? encoder.encode(sessions) {
            context["sessions"] = data
        }
        if !alerts.isEmpty, let data = try? encoder.encode(alerts) {
            context["alerts"] = data
        }
        // v1.41 Mobile Machine: trimmed, ≤4 device-health summaries (keeps the
        // WC context small; no control-plane fields cross to the read-only watch).
        let deviceSummaries = WatchDeviceTrim.summaries(from: devices)
        if !deviceSummaries.isEmpty, let data = try? encoder.encode(deviceSummaries) {
            context["devices"] = data
        }

        guard !context.isEmpty, WCSession.isSupported() else { return }
        if WCSession.default.activationState == .activated, WCSession.default.isPaired {
            try? WCSession.default.updateApplicationContext(context)
        } else {
            // Hold the most recent snapshot and replay on activation.
            pendingLock.lock()
            pendingContext = context
            pendingLock.unlock()
        }
    }

    /// Flush anything we couldn't send while the WCSession was still
    /// activating. Called from `session(_:activationDidCompleteWith:error:)`.
    fileprivate func flushPending() {
        pendingLock.lock()
        let auth = pendingAuthPayload
        let ctx = pendingContext
        let logout = pendingLogout
        pendingAuthPayload = nil
        pendingContext = nil
        pendingLogout = false
        pendingLock.unlock()

        guard WCSession.default.activationState == .activated,
              WCSession.default.isPaired else { return }

        if logout {
            WCSession.default.transferUserInfo(["cli_pulse_logout": true])
        } else if let auth {
            WCSession.default.transferUserInfo(auth)
        }
        if let ctx {
            try? WCSession.default.updateApplicationContext(ctx)
        }
    }
}

// MARK: - WCSessionDelegate

extension PhoneSessionManager: WCSessionDelegate {
    func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
        // Any auth/snapshot that was queued while activation was in flight
        // goes out now. Without this, a cold-launch auth event fires before
        // WCSession is `.activated` and is silently lost.
        flushPending()
    }

    func sessionDidBecomeInactive(_ session: WCSession) { }
    func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate for multi-watch support
        session.activate()
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isWatchReachable = session.isReachable
        }
    }
}
