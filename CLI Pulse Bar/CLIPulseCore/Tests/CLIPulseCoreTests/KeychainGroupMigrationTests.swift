import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Covers `KeychainHelper.migrateToSharedGroup(key:)` — the one-time
/// re-homing of legacy no-access-group keychain items into the shared
/// app-group keychain (`group.yyh.CLI-Pulse`). That migration is what stops
/// the recurring "CLIPulseHelper wants to use information stored by ... in
/// your keychain" consent prompt: once a per-provider apiKey/cookie lives in
/// the shared group, the LoginItem helper reads it prompt-free.
///
/// NOTE: under an unsigned `swift test` host the macOS file keychain does not
/// strictly partition by `kSecAttrAccessGroup` (the same loose behavior the
/// existing `HelperConfigCrossAccountGuardTests` relies on), so these
/// assertions are written to hold *regardless* of whether the host enforces
/// group partitioning. The strict no-prompt behavior itself is a runtime
/// property of a properly-signed build and is verified on-device.
final class KeychainGroupMigrationTests: XCTestCase {

    private let key = "cli_pulse_test_keychain_group_migration"
    private let group = KeychainHelper.sharedAccessGroup

    private func clear() {
        KeychainHelper.delete(key: key)
        KeychainHelper.delete(key: key, accessGroup: group)
    }

    override func setUp() {
        super.setUp()
        clear()
    }

    override func tearDown() {
        clear()
        super.tearDown()
    }

    /// A legacy item written with NO access group is readable from the shared
    /// group after migration.
    func testMigrateCopiesLegacyValueIntoGroup() {
        KeychainHelper.save(key: key, value: "legacy-secret") // no access group
        KeychainHelper.migrateToSharedGroup(key: key)
        XCTAssertEqual(
            KeychainHelper.load(key: key, accessGroup: group),
            "legacy-secret",
            "after migration the value must be readable via the shared access group"
        )
    }

    /// Nothing stored ⇒ migration is a harmless no-op that creates no item.
    func testMigrateIsNoOpWhenNothingStored() {
        KeychainHelper.migrateToSharedGroup(key: key)
        XCTAssertNil(
            KeychainHelper.load(key: key, accessGroup: group),
            "migration must not invent an item when there is nothing to migrate"
        )
    }

    /// An existing in-group value is preserved (the early-return guard must not
    /// overwrite it). The migration never deletes the legacy copy, so this also
    /// pins that a second pass is safe.
    func testMigratePreservesExistingGroupValue() {
        KeychainHelper.save(key: key, value: "group-value", accessGroup: group)
        KeychainHelper.migrateToSharedGroup(key: key)
        XCTAssertEqual(
            KeychainHelper.load(key: key, accessGroup: group),
            "group-value",
            "an already-migrated value must survive a re-run of the migration"
        )
    }

    /// Idempotent: running the migration twice leaves the value intact.
    func testMigrateIsIdempotent() {
        KeychainHelper.save(key: key, value: "legacy-secret") // no access group
        KeychainHelper.migrateToSharedGroup(key: key)
        KeychainHelper.migrateToSharedGroup(key: key)
        XCTAssertEqual(
            KeychainHelper.load(key: key, accessGroup: group),
            "legacy-secret",
            "repeated migration passes must be safe and value-preserving"
        )
    }
}

#endif
