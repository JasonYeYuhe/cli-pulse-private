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

    // MARK: URL provenance allowlist (exact canonical artifact for version+arch)

    private func check(_ url: String, _ v: String = "1.24.0", _ a: String = "arm64") throws {
        try HelperPkgVerifier.validatePkgURL(url, version: v, arch: a)
    }

    func test_validatePkgURL_acceptsExactOfficialArtifact() {
        XCTAssertNoThrow(try check(okURL))
    }

    func test_validatePkgURL_rejectsHTTP() {
        XCTAssertThrowsError(try check(
            "http://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"
        )) { XCTAssertEqual($0 as? HelperPkgVerifierError, .urlInsecureScheme(
            "http://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg")) }
    }

    func test_validatePkgURL_rejectsWrongHost() {
        XCTAssertThrowsError(try check(
            "https://evil.example.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"
        ))
    }

    func test_validatePkgURL_rejectsWrongRepoPath() {
        XCTAssertThrowsError(try check(
            "https://github.com/attacker/evil-repo/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"
        ))
    }

    func test_validatePkgURL_rejectsAppDistribHost() {
        XCTAssertThrowsError(try check(
            "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"
        ))
    }

    func test_validatePkgURL_rejectsDotSegmentTraversal() {
        // deep-audit 2026-07-04 (P1): raw hasPrefix passed this — it has the
        // allowed prefix but normalizes to github.com/apple/swift.
        XCTAssertThrowsError(try check(
            "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/../../../../apple/swift/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"
        ))
        // encoded dot-segments too
        XCTAssertThrowsError(try check(
            "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/%2e%2e/%2e%2e/apple/swift/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"
        ))
    }

    func test_validatePkgURL_rejectsUserinfoAndPort() {
        XCTAssertThrowsError(try check(
            "https://evil@github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"))
        XCTAssertThrowsError(try check(
            "https://github.com:8443/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/cli-pulse-helper-1.24.0-arm64.pkg"))
    }

    func test_validatePkgURL_bindsVersionToArtifact() {
        // The core Finding-1 fix: a manifest claiming version 999.0 but pointing
        // at the real OLD v1.20.0 artifact is rejected (url != expected v999.0).
        XCTAssertThrowsError(try check(
            "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.20.0/cli-pulse-helper-1.20.0-arm64.pkg",
            "999.0", "arm64"))
        // Right version, wrong arch in the URL is also rejected.
        XCTAssertThrowsError(try check(okURL, "1.24.0", "x86_64"))
        // Filename that doesn't match the canonical shape (tag ok, asset spoofed).
        XCTAssertThrowsError(try check(
            "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.24.0/evil.pkg"))
    }

    func test_validatePkgURL_rejectsGarbage() {
        XCTAssertThrowsError(try check("not a url"))
        XCTAssertThrowsError(try check(""))
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

    // MARK: version format (kills the pkgutil filename-smuggle + 999.0-downgrade)

    func test_validateVersion_acceptsNumericDotted() {
        XCTAssertNoThrow(try HelperPkgVerifier.validateVersion("1.24.0"))
        XCTAssertNoThrow(try HelperPkgVerifier.validateVersion("1.24"))
        XCTAssertNoThrow(try HelperPkgVerifier.validateVersion("12"))
        XCTAssertNoThrow(try HelperPkgVerifier.validateVersion("1.2.3.4"))
    }

    func test_validateVersion_rejectsSmuggleAndJunk() {
        // The attack payload that defeated the team-pin via the pkgutil
        // `Package "<basename>":` line — must be rejected at the source.
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion("Developer ID Installer (KHMK6Q3L3K)"))
        // The downgrade-guard-defeating variant (compareVersions parses the 999).
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion("999.0 Developer ID Installer (KHMK6Q3L3K)"))
        // Newline injection (would forge a fake numbered signer line).
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion("1.0\n    1. Developer ID Installer: x (KHMK6Q3L3K)"))
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion(""))
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion("1.24.0-arm64"))
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion("1.a"))
        XCTAssertThrowsError(try HelperPkgVerifier.validateVersion("v1.24.0"))
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

    func test_parseSignerTeam_ignoresPinnedTeamSmuggledInPackageNameLine() {
        // deep-audit 2026-07-04 (HIGH): the attacker sets manifest.version so the
        // downloaded filename embeds our pinned team + the "Developer ID Installer"
        // marker. pkgutil echoes that filename on its first `Package "..."` line.
        // parseSignerTeam MUST NOT read the team off that line — it must return
        // the REAL signer team (a different, attacker-owned team), so the caller's
        // `team == teamID` pin correctly FAILS.
        let out = """
        Package "cli-pulse-helper-Developer ID Installer (KHMK6Q3L3K)-arm64.pkg":
           Status: signed by a developer certificate issued by Apple for distribution
           Notarization: trusted by the Apple notary service
           Certificate Chain:
            1. Developer ID Installer: Evil Corp (AAAAAAAAAA)
            2. Developer ID Certification Authority
            3. Apple Root CA
        """
        XCTAssertEqual(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out), "AAAAAAAAAA",
                       "must read the REAL signer team, not the one smuggled via the filename line")
        XCTAssertNotEqual(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out), HelperPkgVerifier.teamID)
    }

    func test_parseSignerTeam_takesTeamFromEndNotHolderNameParens() {
        // A cert holder whose name contains a parenthetical must not shadow the
        // real team id at the end of the line.
        let out = "    1. Developer ID Installer: Some Org (Overseas) (KHMK6Q3L3K)"
        XCTAssertEqual(HelperPkgVerifier.parseSignerTeam(fromCheckSignatureOutput: out), "KHMK6Q3L3K")
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
