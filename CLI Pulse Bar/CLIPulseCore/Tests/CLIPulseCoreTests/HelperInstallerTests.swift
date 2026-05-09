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
}

#endif
