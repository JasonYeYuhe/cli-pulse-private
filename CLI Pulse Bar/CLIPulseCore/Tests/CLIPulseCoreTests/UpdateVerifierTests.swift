import XCTest
@testable import CLIPulseCore

// Trust Hardening v2 (2026-06-30). UpdateVerifier is compiled only under DEVID_BUILD
// (like AppUpdater), so these tests run under `swift test -Xswiftc -DDEVID_BUILD`
// (the CI "DEVID swift test" step) and are skipped from the default `swift test`.
#if os(macOS) && DEVID_BUILD

/// Pure-logic tests (offline, deterministic). The IO path (real signed/notarized DMG)
/// is exercised by `test_realDMG_passes_whenProvided` when `CLIPULSE_TEST_DMG` points at
/// a genuine DMG, and by PR-3's published-artifact CI gate.
final class UpdateVerifierTests: XCTestCase {

    private let okURL =
        "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/CLI-Pulse-1.34.0-arm64.dmg"

    // MARK: manifest URL allowlist

    func test_validateManifestURL_acceptsOfficialReleasePrefix() {
        XCTAssertNoThrow(try UpdateVerifier.validateManifestURL(okURL))
    }

    func test_validateManifestURL_rejectsHTTP() {
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "http://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/x.dmg"
        )) { XCTAssertEqual($0 as? UpdateVerifierError,
                            .manifestInsecureScheme("http://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/x.dmg")) }
    }

    func test_validateManifestURL_rejectsWrongHost() {
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "https://evil.example.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/x.dmg"
        ))
    }

    func test_validateManifestURL_rejectsWrongRepoPath() {
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "https://github.com/attacker/evil-repo/releases/download/v1/x.dmg"
        ))
    }

    func test_validateManifestURL_rejectsDotSegmentTraversal() {
        // deep-audit 2026-07-04 (P1): raw hasPrefix passed this — it has the
        // allowed prefix but normalizes to a different repository.
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/../../../../apple/swift/releases/download/app-v1.34.0/x.dmg"
        ))
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/%2e%2e/%2e%2e/apple/swift/app-v1.34.0/x.dmg"
        ))
    }

    func test_validateManifestURL_rejectsUserinfoAndPort() {
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "https://evil@github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/x.dmg"))
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(
            "https://github.com:8443/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/x.dmg"))
    }

    func test_validateManifestURL_rejectsGarbage() {
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL("not a url"))
        XCTAssertThrowsError(try UpdateVerifier.validateManifestURL(""))
    }

    func test_isAllowedAuxURL() {
        XCTAssertTrue(UpdateVerifier.isAllowedAuxURL(okURL))
        XCTAssertTrue(UpdateVerifier.isAllowedAuxURL(
            "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/tag/app-v1.34.0"))
        XCTAssertFalse(UpdateVerifier.isAllowedAuxURL("https://phishing.example.com/notes"))
        XCTAssertFalse(UpdateVerifier.isAllowedAuxURL(nil))
    }

    // MARK: size

    func test_validateSize_inRange() {
        XCTAssertNoThrow(try UpdateVerifier.validateSize(21_588_491))
        XCTAssertNoThrow(try UpdateVerifier.validateSize(1))
        XCTAssertNoThrow(try UpdateVerifier.validateSize(UpdateVerifier.maxArtifactBytes))
    }

    func test_validateSize_rejectsOutOfRange() {
        XCTAssertThrowsError(try UpdateVerifier.validateSize(0))
        XCTAssertThrowsError(try UpdateVerifier.validateSize(-5))
        XCTAssertThrowsError(try UpdateVerifier.validateSize(UpdateVerifier.maxArtifactBytes + 1))
    }

    func test_assertSizeMatch() {
        XCTAssertNoThrow(try UpdateVerifier.assertSizeMatch(expected: 100, actual: 100))
        XCTAssertThrowsError(try UpdateVerifier.assertSizeMatch(expected: 100, actual: 99))
    }

    // MARK: downgrade protection

    func test_assertUpgrade_acceptsStrictlyNewer() {
        XCTAssertNoThrow(try UpdateVerifier.assertUpgrade(installed: "1.33.0", candidate: "1.34.0"))
        XCTAssertNoThrow(try UpdateVerifier.assertUpgrade(installed: "1.34.0", candidate: "1.34.1"))
    }

    func test_assertUpgrade_rejectsEqualOrOlder() {
        XCTAssertThrowsError(try UpdateVerifier.assertUpgrade(installed: "1.34.0", candidate: "1.34.0"))
        XCTAssertThrowsError(try UpdateVerifier.assertUpgrade(installed: "1.34.0", candidate: "1.33.0"))
    }

    // MARK: version/build match (closes the spoofed-high-manifest downgrade)

    func test_assertVersionMatch_matchingVersionAndBuild() {
        XCTAssertNoThrow(try UpdateVerifier.assertVersionMatch(
            appShortVersion: "1.34.0", appBuild: "84",
            manifestVersion: "1.34.0", manifestBuild: "84"))
    }

    func test_assertVersionMatch_versionMismatchThrows() {
        // The attack: manifest claims 99.0.0 but the (legit, old) app is 1.0.0.
        XCTAssertThrowsError(try UpdateVerifier.assertVersionMatch(
            appShortVersion: "1.0.0", appBuild: "1",
            manifestVersion: "99.0.0", manifestBuild: "1")) {
            XCTAssertEqual($0 as? UpdateVerifierError, .versionMismatch(expected: "99.0.0", found: "1.0.0"))
        }
    }

    func test_assertVersionMatch_buildMismatchThrows() {
        XCTAssertThrowsError(try UpdateVerifier.assertVersionMatch(
            appShortVersion: "1.34.0", appBuild: "83",
            manifestVersion: "1.34.0", manifestBuild: "84"))
    }

    func test_assertVersionMatch_nilAppVersionThrows() {
        XCTAssertThrowsError(try UpdateVerifier.assertVersionMatch(
            appShortVersion: nil, appBuild: "84",
            manifestVersion: "1.34.0", manifestBuild: "84")) {
            XCTAssertEqual($0 as? UpdateVerifierError, .infoPlistUnreadable)
        }
    }

    func test_assertVersionMatch_nilManifestBuildSkipsBuildCheck() {
        XCTAssertNoThrow(try UpdateVerifier.assertVersionMatch(
            appShortVersion: "1.34.0", appBuild: nil,
            manifestVersion: "1.34.0", manifestBuild: nil))
    }

    // MARK: real-DMG integration (env-gated; the no-false-reject gate)

    /// Run with `CLIPULSE_TEST_DMG=/path/to/CLI-Pulse-1.34.0-arm64.dmg swift test
    /// -Xswiftc -DDEVID_BUILD` against a GENUINE signed+notarized DMG to prove the
    /// verifier does NOT false-reject a legitimate update. Skipped otherwise.
    func test_realDMG_passes_whenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPULSE_TEST_DMG"] else {
            throw XCTSkip("set CLIPULSE_TEST_DMG to a genuine notarized DMG to run this")
        }
        let dmg = URL(fileURLWithPath: path)
        XCTAssertNoThrow(try UpdateVerifier.verifyDMGContainer(dmg),
                         "legitimate notarized DMG must pass container verification")
        let mv = ProcessInfo.processInfo.environment["CLIPULSE_TEST_DMG_VERSION"] ?? "1.34.0"
        let mb = ProcessInfo.processInfo.environment["CLIPULSE_TEST_DMG_BUILD"]
        let mount = try UpdateVerifier.mountAndVerifyApp(
            dmg: dmg, manifestVersion: mv, manifestBuild: mb, installedVersion: "0.0.0")
        defer { UpdateVerifier.detach(device: mount.device) }
        XCTAssertTrue(mount.appPath.lastPathComponent.hasSuffix(".app"))
    }

    // MARK: selectMount (detach the mount-carrying volume's whole disk, not shortest)

    func test_selectMount_multiVolume_picksMountCarryingWholeDisk() {
        // Real-shape multi-volume hdiutil output: the mount is on /dev/disk13s1, but the
        // globally-shortest dev-entry is /dev/disk12 (a DIFFERENT disk). Must detach
        // /dev/disk13 (the mount-carrier's whole disk), not /dev/disk12.
        let entities: [[String: Any]] = [
            ["dev-entry": "/dev/disk12s1"],
            ["dev-entry": "/dev/disk12"],
            ["dev-entry": "/dev/disk13s1", "mount-point": "/private/tmp/dmg.q8h07U"],
            ["dev-entry": "/dev/disk13"],
        ]
        let sel = UpdateVerifier.selectMount(from: entities)
        XCTAssertEqual(sel?.device, "/dev/disk13")
        XCTAssertEqual(sel?.mountpoint, "/private/tmp/dmg.q8h07U")
    }

    func test_selectMount_singleVolume() {
        let entities: [[String: Any]] = [
            ["dev-entry": "/dev/disk7"],
            ["dev-entry": "/dev/disk7s1", "mount-point": "/Volumes/CLI Pulse"],
        ]
        XCTAssertEqual(UpdateVerifier.selectMount(from: entities)?.device, "/dev/disk7")
    }

    func test_selectMount_noMountPoint_returnsNil() {
        XCTAssertNil(UpdateVerifier.selectMount(from: [["dev-entry": "/dev/disk9"]]))
        XCTAssertNil(UpdateVerifier.selectMount(from: []))
    }

    func test_selectMount_mountEntityWithoutDevEntry_fallsBackToMountpoint() {
        let entities: [[String: Any]] = [["mount-point": "/Volumes/X"]]
        XCTAssertEqual(UpdateVerifier.selectMount(from: entities)?.device, "/Volumes/X")
    }
}

#endif
