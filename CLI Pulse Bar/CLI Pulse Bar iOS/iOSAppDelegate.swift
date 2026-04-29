import UIKit
import UserNotifications
import CLIPulseCore
import os

private let pushLogger = Logger(subsystem: "com.clipulse", category: "iOSPush")

/// SwiftUI `@UIApplicationDelegateAdaptor` for the iOS app. Owns the APNs
/// registration handshake and the foreground / tap routing for Remote
/// Approvals push notifications.
///
/// Why this file exists at all (the iOS app is otherwise pure SwiftUI):
/// SwiftUI has no first-class hook for
/// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
/// The only supported route is a thin AppDelegate adaptor.
///
/// The class is iOS-only — UIKit is not available on watchOS targets, so
/// it lives in `CLI Pulse Bar iOS/` (the iOS app target's source dir),
/// not in CLIPulseCore.
final class iOSAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Handed to us by the SwiftUI App on launch so we can route
    /// notification taps + sync the device token through DataRefreshManager.
    static weak var sharedAppState: AppState?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        // Take over notification delivery callbacks from the OS.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // ── APNs registration ──────────────────────────────────────

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = PushTokenSync.formatToken(deviceToken)
        pushLogger.info("APNs registration succeeded (\(hex.count, privacy: .public) hex chars)")
        guard let state = Self.sharedAppState else {
            // First-launch race: AppState not wired yet. APNs will
            // re-deliver on next launch via the cached token.
            return
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "yyh.CLI-Pulse-iOS"
        state.syncPushToken(
            token: hex,
            platform: PushTokenSync.platformIdentifier(forUIKit: true),
            bundleId: bundleId
        )
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        // Common failure modes:
        //   * App is signed without `aps-environment` entitlement (Debug
        //     build before user enables Push Notifications capability)
        //   * Simulator with no Apple ID configured
        //   * Network failure during initial APNs registration
        // Logged at INFO because it's expected on most dev installs.
        pushLogger.info("APNs registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // ── Foreground display ─────────────────────────────────────

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banner even if app is in foreground — the user may be on
        // a different tab and miss the active-polling refresh otherwise.
        completionHandler([.banner, .sound, .list])
    }

    // ── Tap routing ────────────────────────────────────────────

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Spec: "确保 app foreground / notification tap 后会 refresh pending approvals"
        // The Settings tab houses the always-visible "Pending Approvals"
        // NavigationLink (count badge included). Routing there gives the
        // user one tap to drill in. We deliberately don't try to deep-
        // link straight into the approvals view — the navigation stack
        // shape varies (iPad split, iPhone tabs, no-iPhone-Mac on
        // Mac Catalyst) and the badge already makes the destination
        // visually obvious.
        Task { @MainActor in
            guard let state = Self.sharedAppState else {
                completionHandler()
                return
            }
            state.selectedTab = .settings
            await state.refreshRemoteApprovals()
            completionHandler()
        }
    }
}
