import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Unit tests for HelperInstaller's pure-logic helpers (version comparison
/// and architecture gate). Network / file / UDS paths are out of scope for
/// unit tests — exercised in the v1.16 ship E2E checklist (plan §7).
final class HelperInstallerTests: XCTestCase {

    func test_compareVersions_equalReturnsZero() {
        XCTAssertEqual(HelperInstaller.compareVersions("1.16.0", "1.16.0"), 0)
        XCTAssertEqual(HelperInstaller.compareVersions("1.0.0", "1.0.0"), 0)
    }

    func test_compareVersions_olderReturnsNegative() {
        XCTAssertLessThan(HelperInstaller.compareVersions("1.15.0", "1.16.0"), 0)
        XCTAssertLessThan(HelperInstaller.compareVersions("1.16.0", "1.16.1"), 0)
        XCTAssertLessThan(HelperInstaller.compareVersions("0.0.0", "1.0.0"), 0)
    }

    func test_compareVersions_newerReturnsPositive() {
        XCTAssertGreaterThan(HelperInstaller.compareVersions("1.16.1", "1.16.0"), 0)
        XCTAssertGreaterThan(HelperInstaller.compareVersions("2.0.0", "1.99.99"), 0)
    }

    func test_compareVersions_handlesShortVersionStrings() {
        // "1.16" treated as "1.16.0"
        XCTAssertEqual(HelperInstaller.compareVersions("1.16", "1.16.0"), 0)
        XCTAssertLessThan(HelperInstaller.compareVersions("1.16", "1.16.1"), 0)
    }

    func test_assertArchitectureMatches_failsWhenWrong() {
        // Build a manifest claiming the OPPOSITE arch from the host so we
        // can prove the guard fires. Rather than hard-coding which arch
        // we're on, just assert that one of the two is wrong.
        let armManifest = HelperInstaller.Manifest(
            version: "1.16.0",
            arch: "arm64",
            url: "https://example.com/p.pkg",
            sha256: "abc",
            sizeBytes: 1,
            minOsVersion: "13.0",
            releaseNotesUrl: nil
        )
        let intelManifest = HelperInstaller.Manifest(
            version: "1.16.0",
            arch: "x86_64",
            url: "https://example.com/p.pkg",
            sha256: "abc",
            sizeBytes: 1,
            minOsVersion: "13.0",
            releaseNotesUrl: nil
        )
        // Exactly one of the two should throw.
        let armPasses = (try? HelperInstaller.assertArchitectureMatches(armManifest)) != nil
        let intelPasses = (try? HelperInstaller.assertArchitectureMatches(intelManifest)) != nil
        XCTAssertTrue(armPasses != intelPasses, "Exactly one arch should match this host")
    }

    // MARK: - shouldReprobe (RC-2 popover-reopen re-probe gate)

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func test_shouldReprobe_midFlightStatesNeverReprobe() {
        // The install/refresh flow owns these — a popover re-open must not
        // race it, regardless of how old lastChecked is.
        for state in [HelperInstaller.State.downloading(progress: 0.5),
                      .installing,
                      .checking] {
            XCTAssertFalse(
                HelperInstaller.shouldReprobe(
                    state: state, lastChecked: nil, now: t0, maxAge: 8),
                "\(state) should never re-probe (nil lastChecked)")
            XCTAssertFalse(
                HelperInstaller.shouldReprobe(
                    state: state,
                    lastChecked: t0.addingTimeInterval(-3600),
                    now: t0, maxAge: 8),
                "\(state) should never re-probe (very stale lastChecked)")
        }
    }

    func test_shouldReprobe_settledStatesReprobeWhenStale() {
        // The post-install case: state settled `.notInstalled` but the helper
        // bound its socket later; on the next popover open (> maxAge) we must
        // re-probe so it flips to `.running`.
        let settled: [HelperInstaller.State] = [
            .notInstalled, .unreachable("sock"), .error("x"),
            .running(version: "1.18.0"),
            .updateAvailable(installed: "1.17.0", latest: "1.18.0"),
        ]
        for state in settled {
            // Older than maxAge → re-probe.
            XCTAssertTrue(
                HelperInstaller.shouldReprobe(
                    state: state,
                    lastChecked: t0.addingTimeInterval(-10),
                    now: t0, maxAge: 8),
                "\(state) older than maxAge should re-probe")
            // Never checked → re-probe.
            XCTAssertTrue(
                HelperInstaller.shouldReprobe(
                    state: state, lastChecked: nil, now: t0, maxAge: 8),
                "\(state) with nil lastChecked should re-probe")
        }
    }

    func test_shouldReprobe_settledStatesThrottleWhenFresh() {
        // Rapid open/close toggling within maxAge must not hammer the
        // manifest endpoint with overlapping refreshes.
        for state in [HelperInstaller.State.notInstalled,
                      .running(version: "1.18.0")] {
            XCTAssertFalse(
                HelperInstaller.shouldReprobe(
                    state: state,
                    lastChecked: t0.addingTimeInterval(-2),
                    now: t0, maxAge: 8),
                "\(state) checked 2s ago should NOT re-probe (maxAge 8)")
        }
    }

    // MARK: - SessionControlHello.paired plumbing (RC-1 app-side)

    func test_sessionControlHello_pairedDefaultsNilForOlderHelpers() {
        let hello = SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false))
        XCTAssertNil(hello.paired, "older helper (no paired field) → nil")
    }

    func test_sessionControlHello_pairedRoundTrips() {
        let unpaired = SessionControlHello(
            protocolVersion: 1, supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false),
            paired: false)
        XCTAssertEqual(unpaired.paired, false)
    }
}

#endif
