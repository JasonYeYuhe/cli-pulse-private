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

    // MARK: - B3-bis cloudConfigSnapshot three-layer fallback

    private static let fakeSupabase = SupabaseConfigResolver.Resolved(
        url: "https://test.supabase.co",
        anonKey: "test-anon-key"
    )

    func testCloudConfigSnapshot_readsFromUserDefaults_whenAvailable() {
        let store = makeStore()
        let snapshot = store.cloudConfigSnapshot(
            appGroupReader: {
                AppGroupConfigReader.AppPairing(
                    deviceId: "modern-device-id",
                    helperSecret: "modern-secret"
                )
            },
            supabaseResolver: { Self.fakeSupabase },
            legacyJSON: { (deviceId: "should-be-ignored", helperSecret: "ignored") }
        )
        XCTAssertEqual(snapshot.deviceId, "modern-device-id")
        XCTAssertEqual(snapshot.helperSecret, "modern-secret")
        XCTAssertEqual(snapshot.supabaseURL, "https://test.supabase.co")
        XCTAssertEqual(snapshot.supabaseAnonKey, "test-anon-key")
        XCTAssertTrue(snapshot.isPaired)
    }

    func testCloudConfigSnapshot_fallsBackToJSON_whenUserDefaultsEmpty() throws {
        // Seed the legacy JSON file with paired state
        let path = tmp.appendingPathComponent("cfg.json")
        let seed: [String: Any] = [
            "device_id": "legacy-device",
            "helper_secret": "legacy-secret",
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: path)
        let store = HelperConfigStore(path: path)

        let snapshot = store.cloudConfigSnapshot(
            appGroupReader: { nil },
            supabaseResolver: { Self.fakeSupabase },
            legacyJSON: nil  // use real readLegacyJSONPairing()
        )
        XCTAssertEqual(snapshot.deviceId, "legacy-device")
        XCTAssertEqual(snapshot.helperSecret, "legacy-secret")
        XCTAssertEqual(snapshot.supabaseURL, "https://test.supabase.co")
        XCTAssertTrue(snapshot.isPaired)
    }

    func testCloudConfigSnapshot_unpairedWhenBothEmpty() {
        let store = makeStore()
        let snapshot = store.cloudConfigSnapshot(
            appGroupReader: { nil },
            supabaseResolver: { Self.fakeSupabase },
            legacyJSON: { (deviceId: "", helperSecret: "") }
        )
        XCTAssertEqual(snapshot.deviceId, "")
        XCTAssertEqual(snapshot.helperSecret, "")
        // Supabase URL still populated — daemon can reach Supabase
        // but has no pairing credentials, so cloud RPCs skip.
        XCTAssertEqual(snapshot.supabaseURL, "https://test.supabase.co")
        XCTAssertFalse(snapshot.isPaired)
    }

    func testCloudConfigSnapshot_unpairedWhenSupabaseResolverFails() {
        let store = makeStore()
        let snapshot = store.cloudConfigSnapshot(
            appGroupReader: {
                // Even with valid pairing, no Supabase = cannot dispatch
                AppGroupConfigReader.AppPairing(
                    deviceId: "x", helperSecret: "y"
                )
            },
            supabaseResolver: { nil },
            legacyJSON: nil
        )
        // All four fields empty — Supabase unreachable
        XCTAssertEqual(snapshot.supabaseURL, "")
        XCTAssertEqual(snapshot.supabaseAnonKey, "")
        XCTAssertEqual(snapshot.deviceId, "")
        XCTAssertFalse(snapshot.isPaired)
    }

    func testCloudConfigSnapshot_preferences_modernOverLegacy() throws {
        // Both modern + legacy populated; modern wins.
        let path = tmp.appendingPathComponent("cfg.json")
        let seed: [String: Any] = [
            "device_id": "legacy-device",
            "helper_secret": "legacy-secret",
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: path)
        let store = HelperConfigStore(path: path)

        let snapshot = store.cloudConfigSnapshot(
            appGroupReader: {
                AppGroupConfigReader.AppPairing(
                    deviceId: "modern-device",
                    helperSecret: "modern-secret"
                )
            },
            supabaseResolver: { Self.fakeSupabase },
            legacyJSON: nil
        )
        XCTAssertEqual(snapshot.deviceId, "modern-device",
                       "modern UserDefaults takes precedence over legacy JSON")
        XCTAssertEqual(snapshot.helperSecret, "modern-secret")
    }

    // MARK: - remoteRealtimeEnabled (v1.25 Phase 2c slice 4)

    func testRemoteRealtimeEnabledDefaultsTrueOnMissingFile() {
        // Default is TRUE — terminal mirror is opt-out. Missing file
        // = fresh install / unpaired = default behavior.
        XCTAssertTrue(makeStore().remoteRealtimeEnabled,
                      "missing config must read as ENABLED — terminal mirror is opt-out")
    }

    func testRemoteRealtimeEnabledDefaultsTrueOnMissingKey() throws {
        // Existing config without the new key still defaults true.
        // A pre-v1.25 helper.json that has device_id+helper_secret
        // but no `remote_realtime_enabled` key must NOT silently
        // disable the feature.
        let path = tmp.appendingPathComponent("cfg.json")
        try Data(#"{"device_id":"d","helper_secret":"s"}"#.utf8).write(to: path)
        let store = HelperConfigStore(path: path)
        XCTAssertTrue(store.remoteRealtimeEnabled)
    }

    func testRemoteRealtimeEnabledRespectsPersistedFalse() throws {
        // Kill switch: ops sets `false` to stop Realtime broadcasts.
        let path = tmp.appendingPathComponent("cfg.json")
        try Data(#"{"remote_realtime_enabled":false}"#.utf8).write(to: path)
        let store = HelperConfigStore(path: path)
        XCTAssertFalse(store.remoteRealtimeEnabled)
    }

    func testRemoteRealtimeEnabledRespectsPersistedTrue() throws {
        // Explicit true round-trip. Distinct from default-true so a
        // future flip of the default (e.g. opt-in for v2) can't
        // silently break explicit user opt-ins.
        let path = tmp.appendingPathComponent("cfg.json")
        try Data(#"{"remote_realtime_enabled":true}"#.utf8).write(to: path)
        let store = HelperConfigStore(path: path)
        XCTAssertTrue(store.remoteRealtimeEnabled)
    }

    func testRemoteRealtimeEnabledIsIndependentFromLocalControl() throws {
        // The two kill switches are orthogonal — one gates UDS local
        // control, the other gates the Supabase Realtime broadcast
        // path. Both must read correctly in every combination.
        for (localControl, realtime) in [(false, false), (false, true),
                                          (true, false), (true, true)] {
            let path = tmp.appendingPathComponent("cfg-\(localControl)-\(realtime).json")
            let seed: [String: Any] = [
                "local_control_enabled": localControl,
                "remote_realtime_enabled": realtime,
            ]
            try JSONSerialization.data(withJSONObject: seed).write(to: path)
            let store = HelperConfigStore(path: path)
            XCTAssertEqual(store.localControlEnabled, localControl,
                           "local_control_enabled mismatch for \(localControl)/\(realtime)")
            XCTAssertEqual(store.remoteRealtimeEnabled, realtime,
                           "remote_realtime_enabled mismatch for \(localControl)/\(realtime)")
        }
    }

    func testSetLocalControlEnabledPreservesRealtimeKey() throws {
        // Read-modify-write of local_control_enabled must NOT
        // clobber remote_realtime_enabled — Swift's HelperConfigStore
        // keeps unknown keys in `raw` so Python's older writer's
        // fields survive a Swift rewrite. Verify the new key
        // participates in that preservation.
        let path = tmp.appendingPathComponent("cfg.json")
        let seed: [String: Any] = [
            "device_id": "d",
            "helper_secret": "s",
            "remote_realtime_enabled": false,
            "local_control_enabled": false,
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: path)
        let store = HelperConfigStore(path: path)
        store.setLocalControlEnabled(true)
        let after = try JSONSerialization.jsonObject(with: try Data(contentsOf: path))
            as? [String: Any] ?? [:]
        XCTAssertEqual(after["local_control_enabled"] as? Bool, true)
        XCTAssertEqual(after["remote_realtime_enabled"] as? Bool, false,
                       "remote_realtime_enabled must survive a setLocalControlEnabled write")
    }

    // MARK: - StoredConfig schema parity check

    func testStoredConfigSchemaMatchesAppEncoding() throws {
        // Round-trip a payload encoded the way the macOS app's
        // CLIPulseCore.HelperConfig.StoredConfig encodes. If the
        // app's StoredConfig adds/removes a field without updating
        // HelperKit's mirror, this test breaks the bridge before
        // ship.
        //
        // Golden JSON matches the app's StoredConfig field set:
        // deviceId, userId (optional), deviceName (optional),
        // helperVersion (optional).
        let goldenJSON = """
        {
            "deviceId": "abc-123",
            "userId": "user-456",
            "deviceName": "Test Mac",
            "helperVersion": "1.17.3"
        }
        """
        let data = goldenJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            AppGroupConfigReader.StoredConfig.self,
            from: data
        )
        XCTAssertEqual(decoded.deviceId, "abc-123")
        XCTAssertEqual(decoded.userId, "user-456")
        XCTAssertEqual(decoded.deviceName, "Test Mac")
        XCTAssertEqual(decoded.helperVersion, "1.17.3")
    }

    func testStoredConfigSchema_tolerates_missingOptionals() throws {
        // The macOS app may write a StoredConfig with userId /
        // deviceName / helperVersion absent (Codable encodes nil as
        // missing key by default). The mirror must decode this case.
        let minimalJSON = #"{"deviceId":"only-the-required-field"}"#
        let data = minimalJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(
            AppGroupConfigReader.StoredConfig.self,
            from: data
        )
        XCTAssertEqual(decoded.deviceId, "only-the-required-field")
        XCTAssertNil(decoded.userId)
        XCTAssertNil(decoded.deviceName)
        XCTAssertNil(decoded.helperVersion)
    }
}
