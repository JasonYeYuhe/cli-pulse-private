import XCTest
@testable import CLIPulseCore

// v1.21 D5: AppUpdater is compiled only under DEVID_BUILD now. Tests are
// skipped when DEVID_BUILD is not set (e.g., default `swift test` from the
// CLIPulseCore package). The Xcode CI scheme for DEVID passes the flag.
#if os(macOS) && DEVID_BUILD

/// Unit tests for AppUpdater's pure-logic helpers (version comparison,
/// architecture gate, manifest decode). Network / file / Finder-handoff
/// paths are exercised in the v1.19 ship E2E checklist (plan §D8).
final class AppUpdaterTests: XCTestCase {

    // MARK: - refreshIfStale (passive discovery, post-1.42.0 audit)

    /// A manifest URL that fails fast with no network: nonexistent local file.
    private static let deadManifestURL = URL(
        fileURLWithPath: "/nonexistent-cli-pulse-test/latest.json")

    /// Regression for the codex-review P1: `state`'s INITIAL value is
    /// `.checking` with no request behind it. A refreshIfStale that gates on
    /// state would return early on every fresh launch and passive discovery
    /// would never run. It must gate on `inFlight` instead and attempt the
    /// fetch (which here fails fast → .error, proving it TRIED).
    @MainActor
    func test_refreshIfStale_attemptsFetchOnFreshLaunch() async {
        let updater = AppUpdater(manifestURL: Self.deadManifestURL)
        XCTAssertNil(updater.lastChecked)
        await updater.refreshIfStale()
        XCTAssertNotNil(updater.lastChecked, "fresh launch must attempt a check")
        guard case .error = updater.state else {
            return XCTFail("expected .error from dead manifest URL, got \(updater.state)")
        }
    }

    @MainActor
    func test_refreshIfStale_throttlesWithinMaxAge() async {
        let updater = AppUpdater(manifestURL: Self.deadManifestURL)
        await updater.refreshIfStale()
        let first = updater.lastChecked
        XCTAssertNotNil(first)
        await updater.refreshIfStale()  // immediately again — must be a no-op
        XCTAssertEqual(updater.lastChecked, first, "second call within maxAge must not re-fetch")
    }

    @MainActor
    func test_refreshIfStale_refetchesAfterMaxAge() async {
        let updater = AppUpdater(manifestURL: Self.deadManifestURL)
        await updater.refreshIfStale()
        let first = updater.lastChecked
        XCTAssertNotNil(first)
        // Pretend 25h passed by moving `now` forward instead of the clock.
        await updater.refreshIfStale(now: Date().addingTimeInterval(25 * 60 * 60))
        XCTAssertNotEqual(updater.lastChecked, first, "stale check must re-fetch")
    }

    /// Regression for the #377 independent-review finding: a user's Download
    /// click racing a background refresh must WAIT for it, never be silently
    /// dropped. If `download()` bailed on seeing the in-flight task, `state`
    /// would still be the pristine initial `.checking` afterwards; because it
    /// joins and then runs, the dead manifest URL drives it to `.error`.
    @MainActor
    func test_download_waitsOutInFlightRefresh_neverSilentlyDropped() async {
        let updater = AppUpdater(manifestURL: Self.deadManifestURL)
        updater.refreshTask = Task { try? await Task.sleep(nanoseconds: 200_000_000) }
        let started = Date()
        await updater.download()
        XCTAssertGreaterThanOrEqual(
            Date().timeIntervalSince(started), 0.15,
            "download must await the in-flight refresh, not bail early")
        guard case .error = updater.state else {
            return XCTFail("download must run after the join; state is \(updater.state)")
        }
    }

    func test_compareVersions_equalReturnsZero() {
        XCTAssertEqual(AppUpdater.compareVersions("1.19.0", "1.19.0"), 0)
        XCTAssertEqual(AppUpdater.compareVersions("1.0.0", "1.0.0"), 0)
    }

