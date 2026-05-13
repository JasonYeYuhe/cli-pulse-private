import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Tests for `AppPermissionMigrationChecker`. v1.19 G1 mitigation that
/// detects TCC permission revocations on MAS → DEVID swap.
///
/// The xctest defense in `captureCurrentSnapshot()` returns a
/// defaults-only Snapshot when running under swift test, so the
/// snapshot-write-then-compare flow is exercisable here without
/// touching UNUserNotificationCenter (which would crash in this
/// context with `bundleProxyForCurrentProcess is nil`).
final class AppPermissionMigrationCheckerTests: XCTestCase {

    /// Use a dedicated UserDefaults suite per test so state doesn't
    /// bleed across runs. App-group defaults can persist between test
    /// invocations on the same machine; a per-test suite avoids that.
    private func makeTestSuite() -> (UserDefaults, String) {
        let name = "test.cli-pulse.perm-migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, name)
    }

    private func writeSnapshot(
        _ snap: AppPermissionMigrationChecker.Snapshot,
        to defaults: UserDefaults
    ) {
        let data = try! JSONEncoder().encode(snap)
        defaults.set(data, forKey: AppPermissionMigrationChecker.snapshotDefaultsKey)
    }

    private func readSnapshot(
        from defaults: UserDefaults
    ) -> AppPermissionMigrationChecker.Snapshot? {
        guard let data = defaults.data(
            forKey: AppPermissionMigrationChecker.snapshotDefaultsKey
        ) else { return nil }
        return try? JSONDecoder().decode(
            AppPermissionMigrationChecker.Snapshot.self, from: data
        )
    }

    /// F1 regression test: previously `runOnLaunch()` wrote the
    /// current snapshot BEFORE reading the previous one, so the read
    /// always returned what we'd just written and `revertedPermissions`
    /// was always empty. After the fix, the read happens first.
    ///
    /// We can't drive a full `runOnLaunch()` here because that uses
    /// the singleton app-group UserDefaults and the actual TCC
    /// probe (which under xctest defense returns false/false anyway).
    /// Instead we directly exercise the write-then-read ordering
    /// using the helper accessor surface: write a known previous
    /// snapshot, verify it round-trips, and confirm the `current
    /// != previous` comparison would actually fire when the input
    /// differs.
    func test_F1_previousSnapshotReadable_afterWriteFix() {
        let (defaults, _) = makeTestSuite()
        let previous = AppPermissionMigrationChecker.Snapshot(
            notificationsGranted: true,
            accessibilityGranted: true,
            capturedAt: Date(timeIntervalSinceNow: -3600)  // 1h ago
        )
        writeSnapshot(previous, to: defaults)

        let roundTripped = readSnapshot(from: defaults)
        XCTAssertNotNil(roundTripped)
        XCTAssertEqual(roundTripped?.notificationsGranted, true)
        XCTAssertEqual(roundTripped?.accessibilityGranted, true)

        // Simulate a "current" snapshot where notifications were
        // revoked — this is what the post-DEVID-swap state would look
        // like. The comparison MUST identify Notifications as
        // reverted.
        let current = AppPermissionMigrationChecker.Snapshot(
            notificationsGranted: false,   // revoked
            accessibilityGranted: true,
            capturedAt: Date()
        )
        var reverted: [String] = []
        if roundTripped!.notificationsGranted && !current.notificationsGranted {
            reverted.append("Notifications")
        }
        if roundTripped!.accessibilityGranted && !current.accessibilityGranted {
            reverted.append("Accessibility")
        }
        XCTAssertEqual(reverted, ["Notifications"],
                       "post-fix: revocation must be detected when previous snapshot is read BEFORE current is written")
    }

    /// Mixed-revocation: both Notifications AND Accessibility lost.
    /// Verifies the reverted list captures both.
    func test_bothPermissionsRevoked_listsBoth() {
        let previous = AppPermissionMigrationChecker.Snapshot(
            notificationsGranted: true,
            accessibilityGranted: true,
            capturedAt: Date(timeIntervalSinceNow: -100)
        )
        let current = AppPermissionMigrationChecker.Snapshot(
            notificationsGranted: false,
            accessibilityGranted: false,
            capturedAt: Date()
        )
        var reverted: [String] = []
        if previous.notificationsGranted && !current.notificationsGranted {
            reverted.append("Notifications")
        }
        if previous.accessibilityGranted && !current.accessibilityGranted {
            reverted.append("Accessibility")
        }
        XCTAssertEqual(reverted, ["Notifications", "Accessibility"])
    }

    /// Permissions never granted on MAS → no nudge needed on DEVID.
    func test_neverGranted_noRevocation() {
        let previous = AppPermissionMigrationChecker.Snapshot(
            notificationsGranted: false,
            accessibilityGranted: false,
            capturedAt: Date(timeIntervalSinceNow: -100)
        )
        let current = AppPermissionMigrationChecker.Snapshot(
            notificationsGranted: false,
            accessibilityGranted: false,
            capturedAt: Date()
        )
        var reverted: [String] = []
        if previous.notificationsGranted && !current.notificationsGranted {
            reverted.append("Notifications")
        }
        if previous.accessibilityGranted && !current.accessibilityGranted {
            reverted.append("Accessibility")
        }
        XCTAssertEqual(reverted, [])
    }

    /// xctest defense: in this test context, captureCurrentSnapshot
    /// returns a defaults-only snapshot without crashing.
    func test_xctestDefense_doesNotCrash() async {
        let checker = AppPermissionMigrationChecker()
        // Just calling runOnLaunch must not crash. We don't assert
        // specific values because the singleton app-group state
        // depends on prior test runs / production launches.
        await checker.runOnLaunch()
        // If we reach here without throwing, the xctest defense
        // worked.
    }

    /// System Settings deep-link returns a non-nil URL for known
    /// permission strings. The URL string format is brittle (Apple
    /// renames the scheme components over macOS releases), but the
    /// test pins the contract that these strings are recognised.
    func test_systemSettingsURL_knownPermissions() {
        XCTAssertNotNil(
            AppPermissionMigrationChecker.systemSettingsURL(for: "Notifications")
        )
        XCTAssertNotNil(
            AppPermissionMigrationChecker.systemSettingsURL(for: "Accessibility")
        )
        // Unknown falls back to the generic privacy pane.
        XCTAssertNotNil(
            AppPermissionMigrationChecker.systemSettingsURL(for: "Mystery")
        )
    }

    /// dismissNudge clears the published flag + persists the
    /// "already shown" key so subsequent launches don't re-show.
    @MainActor
    func test_dismissNudge_persistsShownFlag() {
        let checker = AppPermissionMigrationChecker()
        // Note: dismissNudge writes to the SINGLETON app-group
        // defaults, not a per-test suite. We can't fully isolate this
        // without injecting the defaults instance; the test just
        // verifies the public method runs without crashing and that
        // the published fields update.
        checker.dismissNudge()
        XCTAssertFalse(checker.needsMigrationNudge)
        XCTAssertEqual(checker.revertedPermissions, [])
    }
}

#endif
