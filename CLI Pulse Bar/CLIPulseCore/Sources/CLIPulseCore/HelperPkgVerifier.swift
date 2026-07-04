// F8 (deep-audit 2026-07-04) — helper .pkg installer authenticity + downgrade
// protection, bringing HelperInstaller to parity with the DEVID app's
// UpdateVerifier (see UpdateVerifier.swift + PROJECT_FIX_2026-06-30_updater_
// artifact_authenticity.md).
//
// Threat model: the helper manifest (`latest.json` on the public
// cli-pulse-helper-releases repo) is UNSIGNED. An attacker who controls the
// manifest controls both the `url` AND the `sha256`, so the pre-F8 installer's
// SHA-256 check proved download INTEGRITY, not AUTHENTICITY — a swapped manifest
// pointing at an attacker .pkg (with a matching attacker SHA) would install
// silently. This verifier adds:
//
//   1. URL provenance — the .pkg `url` must be https + under the official
//      cli-pulse-helper-releases release-download prefix (pure; all builds).
//   2. Size sanity + exact match vs the manifest (pure; all builds).
//   3. Downgrade guard — refuse a manifest that points BACKWARDS from the
//      running helper (an attacker serving an old, legitimately-signed but
//      vulnerable .pkg). Pure; all builds.
//   4. Developer ID Installer team-pin + notarization on the downloaded .pkg
//      (spctl install-assessment + pkgutil --check-signature team match).
//      DEVID_BUILD only — the MAS build is sandboxed and cannot exec spctl/
//      pkgutil; there, Installer.app's own Gatekeeper install-assessment is the
//      backstop and 1–3 above still apply. See the parity note in the Codex
//      review prompt.
//
// Every check fails CLOSED — any error (including missing tooling) is a
// verification failure, never a pass.
#if os(macOS)
import Foundation
import os

private let helperPkgVerifierLog = Logger(
    subsystem: "com.cli-pulse.bar", category: "helper-pkg-verifier"
)

public enum HelperPkgVerifierError: Error, LocalizedError, Equatable {
    case urlInsecureScheme(String)
    case urlNotAllowed(String)
    case sizeOutOfRange(Int)
    case sizeMismatch(expected: Int, actual: Int)
    case downgradeBlocked(installed: String, candidate: String)
    case signatureRejected(String)
    case notarizationRejected(String)
    case teamMismatch(found: String)
    case toolingUnavailable(String)

    public var errorDescription: String? {
        let detail: String
        switch self {
        case .urlInsecureScheme(let s): detail = "download URL is not https (\(s))"
        case .urlNotAllowed(let s): detail = "download URL is not an official helper release (\(s))"
        case .sizeOutOfRange(let n): detail = "declared size out of range (\(n))"
        case .sizeMismatch(let e, let a): detail = "size mismatch (expected \(e), got \(a))"
        case .downgradeBlocked(let i, let c): detail = "refusing a downgrade (installed \(i), offered \(c))"
        case .signatureRejected(let s): detail = "package is not signed by CLI Pulse (\(s))"
        case .notarizationRejected(let s): detail = "package is not notarized (\(s))"
        case .teamMismatch(let f): detail = "package signed by an unexpected team (\(f))"
        case .toolingUnavailable(let s): detail = "verification tool unavailable (\(s))"
        }
        return "Couldn't verify the Companion CLI package: \(detail)."
    }
}

/// Stateless verifier. The pure entry points (`validatePkgURL`, `validateSize`,
/// `assertSizeMatch`, `assertNotDowngrade`, `parseSignerTeam`) are unit-tested
/// offline in the default `swift test`; the subprocess IO path
/// (`verifyPkgSignatureAndNotarization`) is DEVID-only and covered by an
/// env-gated integration test plus the published-artifact CI gate.
public struct HelperPkgVerifier {

    // MARK: Pinned trust anchors
    /// Jason's Developer ID team. Same anchor the app updater pins
    /// (UpdateVerifier.teamID) — the helper .pkg is signed with the matching
    /// Developer ID *Installer* certificate of the same team.
    public static let teamID = "KHMK6Q3L3K"
    /// Only this exact prefix is an official helper-release artifact.
    public static let allowedURLPrefix =
        "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/"
    /// Helper .pkg is ~13 MB today; a generous ceiling that still rejects an
    /// absurd attacker-declared size.
    public static let maxArtifactBytes = 200_000_000

    public init() {}

    // MARK: - Pure logic (no IO; unit-tested offline in default `swift test`)

    /// Reject any .pkg url that is not https or not under the official
    /// helper-release prefix. The manifest is unsigned, so this is what turns
    /// the existing SHA-256 check from "integrity" into "authenticity".
    public static func validatePkgURL(_ urlString: String) throws {
        guard let comps = URLComponents(string: urlString), let scheme = comps.scheme else {
            throw HelperPkgVerifierError.urlNotAllowed(urlString)
        }
        guard scheme.lowercased() == "https" else {
            throw HelperPkgVerifierError.urlInsecureScheme(urlString)
        }
        guard urlString.hasPrefix(allowedURLPrefix) else {
            throw HelperPkgVerifierError.urlNotAllowed(urlString)
        }
    }

