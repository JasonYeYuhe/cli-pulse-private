import SwiftUI
import CLIPulseCore
import AppIntents

@main
struct CLIPulseApp: App {
    @StateObject private var appState: AppState
    @Environment(\.scenePhase) private var scenePhase
    private let phoneSession = PhoneSessionManager.shared

    // SwiftUI is otherwise pure but the APNs registration + tap routing
    // require a UIApplicationDelegate. `iOSAppDelegate` is iOS-target-only;
    // the backing class lives in iOSAppDelegate.swift. See its docstring
    // for why this AppDelegate adaptor exists alongside the SwiftUI app.
    @UIApplicationDelegateAdaptor(iOSAppDelegate.self) private var appDelegate

    init() {
        SentryLogger.start(platform: .iOS)
        let state = AppState()
        _appState = StateObject(wrappedValue: state)
        // Hand AppState to the delegate so the APNs token callback + the
        // tap-handler can call into syncPushToken / refreshRemoteApprovals.
        // The delegate holds a weak ref so it doesn't keep AppState alive.
        iOSAppDelegate.sharedAppState = state
        // Activate the WatchConnectivity bridge as early as possible. The
        // previous call site (`.onAppear`) was losing the first auth
        // notification posted by AppState's restoreSession Task on cold
        // launch, leaving the watch without bridged credentials.
        PhoneSessionManager.shared.activate(appState: state)
    }

    var body: some Scene {
        WindowGroup {
            iOSMainView()
                .environmentObject(appState)
                .environmentObject(appState.subscriptionManager)
                .environmentObject(appState.authState)
                .environmentObject(appState.alertState)
                .environmentObject(appState.providerState)
                .onAppear {
                    if #available(iOS 17.0, *) {
                        CLIPulseShortcuts.updateAppShortcutParameters()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        handleWidgetRefreshRequest()
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu(L10n.common.navigation) {
                Button(L10n.dashboard.title) { appState.selectedTab = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button(L10n.tab.providers) { appState.selectedTab = .providers }
                    .keyboardShortcut("2", modifiers: .command)
                Button(L10n.tab.sessions) { appState.selectedTab = .sessions }
                    .keyboardShortcut("3", modifiers: .command)
                Button(L10n.tab.alerts) { appState.selectedTab = .alerts }
                    .keyboardShortcut("4", modifiers: .command)
                Button(L10n.tab.settings) { appState.selectedTab = .settings }
                    .keyboardShortcut("5", modifiers: .command)
            }
            CommandMenu(L10n.common.data) {
                Button(L10n.common.refresh) {
                    appState.requestRefresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    /// Pick up a refresh request posted by the interactive widget button.
    /// The widget cannot drive the full data refresh itself (different process,
    /// no auth context); it stamps a timestamp in the App Group and reloads
    /// its timeline. When the app next becomes active, we trigger a real
    /// refresh if the request is newer than our last successful pull.
    private func handleWidgetRefreshRequest() {
        guard let requestedAt = CLIPulseIntentCache.refreshRequestedAt() else { return }
        let lastRefresh = appState.lastRefresh ?? .distantPast
        guard requestedAt > lastRefresh else { return }
        appState.requestRefresh()
    }
}