    func test_compareVersions_olderReturnsNegative() {
        XCTAssertLessThan(AppUpdater.compareVersions("1.18.1", "1.19.0"), 0)
        XCTAssertLessThan(AppUpdater.compareVersions("1.19.0", "1.19.1"), 0)
        XCTAssertLessThan(AppUpdater.compareVersions("0.0.0", "1.0.0"), 0)
    }

    func test_compareVersions_newerReturnsPositive() {
        XCTAssertGreaterThan(AppUpdater.compareVersions("1.19.1", "1.19.0"), 0)
        XCTAssertGreaterThan(AppUpdater.compareVersions("2.0.0", "1.99.99"), 0)
    }

    func test_compareVersions_handlesShortVersionStrings() {
        XCTAssertEqual(AppUpdater.compareVersions("1.19", "1.19.0"), 0)
        XCTAssertLessThan(AppUpdater.compareVersions("1.19", "1.19.1"), 0)
    }

    func test_assertArchitectureMatches_failsWhenWrong() {
        let armManifest = AppUpdater.Manifest(
            version: "1.19.0",
            build: "60",
            channel: "devid",
            arch: "arm64",
            url: "https://example.com/CLI-Pulse-1.19.0-arm64.dmg",
            sha256: "abc",
            sizeBytes: 1,
            minOsVersion: "13.0",
            releaseNotesUrl: nil
        )
        let intelManifest = AppUpdater.Manifest(
            version: "1.19.0",
            build: "60",
            channel: "devid",
            arch: "x86_64",
            url: "https://example.com/CLI-Pulse-1.19.0-x86_64.dmg",
            sha256: "abc",
            sizeBytes: 1,
            minOsVersion: "13.0",
            releaseNotesUrl: nil
        )
        let armPasses = (try? AppUpdater.assertArchitectureMatches(armManifest)) != nil
        let intelPasses = (try? AppUpdater.assertArchitectureMatches(intelManifest)) != nil
        XCTAssertTrue(armPasses != intelPasses, "Exactly one arch should match this host")
    }

    /// AppUpdater.Manifest schema extends HelperInstaller.Manifest with
    /// `build` and `channel` fields. Verify both required-field decode
    /// and optional-field decode.
    func test_manifestDecode_minimalFields() throws {
        let json = """
        {
          "version": "1.19.0",
          "arch": "arm64",
          "url": "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.19.0/CLI-Pulse-1.19.0-arm64.dmg",
          "sha256": "deadbeef",
          "size_bytes": 12345678,
          "min_os_version": "13.0"
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(AppUpdater.Manifest.self, from: json)
        XCTAssertEqual(m.version, "1.19.0")
        XCTAssertEqual(m.arch, "arm64")
        XCTAssertEqual(m.sizeBytes, 12345678)
        XCTAssertEqual(m.minOsVersion, "13.0")
        XCTAssertNil(m.build)
        XCTAssertNil(m.channel)
        XCTAssertNil(m.releaseNotesUrl)
    }

    func test_manifestDecode_withChannelAndBuild() throws {
        let json = """
        {
          "version": "1.19.0",
          "build": "60",
          "channel": "devid",
          "arch": "arm64",
          "url": "https://example.com/x.dmg",
          "sha256": "deadbeef",
          "size_bytes": 1,
          "min_os_version": "13.0",
          "release_notes_url": "https://example.com/notes"
        }
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(AppUpdater.Manifest.self, from: json)
        XCTAssertEqual(m.build, "60")
        XCTAssertEqual(m.channel, "devid")
        XCTAssertEqual(m.releaseNotesUrl, "https://example.com/notes")
    }

    func test_installedVersion_readsBundleInfoDictionary() {
        // The default Bundle.main for test executables doesn't have a
        // CFBundleShortVersionString set, so this lands on the fallback.
        // We're verifying the path is non-crashing, not asserting a value.
        let v = AppUpdater.installedVersion()
        XCTAssertFalse(v.isEmpty)
    }
}

#endif
