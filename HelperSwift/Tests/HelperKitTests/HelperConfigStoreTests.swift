import XCTest
@testable import HelperKit
import Foundation

/// Tests for the persisted local-control kill switch (Phase 4D
/// P1.2 — Codex review). Pin the invariant that the production
/// daemon respects whatever the file says, AND that flipping the
/// switch atomically persists.
final class HelperConfigStoreTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("HelperConfig-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func makeStore() -> HelperConfigStore {
        return HelperConfigStore(path: tmp.appendingPathComponent("cfg.json"))
    }

    func testLocalControlEnabledDefaultsFalseOnMissingFile() {
        XCTAssertFalse(makeStore().localControlEnabled,
                       "missing config file must read as DISABLED, matching Python's default")
    }

    func testLocalControlEnabledRespectsPersistedTrue() throws {
        let path = tmp.appendingPathComponent("cfg.json")
        try Data(#"{"local_control_enabled": true}"#.utf8).write(to: path)
        let store = HelperConfigStore(path: path)
        XCTAssertTrue(store.localControlEnabled)
    }

    func testLocalControlEnabledRespectsPersistedFalse() throws {
        let path = tmp.appendingPathComponent("cfg.json")
        try Data(#"{"local_control_enabled": false}"#.utf8).write(to: path)
        let store = HelperConfigStore(path: path)
        XCTAssertFalse(store.localControlEnabled)
    }

    func testSetLocalControlEnabledPersists() throws {
        let store = makeStore()
        store.setLocalControlEnabled(true)
        XCTAssertTrue(store.localControlEnabled)
        // Re-open the file with a fresh store to confirm the
        // value is on disk.
        let store2 = makeStore()
        XCTAssertTrue(store2.localControlEnabled)
    }

    func testSetLocalControlEnabledFlipsBackToFalse() throws {
        let store = makeStore()
        store.setLocalControlEnabled(true)
        store.setLocalControlEnabled(false)
        XCTAssertFalse(store.localControlEnabled)
        let store2 = makeStore()
        XCTAssertFalse(store2.localControlEnabled)
    }

    func testSetLocalControlEnabledPreservesUnknownKeys() throws {
        // Simulate a Python-written config that has device_id /
        // user_id / helper_secret etc. Swift mutates ONLY
        // `local_control_enabled` and keeps everything else.
        let path = tmp.appendingPathComponent("cfg.json")
        let seed: [String: Any] = [
            "device_id": "DID-123",
            "user_id": "UID-456",
            "device_name": "Jason's MacBook",
            "helper_version": "0.42",
            "helper_secret": "s3cr3t-do-not-touch",
            "local_control_enabled": false,
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: path)
        let store = HelperConfigStore(path: path)
        store.setLocalControlEnabled(true)
        // Re-read directly from disk and check every other key
        // is intact.
        let after = try JSONSerialization.jsonObject(with: try Data(contentsOf: path))
            as? [String: Any] ?? [:]
        XCTAssertEqual(after["device_id"] as? String, "DID-123")
        XCTAssertEqual(after["user_id"] as? String, "UID-456")
        XCTAssertEqual(after["device_name"] as? String, "Jason's MacBook")
        XCTAssertEqual(after["helper_version"] as? String, "0.42")
        XCTAssertEqual(after["helper_secret"] as? String, "s3cr3t-do-not-touch")
        XCTAssertEqual(after["local_control_enabled"] as? Bool, true)
    }

    func testWrittenFileHasMode0600() throws {
        let store = makeStore()
        store.setLocalControlEnabled(true)
        let path = tmp.appendingPathComponent("cfg.json")
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600,
                       "config file must be 0600 — same as Python writer")
    }
}