    public static func validateSize(_ size: Int) throws {
        guard size > 0 && size <= maxArtifactBytes else {
            throw HelperPkgVerifierError.sizeOutOfRange(size)
        }
    }

    public static func assertSizeMatch(expected: Int, actual: Int) throws {
        guard expected == actual else {
            throw HelperPkgVerifierError.sizeMismatch(expected: expected, actual: actual)
        }
    }

    /// Downgrade guard. `candidate` (the manifest version being installed) must
    /// be >= the currently-installed helper version. Equal is allowed (a repair
    /// reinstall); strictly-lower is refused (an attacker-controlled manifest
    /// pushing an old, vulnerable helper onto a newer install).
    public static func assertNotDowngrade(installed: String, candidate: String) throws {
        guard compareVersions(candidate, installed) >= 0 else {
            throw HelperPkgVerifierError.downgradeBlocked(installed: installed, candidate: candidate)
        }
    }

    /// Numeric, dot-separated compare (mirrors HelperInstaller/UpdateVerifier).
    /// Returns -1 / 0 / 1 for a<b / a==b / a>b.
    public static func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return -1 }
            if av > bv { return 1 }
        }
        return 0
    }

    /// Extract the 10-char Apple Team ID from a `pkgutil --check-signature`
    /// dump. The signer line looks like:
    ///   `1. Developer ID Installer: Jason … (KHMK6Q3L3K)`
    /// We require BOTH the "Developer ID Installer" marker and a team id in
    /// parens; returns the first team id found on a Developer-ID-Installer line,
    /// or nil if the output carries no such signer. Pure so it's unit-tested
    /// without a real .pkg.
    public static func parseSignerTeam(fromCheckSignatureOutput output: String) -> String? {
        // Only trust a team id that sits on a "Developer ID Installer" line —
        // an attacker's ad-hoc/other-cert chain must not satisfy the pin.
        for rawLine in output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = String(rawLine)
            guard line.contains("Developer ID Installer") else { continue }
            if let team = firstTeamID(in: line) { return team }
        }
        return nil
    }

    /// First `(XXXXXXXXXX)` 10-char uppercase-alphanumeric Team ID in a string.
    static func firstTeamID(in line: String) -> String? {
        guard let open = line.range(of: "(") else { return nil }
        let after = line[open.upperBound...]
        guard let close = after.range(of: ")") else { return nil }
        let candidate = String(after[..<close.lowerBound])
        let isTeam = candidate.count == 10 &&
            candidate.allSatisfy { ($0.isLetter && $0.isUppercase) || $0.isNumber }
        return isTeam ? candidate : nil
    }

    // MARK: - Signature + notarization (DEVID build only; subprocess)

    #if DEVID_BUILD
    /// Verify the downloaded .pkg is notarized AND signed by our Developer ID
    /// Installer team. Two layers, both fail-closed:
    ///   1. `spctl --assess --type install` — Gatekeeper install assessment
    ///      (validates a Developer ID Installer signature + the stapled
    ///      notarization ticket, offline).
    ///   2. `pkgutil --check-signature` — parse the signer chain and pin the
    ///      team id to `teamID` (spctl proves "notarized Developer ID", pkgutil
    ///      proves it's OUR team specifically).
    public static func verifyPkgSignatureAndNotarization(_ pkg: URL) throws {
        // (1) Gatekeeper install assessment.
        let assess: (status: Int32, out: String)
        do {
            assess = try runTool("/usr/sbin/spctl",
                                 ["--assess", "--type", "install", "--ignore-cache", pkg.path])
        } catch {
            throw HelperPkgVerifierError.toolingUnavailable("spctl: \(error.localizedDescription)")
        }
        guard assess.status == 0 else {
            throw HelperPkgVerifierError.notarizationRejected(
                "spctl rejected (\(assess.status)) \(assess.out.prefix(200))")
        }
        // (2) Signer team pin.
        let sig: (status: Int32, out: String)
        do {
            sig = try runTool("/usr/sbin/pkgutil", ["--check-signature", pkg.path])
        } catch {
            throw HelperPkgVerifierError.toolingUnavailable("pkgutil: \(error.localizedDescription)")
        }
        guard sig.status == 0 else {
            throw HelperPkgVerifierError.signatureRejected(
                "pkgutil exit \(sig.status) \(sig.out.prefix(200))")
        }
        guard let team = parseSignerTeam(fromCheckSignatureOutput: sig.out) else {
            throw HelperPkgVerifierError.signatureRejected("no Developer ID Installer signer")
        }
        guard team == teamID else {
            throw HelperPkgVerifierError.teamMismatch(found: team)
        }
    }

    // MARK: - Process helper (fail closed: a launch error is a verification failure)

    static func runTool(_ launchPath: String, _ args: [String]) throws -> (status: Int32, out: String) {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            throw HelperPkgVerifierError.toolingUnavailable(launchPath)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
    #endif
}
#endif
