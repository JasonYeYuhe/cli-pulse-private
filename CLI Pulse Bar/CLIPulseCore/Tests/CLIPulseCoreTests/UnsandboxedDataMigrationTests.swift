#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// W1-A: guards the one-time unsandboxed-launch UserDefaults migration. The
/// pure `migrate` core and the `runIfNeeded` orchestration are exercised with
/// an isolated defaults suite + temp plist so nothing touches the real app's
/// container or standard defaults.
final class UnsandboxedDataMigrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var tmpDir: URL!

    override func setUpWithError() throws {
        suiteName = "test.unsandbox.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unsandbox-mig-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Write a `[String: Any]` to a plist file and return its URL.
    private func writePlist(_ dict: [String: Any], name: String = "src.plist") throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try (dict as NSDictionary).write(to: url)
        return url
    }

    // MARK: - Pure migrate()

    func test_migrate_copiesAppOwnedKeys_andSkipsForeignKeys() throws {
        let src = try writePlist([
            "cli_pulse_onboarding_completed": true,
            "cli_pulse_refresh_interval": 30,
            "cli_pulse_locale_override": "zh-Hans",
            // PrivacySettings opt-outs use the `privacy.` namespace, NOT
            // cli_pulse_ — these MUST migrate (stranding re-enables cross-app
            // keychain reads for users who opted out). Codex diff-review catch.
            "privacy.skipClaudeKeychain": true,
            "privacy.localOnlyMode": true,
            // Non-app keys that must NOT be imported into the unsandboxed app:
            "NSWindow Frame main": "0 0 800 600 0 0 1440 900",
            "NSNavLastRootDirectory": "~/Downloads",
            "WebKitSomeCache": 1,
            "AppleLanguages": ["en"],
        ])
        let copied = UnsandboxedDataMigration.migrate(fromContainerPlist: src, into: defaults)
        // `copied == 5` is the authoritative proof the four foreign keys were
        // skipped — migrate only increments `copied` when it writes a key.
        XCTAssertEqual(copied, 5, "the five app-owned keys should copy (foreign keys excluded)")
        XCTAssertEqual(defaults.bool(forKey: "cli_pulse_onboarding_completed"), true)
        XCTAssertEqual(defaults.integer(forKey: "cli_pulse_refresh_interval"), 30)
        XCTAssertEqual(defaults.string(forKey: "cli_pulse_locale_override"), "zh-Hans")
        XCTAssertEqual(defaults.bool(forKey: "privacy.skipClaudeKeychain"), true,
                       "privacy opt-out must migrate, not silently revert to OFF")
        XCTAssertEqual(defaults.bool(forKey: "privacy.localOnlyMode"), true)
        // Negative check must read the suite's OWN persistent domain:
        // `object(forKey:)` falls through to NSGlobalDomain, where keys like
        // AppleLanguages always exist regardless of what we wrote.
        let written = defaults.persistentDomain(forName: suiteName) ?? [:]
        XCTAssertNil(written["NSWindow Frame main"])
        XCTAssertNil(written["NSNavLastRootDirectory"])
        XCTAssertNil(written["WebKitSomeCache"])
        XCTAssertNil(written["AppleLanguages"])
        XCTAssertNotNil(written["cli_pulse_onboarding_completed"])
    }

    func test_migrate_preservesProviderConfigData() throws {
        let payload = Data("[{\"kind\":\"claude\"}]".utf8)
        let src = try writePlist(["cli_pulse_provider_configs": payload])
        _ = UnsandboxedDataMigration.migrate(fromContainerPlist: src, into: defaults)
        XCTAssertEqual(defaults.data(forKey: "cli_pulse_provider_configs"), payload)
    }

    func test_migrate_doesNotClobberExistingDestValue() throws {
        defaults.set(99, forKey: "cli_pulse_refresh_interval")
        let src = try writePlist(["cli_pulse_refresh_interval": 30])
        let copied = UnsandboxedDataMigration.migrate(fromContainerPlist: src, into: defaults)
        XCTAssertEqual(copied, 0, "an already-present key must not be overwritten")
        XCTAssertEqual(defaults.integer(forKey: "cli_pulse_refresh_interval"), 99)
    }

    func test_migrate_skipsMigrationDoneKey() throws {
        let src = try writePlist([
            UnsandboxedDataMigration.migrationDoneKey: true,
            "cli_pulse_show_cost": false,
        ])
        let copied = UnsandboxedDataMigration.migrate(fromContainerPlist: src, into: defaults)
        XCTAssertEqual(copied, 1)
        XCTAssertFalse(defaults.bool(forKey: UnsandboxedDataMigration.migrationDoneKey),
                       "the done-flag must never be imported from the source")
    }

    func test_migrate_returnsNegativeOne_whenSourceUnreadable() {
        let missing = tmpDir.appendingPathComponent("does-not-exist.plist")
        XCTAssertEqual(UnsandboxedDataMigration.migrate(fromContainerPlist: missing, into: defaults), -1)
    }

    // MARK: - runIfNeeded() orchestration

    func test_runIfNeeded_noOp_whenSandboxed() throws {
        let src = try writePlist(["cli_pulse_show_cost": true])
        UnsandboxedDataMigration.runIfNeeded(
            defaults: defaults, isSandboxed: true, sandboxContainerPlist: src)
        XCTAssertNil(defaults.object(forKey: "cli_pulse_show_cost"))
        XCTAssertFalse(defaults.bool(forKey: UnsandboxedDataMigration.migrationDoneKey),
                       "sandboxed builds must not even mark the migration done")
    }

    func test_runIfNeeded_marksDone_whenContainerAbsent() {
        let absent = tmpDir.appendingPathComponent("no-container.plist")
        UnsandboxedDataMigration.runIfNeeded(
            defaults: defaults, isSandboxed: false, sandboxContainerPlist: absent)
        XCTAssertTrue(defaults.bool(forKey: UnsandboxedDataMigration.migrationDoneKey),
                      "a clean unsandboxed install marks done so we stop stat-ing")
    }

    func test_runIfNeeded_migratesAndMarksDone_whenContainerPresent() throws {
        let src = try writePlist(["cli_pulse_onboarding_completed": true])
        UnsandboxedDataMigration.runIfNeeded(
            defaults: defaults, isSandboxed: false, sandboxContainerPlist: src)
        XCTAssertTrue(defaults.bool(forKey: "cli_pulse_onboarding_completed"))
        XCTAssertTrue(defaults.bool(forKey: UnsandboxedDataMigration.migrationDoneKey))
    }

    func test_runIfNeeded_doesNotMarkDone_whenSourceUnreadable() throws {
        // A file that EXISTS but is not a valid plist → migrate() returns -1 →
        // must NOT mark done, so the next launch retries.
        let garbage = tmpDir.appendingPathComponent("garbage.plist")
        try Data("not a plist".utf8).write(to: garbage)
        UnsandboxedDataMigration.runIfNeeded(
            defaults: defaults, isSandboxed: false, sandboxContainerPlist: garbage)
        XCTAssertFalse(defaults.bool(forKey: UnsandboxedDataMigration.migrationDoneKey),
                       "a read failure must leave the flag unset to retry next launch")
    }

    func test_runIfNeeded_idempotent_whenAlreadyDone() throws {
        defaults.set(true, forKey: UnsandboxedDataMigration.migrationDoneKey)
        let src = try writePlist(["cli_pulse_show_cost": true])
        UnsandboxedDataMigration.runIfNeeded(
            defaults: defaults, isSandboxed: false, sandboxContainerPlist: src)
        XCTAssertNil(defaults.object(forKey: "cli_pulse_show_cost"),
                     "a second run must not re-migrate")
    }

    // MARK: - Allowlist contract (W4)

    /// Every app-owned `UserDefaults.standard` key must match an entry in
    /// `appOwnedKeyPrefixes`, or it strands on the DEVID unsandbox transition.
    /// This locks the audited contract (2026-06-28): adding a new
    /// standard-defaults namespace requires extending `appOwnedKeyPrefixes`.
    func test_appOwnedKeyPrefixes_coverEveryKnownStandardDefaultsKey() {
        func covered(_ k: String) -> Bool {
            UnsandboxedDataMigration.appOwnedKeyPrefixes.contains { k.hasPrefix($0) }
        }
        // Representative app-owned keys written to UserDefaults.standard.
        let knownKeys = [
            "cli_pulse_onboarding_completed",
            "cli_pulse_provider_configs",
            "cli_pulse_providers_disabled_by_tier",
            "cli_pulse_refresh_interval",
            "cli_pulse_appearance",
            "cli_pulse_locale_override",
            "cli_pulse_provider_secrets_migrated",
            "cli_pulse_keychain_group_migrated",
            "cli_pulse_alert_thresholds_v1",
            "cli_pulse_suppressed_alert_ids_v2",
            "privacy.skipClaudeKeychain",
            "privacy.localOnlyMode",
        ]
        for k in knownKeys {
            XCTAssertTrue(covered(k), "app-owned key '\(k)' is not in the migration allowlist")
        }
        // The cooldown key's app-group suite has a `.standard` fallback, so its
        // key MUST be prefixed too — assert against the real constant so a revert
        // to an unprefixed name fails here (verifier 2026-06-28).
        XCTAssertTrue(covered(ClaudeCredentials.keychainReadCooldownKey),
                      "ClaudeCredentials.keychainReadCooldownKey must match appOwnedKeyPrefixes")
    }

    // MARK: - Path helpers

    func test_sandboxContainerDefaultsPlist_shape() {
        let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
        let plist = UnsandboxedDataMigration.sandboxContainerDefaultsPlist(realHome: home)
        XCTAssertEqual(
            plist.path,
            "/Users/tester/Library/Containers/yyh.CLI-Pulse/Data/Library/Preferences/yyh.CLI-Pulse.plist")
    }

    func test_realUserHome_isAbsoluteExistingDirectory() {
        let home = UnsandboxedDataMigration.realUserHome()
        XCTAssertTrue(home.path.hasPrefix("/"))
        XCTAssertFalse(home.path.contains("/Library/Containers/"),
                       "getpwuid_r resolves the real home, never the sandbox container")
    }

    /// The thread-safe `passwdHomeDirectory()` (`getpwuid_r`) that replaced the
    /// scattered `getpwuid` calls must resolve a real, absolute home — and must
    /// agree with the legacy single-shot `getpwuid` it replaced.
    func test_passwdHomeDirectory_agreesWithLegacyGetpwuid() {
        guard let resolved = passwdHomeDirectory() else {
            return XCTFail("passwdHomeDirectory should resolve a home for the test user")
        }
        XCTAssertTrue(resolved.hasPrefix("/"), "home must be an absolute path")
        XCTAssertFalse(resolved.isEmpty)
        XCTAssertFalse(resolved.contains("/Library/Containers/"),
                       "passwd lookup bypasses the sandbox container redirect")
        // Cross-check against the legacy non-reentrant call: the _r variant must
        // return the identical home directory.
        if let pw = getpwuid(getuid()), let cstr = pw.pointee.pw_dir {
            XCTAssertEqual(resolved, String(cString: cstr),
                           "getpwuid_r must agree with getpwuid on the home dir")
        }
    }
}
#endif
