import SwiftUI
import AppKit
import ServiceManagement
import CLIPulseCore
import os.log

private let logger = Logger(subsystem: "com.clipulse.bar", category: "AppLifecycle")

@main
struct CLIPulseBarApp: App {
    @StateObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow

    /// Keeps the LSUIElement menu-bar app out of App Nap so the background
    /// refresh timer keeps firing and the run loop isn't throttled into
    /// false-positive Sentry app-hang reports. Held for the app's lifetime.
    private let backgroundActivity = BackgroundActivityAssertion()

    init() {
        // W1-A: on the unsandboxed Developer-ID build, migrate per-app-container
        // UserDefaults (provider configs, onboarding flag, display prefs,
        // language override) from the old sandbox container to the real home
        // BEFORE AppState is constructed — AppState.init() reads
        // UserDefaults.standard immediately (loadProviderConfigs + legacy token
        // migration). @StateObject defers AppState() to first body render, but
        // assign it explicitly here AFTER the migration so the
        // migration-before-read ordering is obvious and robust against future
        // edits. No-op on sandboxed (MAS) builds and after the first DEVID run.
        UnsandboxedDataMigration.runIfNeeded()
        _appState = StateObject(wrappedValue: AppState())
        SentryLogger.start(platform: .macOS)
        backgroundActivity.begin()
        // Resolve stored security-scoped bookmarks shortly AFTER launch — off
        // the synchronous init path. Each resolution does slow sandbox XPC, so
        // doing the batch synchronously here stalled startup on the main
        // thread; the deferred, yielding async version keeps launch responsive.
        Task { @MainActor in
            await BookmarkManager.shared.resolveAllBookmarks()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appState)
                .environmentObject(appState.subscriptionManager)
                .environmentObject(appState.authState)
                .environmentObject(appState.alertState)
                .environmentObject(appState.providerState)
        } label: {
            MenuBarLabel(
                appState: appState,
                authState: appState.authState,
                alertState: appState.alertState,
                providerState: appState.providerState
            )
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .appInfo) {
                Button(L10n.tab.overview) { appState.selectedTab = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button(L10n.tab.providers) { appState.selectedTab = .providers }
                    .keyboardShortcut("2", modifiers: .command)
                Button(L10n.tab.sessions) { appState.selectedTab = .sessions }
                    .keyboardShortcut("3", modifiers: .command)
                Button(L10n.tab.alerts) { appState.selectedTab = .alerts }
                    .keyboardShortcut("4", modifiers: .command)
                Button(L10n.tab.settings) { appState.selectedTab = .settings }
                    .keyboardShortcut("5", modifiers: .command)
                Divider()
                Button(L10n.common.refreshAll) {
                    appState.requestRefresh()
                }
                .keyboardShortcut("r", modifiers: .command)
            }
            // v1.24 Phase 3 — in-app terminal entry. DEVID-only;
            // MAS builds get nothing here (helper-mediated MAS PTY
            // is post-v1.24, per plan §R1 + Gemini LOW). The
            // sandbox probe is a constant per process so the check
            // happens once at scene build.
            if MASSandboxGate.canHostInAppTerminal {
                CommandMenu("Terminal") {
                    Button("New Terminal — Claude") {
                        newTerminal(provider: "claude")
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    Button("New Terminal — Gemini (agy)") {
                        newTerminal(provider: "gemini")
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    Button("New Terminal — Codex") {
                        newTerminal(provider: "codex")
                    }
                }
            }
        }

        Window(L10n.about.title, id: "about") {
            AboutView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window(L10n.settings.subscription, id: "subscription") {
            SubscriptionView(manager: appState.subscriptionManager)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Provider config editor lives in its own window so the system
        // Keychain AutoFill dialog (if it ever appears) cannot collapse the
        // MenuBarExtra popover when dismissed.
        Window("Provider Settings", id: "provider-config") {
            ProviderConfigWindowContent()
                .environmentObject(appState)
                .environmentObject(appState.subscriptionManager)
                .environmentObject(appState.authState)
                .environmentObject(appState.alertState)
                .environmentObject(appState.providerState)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // v1.32.1 P1 — in-app terminal as the PRIMARY surface. A value-based
        // WindowGroup keyed by `TerminalSessionKey` gives a per-session
        // SINGLETON: `openWindow(value:)` with a key whose window is already
        // open brings it forward instead of spawning a second WKWebView on the
        // same session. The window ATTACHES to an already-running session (the
        // id is resolved before opening — spawned headlessly for "New", or the
        // existing id from the Sessions row). Closing detaches (P1-3); the
        // helper session keeps running. Registered unconditionally so
        // `openWindow(value:)` is a harmless no-op on MAS (menu hidden there).
        WindowGroup(for: TerminalSessionKey.self) { $key in
            if let key {
                TerminalAttachView(sessionId: key.sessionId, provider: key.provider)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    /// "New Terminal — <provider>": pick a working directory, spawn the managed
    /// session headlessly, then open a window keyed by the helper-assigned id so
    /// the value-based WindowGroup singleton owns it. DEVID-only (the menu is
    /// gated by `MASSandboxGate.canHostInAppTerminal`). Spawn-first means the
    /// window always uses the attach-to-existing path (no spawn-on-appear),
    /// unifying "New" and "Open existing" on one code path.
    @MainActor
    private func newTerminal(provider: String) {
        // Capture the action before the modal panel runs its nested runloop —
        // grabbing `self.openWindow` from inside the escaping completion can
        // otherwise pick up a stale environment reference (Gemini 3.1 Pro review).
        let windowAction = openWindow
        // Real home even if sandboxed (future MAS-helper support); a no-op
        // alias for homeDirectoryForCurrentUser on the unsandboxed DEVID build
        // where the terminal actually runs. Keeps one cwd flow for both paths.
        let home = UnsandboxedDataMigration.realUserHome()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal Here"
        panel.message = "Choose the working directory for the \(provider.capitalized) session"
        panel.directoryURL = home
        panel.begin { response in
            // Cancel cancels — don't headlessly spawn a CLI in HOME when the
            // user backed out (Codex review): spawn now happens before any
            // window appears, so a fallback-to-HOME would be an invisible
            // surprise session.
            guard response == .OK, let cwd = panel.url?.path else { return }
            Task { @MainActor in
                do {
                    let result = try await LocalSessionControlClient().startManagedSession(
                        provider: provider,
                        clientLabel: "in-app-terminal",
                        cwdBasename: (cwd as NSString).lastPathComponent,
                        cwdHmac: nil,
                        cwd: cwd)
                    windowAction(value: TerminalSessionKey(sessionId: result.sessionId,
                                                           provider: provider))
                } catch {
                    // A menu command that silently does nothing reads as "the
                    // app is broken" (helper down / control off / missing
                    // binary / bad cwd). Tell the user why (both reviewers).
                    logger.error("newTerminal(\(provider)) spawn failed: \(error.localizedDescription)")
                    // LSUIElement apps aren't frontmost after the async gap, so
                    // a bare runModal() can open behind other apps and look like
                    // a hung menu — activate first (deep review).
                    NSApp.activate(ignoringOtherApps: true)
                    let alert = NSAlert()
                    alert.messageText = "Couldn't start \(provider.capitalized) session"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.runModal()
                }
            }
        }
    }
}

// MARK: - Menu Bar Label

/// Observes `AppState`, `AuthState`, `AlertState`, and `ProviderState` so the
/// MenuBarExtra label re-renders when any field consumed by `menuBarIcon` /
/// `menuBarLabel` changes. Those computed properties read:
/// - `isAuthenticated` / `isPaired` — now on AuthState
/// - `alerts.filter { !$0.is_resolved }.count` — now on AlertState
/// - `mostUsedProvider` (reads `providers` + `enabledProviderNames` which
///   reads `providerConfigs`) — now on ProviderState
/// - `serverOnline` and `menuBarDisplayMode` — still on AppState
///
/// The backing `@Published` storage lives on the child ObservableObjects, not
/// on AppState, so the label closure must observe all four publishers to
/// pick up icon/badge/label changes.
private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var authState: AuthState
    @ObservedObject var alertState: AlertState
    @ObservedObject var providerState: ProviderState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: appState.menuBarIcon)
                .symbolRenderingMode(.hierarchical)
            let label = appState.menuBarLabel
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
        }
        // v1.10 P3-3: VoiceOver reads the menu-bar widget as a single
        // "CLI Pulse, {label}" element (e.g. "CLI Pulse, 3" when 3 alerts
        // are unresolved) instead of announcing the raw SF Symbol name.
        // Use `.ignore` + explicit label because we're entirely replacing
        // the readout — `.combine` + label would make the combine redundant.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(menuBarAccessibilityLabel)
    }

    private var menuBarAccessibilityLabel: String {
        let label = appState.menuBarLabel
        if label.isEmpty {
            return "CLI Pulse"
        }
        return "CLI Pulse, \(label)"
    }
}

// MARK: - Provider Config Window Content

/// Wraps the provider config editor in a View so the App Scene closure doesn't
/// need to read `appState.editingProviderKind` directly. Reading a @Published
/// property from inside a Scene closure can cause the App body to re-evaluate
/// on every state change, destabilizing MenuBarExtra.
private struct ProviderConfigWindowContent: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState

    var body: some View {
        Group {
            if let kind = providerState.editingProviderKind {
                ProviderConfigEditor(kind: kind, state: state)
            } else {
                Text(L10n.common.noProviderSelected)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 340, minHeight: 380)
    }
}

// MARK: - About Window

struct AboutView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 4)

            VStack(spacing: 4) {
                Text(L10n.about.title)
                    .font(.system(size: 20, weight: .bold))
                Text("\(L10n.settings.version) \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0")")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("\(L10n.settings.build) \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Text(L10n.about.description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Divider()
                .padding(.horizontal, 20)

            VStack(spacing: 6) {
                Link(L10n.settings.github, destination: URL(string: "https://github.com/jasonyeyuhe/cli-pulse")!)
                    .font(.system(size: 11))
                Link(L10n.about.reportIssue, destination: URL(string: "https://github.com/jasonyeyuhe/cli-pulse/issues")!)
                    .font(.system(size: 11))
            }

            Text(L10n.about.copyright)
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
        .padding(30)
        .frame(width: 340)
    }
}

// MARK: - Launch at Login Helper

enum LaunchAtLogin {
    @available(macOS 13.0, *)
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @available(macOS 13.0, *)
    static func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.error("LaunchAtLogin error: \(error.localizedDescription)")
        }
    }
}

// MARK: - Background Helper Login Item

enum HelperLogin {
    private static let identifier = "yyh.CLI-Pulse.helper"

    @available(macOS 13.0, *)
    static var service: SMAppService {
        SMAppService.loginItem(identifier: identifier)
    }

    @available(macOS 13.0, *)
    static var isEnabled: Bool {
        service.status == .enabled
    }

    @available(macOS 13.0, *)
    static func register() {
        do {
            try service.register()
            logger.info("HelperLogin: registered")
        } catch {
            logger.error("HelperLogin register error: \(error.localizedDescription)")
        }
    }

    @available(macOS 13.0, *)
    static func unregister() {
        do {
            try service.unregister()
            logger.info("HelperLogin: unregistered")
        } catch {
            logger.error("HelperLogin unregister error: \(error.localizedDescription)")
        }
    }

    @available(macOS 13.0, *)
    static func toggle() {
        if isEnabled {
            unregister()
        } else {
            register()
        }
    }
}
