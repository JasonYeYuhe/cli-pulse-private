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

    // MARK: - SessionControlHello.implementation plumbing (v1.43 app-side)

    private func makeHello(impl: String?, version: String = "1.30.0") -> SessionControlHello {
        SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false),
            helperVersion: version,
            implementation: impl)
    }

    func test_sessionControlHello_implementationDefaultsNilForOlderHelpers() {
        let hello = SessionControlHello(
            protocolVersion: 1, supportedMethods: ["hello"],
            capabilities: SessionControlCapabilities(
                sendInput: true, subscribeEvents: false, approvals: false))
        XCTAssertNil(hello.implementation, "older helper (no implementation field) → nil")
        XCTAssertFalse(hello.isSwiftBundled, "nil implementation must not read as bundled")
    }

    func test_sessionControlHello_isSwiftBundledOnlyForExactValue() {
        XCTAssertTrue(makeHello(impl: "swift-bundled").isSwiftBundled)
        XCTAssertFalse(makeHello(impl: "python-pkg").isSwiftBundled)
        // Additive tolerance: an unknown future value must NOT read as bundled.
        XCTAssertFalse(makeHello(impl: "some-future-impl").isSwiftBundled)
        XCTAssertFalse(makeHello(impl: nil).isSwiftBundled)
    }

    // MARK: - resolveState (v1.43 nag suppression + regression pins)

    private func pkgManifest(_ version: String) -> HelperInstaller.Manifest {
        HelperInstaller.Manifest(
            version: version, arch: "arm64", url: "https://example.com/p.pkg",
            sha256: "abc", sizeBytes: 1, minOsVersion: "13.0", releaseNotesUrl: nil)
    }

    /// THE nag root-fix + primary regression pin: a bundled (swift-bundled)
    /// owner must resolve to `.bundled` even when the `.pkg` manifest advertises
    /// a HIGHER version. Pre-v1.43 this exact input produced `.updateAvailable`
    /// — the perpetual, unclearable nag. If this ever flips back to
    /// `.updateAvailable`, the shipped bug is back.
    func test_resolveState_bundledOwnerNeverNagsEvenWhenManifestNewer() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "swift-bundled", version: "1.29.0"),
            manifest: pkgManifest("1.30.0"),   // .pkg claims a newer version
            socketExists: true,
            udsPath: "/tmp/sock")
        XCTAssertEqual(state, .bundled(version: "1.29.0"),
                       "bundled owner must show .bundled, NOT .updateAvailable")
    }

    func test_resolveState_bundledOwnerIsBundledWithNoManifest() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "swift-bundled", version: "1.30.0"),
            manifest: nil, socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(state, .bundled(version: "1.30.0"))
    }

    /// Regression guard the OTHER direction: `.pkg` owners keep their update
    /// prompt exactly as before — the fix must not suppress legitimate nags.
    func test_resolveState_pkgOwnerOlderThanManifestStillNags() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "python-pkg", version: "1.29.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(state, .updateAvailable(installed: "1.29.0", latest: "1.30.0"))
    }

    /// A pre-v1.43 helper omits `implementation` (nil) → legacy `.pkg` compare
    /// path, byte-for-byte unchanged (backward compat: new app ↔ old helper).
    func test_resolveState_olderHelperMissingImplFallsBackToLegacyCompare() {
        let older = HelperInstaller.resolveState(
            hello: makeHello(impl: nil, version: "1.29.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(older, .updateAvailable(installed: "1.29.0", latest: "1.30.0"))
        let upToDate = HelperInstaller.resolveState(
            hello: makeHello(impl: nil, version: "1.30.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(upToDate, .running(version: "1.30.0"))
    }

    func test_resolveState_pkgOwnerUpToDateIsRunning() {
        let state = HelperInstaller.resolveState(
            hello: makeHello(impl: "python-pkg", version: "1.30.0"),
            manifest: pkgManifest("1.30.0"), socketExists: true, udsPath: "/tmp/sock")
        XCTAssertEqual(state, .running(version: "1.30.0"))
    }

    func test_resolveState_helloNilSocketPresentIsUnreachable() {
        let state = HelperInstaller.resolveState(
            hello: nil, manifest: pkgManifest("1.30.0"),
            socketExists: true, udsPath: "/tmp/x.sock")
        guard case .unreachable = state else {
            return XCTFail("socket present + no hello → .unreachable, got \(state)")
        }
    }

    func test_resolveState_helloNilNoSocketIsNotInstalled() {
        let state = HelperInstaller.resolveState(
            hello: nil, manifest: nil, socketExists: false, udsPath: "/tmp/x.sock")
        XCTAssertEqual(state, .notInstalled)
    }

    func test_shouldReprobe_bundledStateReprobesWhenStale() {
        // `.bundled` is a settled state: it must re-probe when stale (a helper
        // swap changes the reported version) but throttle when fresh.
        XCTAssertTrue(HelperInstaller.shouldReprobe(
            state: .bundled(version: "1.30.0"),
            lastChecked: t0.addingTimeInterval(-10), now: t0, maxAge: 8))
        XCTAssertTrue(HelperInstaller.shouldReprobe(
            state: .bundled(version: "1.30.0"),
            lastChecked: nil, now: t0, maxAge: 8))
        XCTAssertFalse(HelperInstaller.shouldReprobe(
            state: .bundled(version: "1.30.0"),
            lastChecked: t0.addingTimeInterval(-2), now: t0, maxAge: 8))
    }
}

#endif
