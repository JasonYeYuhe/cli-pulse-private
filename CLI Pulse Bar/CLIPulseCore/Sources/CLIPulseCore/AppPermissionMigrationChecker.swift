#if os(macOS)
import Foundation
import os
import UserNotifications
import ApplicationServices

private let permMigrationLog = Logger(
    subsystem: "com.cli-pulse.bar", category: "perm-migration"
)

/// v1.19 G1 mitigation — detect TCC permission revocations that happen
/// when a user migrates from the MAS app to the Developer ID DMG app.
///
/// **Background**: macOS TCC binds Notifications / Accessibility / Full
/// Disk Access / etc. to the app's Designated Requirement (cert chain
/// + bundle ID + team ID). Even with the same bundle ID, swapping from
/// Apple Distribution (MAS) to Developer ID Application (DEVID)
/// changes the DR, so all previously-granted permissions silently
/// revert to "not requested." For CLI Pulse this hits notifications
/// hardest (alerts stop working). Accessibility may also break global
/// keyboard shortcuts.
///
/// **Approach**: write a snapshot of currently-granted permissions to
/// app-group UserDefaults from BOTH MAS and DEVID builds (the same
/// call). On DEVID first-launch, read the snapshot and compare against
/// the current status. If permissions reverted (was "granted", now
/// "not determined"), set `needsMigrationNudge = true` so the UI can
/// show a banner pointing the user to System Settings.
///
/// **No requestAuthorization here** — that's owned by DataRefreshManager
/// and runs on its own schedule. This class is read-only: it observes,
/// compares, and surfaces a flag for the UI to consume.
public final class AppPermissionMigrationChecker: ObservableObject, @unchecked Sendable {

    public struct Snapshot: Codable, Equatable, Sendable {
        public var notificationsGranted: Bool
        public var accessibilityGranted: Bool
        public var capturedAt: Date

        public init(notificationsGranted: Bool, accessibilityGranted: Bool, capturedAt: Date) {
            self.notificationsGranted = notificationsGranted
            self.accessibilityGranted = accessibilityGranted
            self.capturedAt = capturedAt
        }
    }

    /// App-group UserDefaults key holding the last-known snapshot.
    /// Shared across MAS / DEVID builds so cross-channel migration
    /// detection works.
    static let snapshotDefaultsKey = "v1_19_last_known_permission_grants"
    static let nudgeShownDefaultsKey = "v1_19_perm_migration_nudge_shown"
    static let appGroupID = "group.yyh.CLI-Pulse"

    /// Set to true when this DEVID build's permissions look reverted
    /// vs a snapshot written by the previous MAS install. The UI
    /// reads this and surfaces a banner.
    @Published public private(set) var needsMigrationNudge: Bool = false

    /// What specifically reverted — drives the banner copy.
    @Published public private(set) var revertedPermissions: [String] = []

    public init() {}

    /// Called from AppState init on both MAS and DEVID builds. Probes
    /// the current state, writes a snapshot, and (DEVID-only)
    /// compares against the previous snapshot for migration detection.
    /// Idempotent — re-runs do not re-show the nudge once dismissed.
    @MainActor
    public func runOnLaunch() async {
        let current = await Self.captureCurrentSnapshot()
        let defaults = Self.appGroupDefaults()

        // Always write the latest snapshot. Both MAS and DEVID builds
        // do this, so whichever ships first creates the baseline; the
        // other reads it.
        if let data = try? JSONEncoder().encode(current) {
            defaults?.set(data, forKey: Self.snapshotDefaultsKey)
        }

        #if DEVID_BUILD
        // Compare against the previous snapshot — if permissions look
        // reverted, set the nudge flag (unless the user has already
        // dismissed it in this DEVID install).
        let nudgeAlreadyShown = defaults?.bool(forKey: Self.nudgeShownDefaultsKey) ?? false
        if nudgeAlreadyShown {
            permMigrationLog.info("perm migration nudge already dismissed; skipping")
            return
        }

        let snapshotData = defaults?.data(forKey: Self.snapshotDefaultsKey)
        guard let snapshotData,
              let previous = try? JSONDecoder().decode(Snapshot.self, from: snapshotData),
              // If the snapshot we just wrote IS the previous one
              // (first run, no prior data), skip the diff.
              abs(previous.capturedAt.timeIntervalSinceNow) > 1.0
        else {
            permMigrationLog.info("no prior snapshot to compare against")
            return
        }

        var reverted: [String] = []
        if previous.notificationsGranted && !current.notificationsGranted {
            reverted.append("Notifications")
        }
        if previous.accessibilityGranted && !current.accessibilityGranted {
            reverted.append("Accessibility")
        }
        if !reverted.isEmpty {
            permMigrationLog.notice("permission migration detected: \(reverted.joined(separator: ", "), privacy: .public) reverted")
            self.revertedPermissions = reverted
            self.needsMigrationNudge = true
        }
        #endif
    }

    /// Called when the user dismisses the migration banner. Persists
    /// so the banner doesn't re-appear on next launch.
    @MainActor
    public func dismissNudge() {
        needsMigrationNudge = false
        revertedPermissions = []
        Self.appGroupDefaults()?.set(true, forKey: Self.nudgeShownDefaultsKey)
    }

    /// Deep-link to a specific System Settings pane. Best-effort —
    /// macOS rewrites these URLs over time but the prefs scheme is
    /// stable enough for v1.19.
    public static func systemSettingsURL(for permission: String) -> URL? {
        switch permission {
        case "Notifications":
            return URL(string: "x-apple.systempreferences:com.apple.preference.notifications")
        case "Accessibility":
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        default:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security")
        }
    }

    // MARK: - Internals

    private static func appGroupDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Probe current TCC status for the two permissions we care about.
    /// READ-ONLY — does NOT request authorization. Notification probe
    /// is async because UNUserNotificationCenter's settings come back
    /// on a callback.
    private static func captureCurrentSnapshot() async -> Snapshot {
        let notifGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus == .authorized)
            }
        }
        // AXIsProcessTrusted is synchronous + read-only when passed
        // false for the prompt option (the default).
        let accessibilityGranted = AXIsProcessTrusted()
        return Snapshot(
            notificationsGranted: notifGranted,
            accessibilityGranted: accessibilityGranted,
            capturedAt: Date()
        )
    }
}

#endif
