import XCTest
@testable import CLIPulseCore

// F8 (deep-audit 2026-07-04) — helper .pkg installer authenticity + downgrade.
// The pure entry points are compiled in ALL builds (unlike UpdateVerifier, which
// is DEVID-only), so these run in the default `swift test`. The subprocess
// signature path (verifyPkgSignatureAndNotarization) is DEVID-only and exercised
// by the env-gated integration test below.
#if os(macOS)

final class HelperPkgVerifierTests: XCTestCase {

    private let okURL =
        "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"

    // MARK: URL provenance allowlist

    func test_validatePkgURL_acceptsOfficialReleasePrefix() {
        XCTAssertNoThrow(try HelperPkgVerifier.validatePkgURL(okURL))
    }

    func test_validatePkgURL_rejectsHTTP() {
        XCTAssertThrowsError(try HelperPkgVerifier.validatePkgURL(
            "http://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/x.pkg"
        )) { XCTAssertEqual($0 as? HelperPkgVerifierError,
                            .urlInsecureScheme("http://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/x.pkg")) }
    }

    func test_validatePkgURL_rejectsWrongHost() {
        XCTAssertThrowsError(try HelperPkgVerifier.validatePkgURL(
            "https://evil.example.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/x.pkg"
        ))
    }

    func test_validatePkgURL_rejectsWrongRepoPath() {
        // Right host, attacker repo — the SHA in a swapped manifest would match
        // the attacker pkg, so ONLY the host+path prefix pin catches this.
        XCTAssertThrowsError(try HelperPkgVerifier.validatePkgURL(
            "https://github.com/attacker/evil-repo/releases/download/v1/x.pkg"
        ))
    }

    func test_validatePkgURL_rejectsAppDistribHost() {
        // The app-updater host is NOT the helper host — must not cross-accept.
        XCTAssertThrowsError(try HelperPkgVerifier.validatePkgURL(
            "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/app-v1.34.0/x.pkg"
        ))
    }

    func test_validatePkgURL_rejectsGarbage() {
        XCTAssertThrowsError(try HelperPkgVerifier.validatePkgURL("not a url"))
        XCTAssertThrowsError(try HelperPkgVerifier.validatePkgURL(""))
    }

    // MARK: size

    func test_validateSize_inRange() {
        XCTAssertNoThrow(try HelperPkgVerifier.validateSize(12_679_650))
        XCTAssertNoThrow(try HelperPkgVerifier.validateSize(1))
        XCTAssertNoThrow(try HelperPkgVerifier.validateSize(HelperPkgVerifier.maxArtifactBytes))
    }

    func test_validateSize_rejectsOutOfRange() {
        XCTAssertThrowsError(try HelperPkgVerifier.validateSize(0))
        XCTAssertThrowsError(try HelperPkgVerifier.validateSize(-5))
        XCTAssertThrowsError(try HelperPkgVerifier.validateSize(HelperPkgVerifier.maxArtifactBytes + 1))
    }

    func test_assertSizeMatch() {
        XCTAssertNoThrow(try HelperPkgVerifier.assertSizeMatch(expected: 12_679_650, actual: 12_679_650))
        XCTAssertThrowsError(try HelperPkgVerifier.assertSizeMatch(expected: 12_679_650, actual: 12_679_649)) {
            XCTAssertEqual($0 as? HelperPkgVerifierError, .sizeMismatch(expected: 12_679_650, actual: 12_679_649))
        }
    }

    // MARK: downgrade guard

    func test_assertNotDowngrade_allowsNewer() {
        XCTAssertNoThrow(try HelperPkgVerifier.assertNotDowngrade(installed: "1.24.0", candidate: "1.25.0"))
        XCTAssertNoThrow(try HelperPkgVerifier.assertNotDowngrade(installed: "1.24.0", candidate: "1.24.1"))
    }

    func test_assertNotDowngrade_allowsEqualReinstall() {
        // Same-version reinstall is a legitimate repair — allowed.
        XCTAssertNoThrow(try HelperPkgVerifier.assertNotDowngrade(installed: "1.24.0", candidate: "1.24.0"))
    }

    func test_assertNotDowngrade_rejectsOlder() {
        // The attack: a swapped latest.json points at an OLD, legitimately-signed
        // but vulnerable helper .pkg to roll a newer install backwards.
        XCTAssertThrowsError(try HelperPkgVerifier.assertNotDowngrade(installed: "1.24.0", candidate: "1.23.0")) {
            XCTAssertEqual($0 as? HelperPkgVerifierError, .downgradeBlocked(installed: "1.24.0", candidate: "1.23.0"))
        }
    }

    // MARK: signer team parsing (pure; no real .pkg)

    func test_parseSignerTeam_extractsTeamFromDeveloperIDInstallerLine() {
        let out = """
        Package "cli-pulse-helper-1.24.0-arm64.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Yuhe Ye (KHMK6Q3L3K)
               SHA256 Fingerprint: ...
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
        XCTAssertEqual(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out), "KHMK6Q3L3K")
    }

    func test_parseSignerTeam_ignoresTeamIDNotOnInstallerLine() {
        // A team id that appears somewhere OTHER than a Developer ID Installer
        // signer line must not satisfy the pin (an attacker echoing our team id
        // in the package name / a different cert type).
        let out = """
        Package "KHMK6Q3L3K-lookalike (KHMK6Q3L3K).pkg":
           Status: signed by an unknown authority
           Certificate Chain:
            1. Some Other Certificate: Evil (ZZZZZZZZZZ)
        """
        XCTAssertNil(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out))
    }

    func test_parseSignerTeam_nilWhenUnsigned() {
        let out = """
        Package "x.pkg":
           Status: no signature
        """
        XCTAssertNil(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out))
    }

    func test_parseSignerTeam_rejectsNonTeamParenthetical() {
        // A parenthetical that isn't a 10-char team id must be ignored.
        let out = "1. Developer ID Installer: Yuhe Ye (Apple Distribution)"
        XCTAssertNil(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out))
    }

    func test_parseSignerTeam_matchesPinnedTeam() {
        // End-to-end of the pure part of the pin: the parsed team equals the
        // pinned constant for a genuine signer dump.
        let out = "   1. Developer ID Installer: Yuhe Ye (\(HelperPkgVerifier.teamID))"
        XCTAssertEqual(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out),
                       HelperPkgVerifier.teamID)
    }

    // MARK: real-.pkg integration (DEVID + env-gated; the no-false-reject gate)

    #if DEVID_BUILD
    /// Run with `CLIPULSE_TEST_PKG=/path/to/cli-pulse-helper-*.pkg swift test
    /// -Xswiftc -DDEVID_BUILD` against a GENUINE signed+notarized helper .pkg to
    /// prove the verifier does NOT false-reject a legitimate package. Skipped
    /// otherwise.
    func test_realPkg_passes_whenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["CLIPULSE_TEST_PKG"] else {
            throw XCTSkip("set CLIPULSE_TEST_PKG to a genuine notarized helper .pkg to run this")
        }
        XCTAssertNoThrow(
            try HelperPkgVerifier.verifyPkgSignatureAndNotarization(URL(fileURLWithPath: path)),
            "a legitimate notarized helper .pkg must pass signature+notarization verification")
    }
    #endif
}
#endif
