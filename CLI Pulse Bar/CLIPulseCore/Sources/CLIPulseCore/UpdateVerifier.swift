// Trust Hardening v2 (2026-06-30) — artifact authenticity + downgrade protection
// for the Developer ID self-updater. See DEV_PLAN_2026-06-30_trust_hardening_v2.md
// and PROJECT_FIX_2026-06-30_updater_artifact_authenticity.md.
//
// Threat model: a compromised/MITM'd `latest.json` (the manifest is unsigned). The
// pre-v2 updater only checked the DMG SHA-256 against the manifest — but an attacker
// who controls the manifest controls both the url AND the sha256, so that proved
// download integrity, not authenticity. This verifier adds AUTHENTICITY + DOWNGRADE
// protection so the updater refuses to present anything that isn't a genuine, current,
// Jason-notarized CLI Pulse build.
//
// Layered defense (every check fails CLOSED — any error, including missing tooling,
// is a verification failure, never a pass):
//   1. Manifest hardening: https + GitHub host/path allowlist + sane size.
//   2. Verify the DMG *container* BEFORE mounting (mounting an attacker-controlled DMG
//      parses the filesystem in-kernel — a pre-auth panic/privesc surface).
//   3. Mount read-only/no-browse, verify the inner .app: Developer ID + Team + bundle-id
//      pinned (SecStaticCode), notarized-for-execution (spctl), exactly one .app, no
//      symlink masquerade.
//   4. Downgrade protection: the mounted app's Info.plist version/build must EQUAL the
//      manifest and be strictly newer than what's installed.
//
// Notarization decider note: `spctl --assess` (always present in macOS) is what proves
// notarization here — it validates the stapled ticket offline (our DMGs are stapled, so
// no flaky online OCSP). `kSecCSCheckGatekeeperArchitectures` only widens SecStaticCode
// to all architectures; it does NOT prove notarization. We deliberately do NOT use
// `stapler` on the client (it ships with Xcode CLT and is absent on end-user Macs) and
// do NOT set `kSecCSEnforceRevocationChecks` (online revocation bricks users behind
// firewalls).
#if os(macOS) && DEVID_BUILD
import Foundation
import Security
import os

private let verifierLog = Logger(subsystem: "com.cli-pulse.bar", category: "update-verifier")

public enum UpdateVerifierError: Error, LocalizedError, Equatable {
    case manifestInsecureScheme(String)
    case manifestURLNotAllowed(String)
    case manifestSizeOutOfRange(Int)
    case sizeMismatch(expected: Int, actual: Int)
    case dmgSignatureRejected(String)
    case dmgNotarizationRejected(String)
    case mountFailed(String)
    case noAppOnVolume
    case multipleAppsOnVolume(Int)
    case symlinkMasquerade(String)
    case appSignatureRejected(String)
    case appNotarizationRejected(String)
    case infoPlistUnreadable
    case versionMismatch(expected: String, found: String)
    case buildMismatch(expected: String, found: String)
    case notAnUpgrade(installed: String, candidate: String)
    case toolingUnavailable(String)

    public var errorDescription: String? {
        let detail: String
        switch self {
        case .manifestInsecureScheme(let s): detail = "update URL is not https (\(s))"
        case .manifestURLNotAllowed(let s): detail = "update URL is not an official release (\(s))"
        case .manifestSizeOutOfRange(let n): detail = "declared size out of range (\(n))"
        case .sizeMismatch(let e, let a): detail = "size mismatch (expected \(e), got \(a))"
        case .dmgSignatureRejected(let s): detail = "disk image is not signed by CLI Pulse (\(s))"
        case .dmgNotarizationRejected(let s): detail = "disk image is not notarized (\(s))"
        case .mountFailed(let s): detail = "could not mount the disk image (\(s))"
        case .noAppOnVolume: detail = "no app found in the disk image"
        case .multipleAppsOnVolume(let n): detail = "unexpected disk image layout (\(n) apps)"
        case .symlinkMasquerade(let s): detail = "app entry is a symlink (\(s))"
        case .appSignatureRejected(let s): detail = "app is not signed by CLI Pulse (\(s))"
        case .appNotarizationRejected(let s): detail = "app is not notarized (\(s))"
        case .infoPlistUnreadable: detail = "could not read the app's Info.plist"
        case .versionMismatch(let e, let f): detail = "version mismatch (manifest \(e), app \(f))"
        case .buildMismatch(let e, let f): detail = "build mismatch (manifest \(e), app \(f))"
        case .notAnUpgrade(let i, let c): detail = "not an upgrade (installed \(i), offered \(c))"
        case .toolingUnavailable(let s): detail = "verification tool unavailable (\(s))"
        }
        return "Couldn't verify this update: \(detail)."
    }
}

/// Stateless verifier. Pure-logic entry points (`validateManifestURL`, `validateSize`,
/// `assertUpgrade`, `assertVersionMatch`) are unit-tested offline; the IO entry points
/// (`verifyDMGContainer`, `mountAndVerifyApp`, `detach`) require a real signed/notarized
/// DMG and are covered by an env-gated integration test plus the CI published-artifact
/// gate (so the highest-risk path can't silently rot).
public struct UpdateVerifier {

    // MARK: Pinned trust anchors
    public static let teamID = "KHMK6Q3L3K"
    public static let appBundleID = "yyh.CLI-Pulse"
    /// Only this exact prefix is an official release artifact.
    public static let allowedURLPrefix =
        "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/"
    public static let maxArtifactBytes = 200_000_000

    /// DMG: Developer ID Application chained to Apple + Jason's team. The DMG's own
    /// signing identifier is version-specific (`CLI-Pulse-<ver>-<arch>`) so it is NOT
    /// pinned — the team OU + Apple anchor are the trust pins; notarization is checked
    /// separately via spctl.
    static let dmgRequirement =
        #"anchor apple generic and certificate leaf[subject.OU] = "KHMK6Q3L3K""#
    /// App: Apple anchor + exact bundle id + team OU + Developer ID marker OIDs
    /// (intermediate 1.2.840.113635.100.6.2.6 + leaf 1.2.840.113635.100.6.1.13).
    static let appRequirement =
        #"anchor apple generic and identifier "yyh.CLI-Pulse" and certificate leaf[subject.OU] = "KHMK6Q3L3K" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#

    public init() {}

    // MARK: - Pure logic (no IO; unit-tested offline)

    /// Reject any manifest url that is not https or not under the official release prefix.
    public static func validateManifestURL(_ urlString: String) throws {
        guard let comps = URLComponents(string: urlString), let scheme = comps.scheme else {
            throw UpdateVerifierError.manifestURLNotAllowed(urlString)
        }
        guard scheme.lowercased() == "https" else {
            throw UpdateVerifierError.manifestInsecureScheme(urlString)
        }
        // Prefix match on the full normalized string (host + path), case-sensitive path.
        guard urlString.hasPrefix(allowedURLPrefix) else {
            throw UpdateVerifierError.manifestURLNotAllowed(urlString)
        }
    }

    /// `release_notes_url` is untrusted unless it lives under the same allowlist; callers
    /// should drop it otherwise rather than reject the whole update.
    public static func isAllowedAuxURL(_ urlString: String?) -> Bool {
        guard let s = urlString else { return false }
        return (try? validateManifestURL(s)) != nil
            || s.hasPrefix("https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/tag/")
    }

    public static func validateSize(_ size: Int) throws {
        guard size > 0 && size <= maxArtifactBytes else {
            throw UpdateVerifierError.manifestSizeOutOfRange(size)
        }
    }

    public static func assertSizeMatch(expected: Int, actual: Int) throws {
        guard expected == actual else {
            throw UpdateVerifierError.sizeMismatch(expected: expected, actual: actual)
        }
    }

    /// Strictly-newer guard (downgrade protection). Reuses AppUpdater's numeric semver
    /// compare semantics.
    public static func assertUpgrade(installed: String, candidate: String) throws {
        guard compareVersions(candidate, installed) > 0 else {
            throw UpdateVerifierError.notAnUpgrade(installed: installed, candidate: candidate)
        }
    }

    /// The mounted app's marketing version + build must EQUAL the manifest's — this is
    /// what closes the "spoofed-high manifest pointing at a legit old DMG" downgrade.
    public static func assertVersionMatch(
        appShortVersion: String?,
        appBuild: String?,
        manifestVersion: String,
        manifestBuild: String?
    ) throws {
        guard let appShort = appShortVersion else { throw UpdateVerifierError.infoPlistUnreadable }
        guard appShort == manifestVersion else {
            throw UpdateVerifierError.versionMismatch(expected: manifestVersion, found: appShort)
        }
        if let mBuild = manifestBuild {
            guard let appBuild = appBuild, appBuild == mBuild else {
                throw UpdateVerifierError.buildMismatch(expected: mBuild, found: appBuild ?? "nil")
            }
        }
    }

    /// Numeric, dot-separated comparison (mirrors AppUpdater.compareVersions). Returns
    /// -1 / 0 / 1 for a<b / a==b / a>b.
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

    // MARK: - Container verification (BEFORE mount)

    /// Verify the downloaded DMG file itself: signature pinned to Jason's Developer ID
    /// team (SecStaticCode, in-process) + notarized (spctl, offline stapled ticket).
    /// Must pass before the DMG is ever handed to `hdiutil attach`.
    public static func verifyDMGContainer(_ dmg: URL) throws {
        try checkCodeRequirement(path: dmg, requirement: dmgRequirement,
                                 onReject: { UpdateVerifierError.dmgSignatureRejected($0) })
        try gatekeeperAssess(path: dmg, type: "open", primarySignature: true,
                             onReject: { UpdateVerifierError.dmgNotarizationRejected($0) })
    }

    // MARK: - Mount + app verification

    /// Mount the (already container-verified) DMG read-only, verify the single inner
    /// `.app`, and assert its version/build match the manifest and beat the installed
    /// version. Returns the live mount so the caller can hand off the *verified* volume
    /// to Finder without a detach/reopen race. The caller owns `detach(device:)`.
    public static func mountAndVerifyApp(
        dmg: URL,
        manifestVersion: String,
        manifestBuild: String?,
        installedVersion: String
    ) throws -> (device: String, mountpoint: URL, appPath: URL) {
        let mount = try mountReadOnly(dmg)
        do {
            let appPath = try locateSingleApp(onVolume: mount.mountpoint)
            try checkCodeRequirement(
                path: appPath, requirement: appRequirement,
                extraFlags: UInt32(kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckGatekeeperArchitectures),
                onReject: { UpdateVerifierError.appSignatureRejected($0) })
            try gatekeeperAssess(path: appPath, type: "execute", primarySignature: false,
                                 onReject: { UpdateVerifierError.appNotarizationRejected($0) })
            let info = try readInfoPlist(appPath: appPath)
            try assertVersionMatch(
                appShortVersion: info.shortVersion, appBuild: info.build,
                manifestVersion: manifestVersion, manifestBuild: manifestBuild)
            try assertUpgrade(installed: installedVersion, candidate: manifestVersion)
            return (mount.device, mount.mountpoint, appPath)
        } catch {
            detach(device: mount.device)
            throw error
        }
    }

    public static func detach(device: String) {
        _ = try? runTool("/usr/bin/hdiutil", ["detach", device, "-quiet"])
    }

    // MARK: - SecStaticCode requirement check (in-process)

    static func checkCodeRequirement(
        path: URL,
        requirement: String,
        extraFlags: UInt32 = 0,
        onReject: (String) -> UpdateVerifierError
    ) throws {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(path as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else {
            throw onReject("SecStaticCodeCreateWithPath \(createStatus)")
        }
        var requirementRef: SecRequirement?
        let reqStatus = SecRequirementCreateWithString(requirement as CFString, [], &requirementRef)
        guard reqStatus == errSecSuccess, let req = requirementRef else {
            throw UpdateVerifierError.toolingUnavailable("SecRequirementCreateWithString \(reqStatus)")
        }
        let flags = SecCSFlags(rawValue: extraFlags)
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, req, &cfError)
        if status != errSecSuccess {
            let msg = (cfError?.takeRetainedValue()).map { String(describing: CFErrorCopyDescription($0)) }
                ?? "OSStatus \(status)"
            throw onReject(msg)
        }
    }

    // MARK: - Gatekeeper assessment (spctl; notarization decider)

    static func gatekeeperAssess(
        path: URL,
        type: String,
        primarySignature: Bool,
        onReject: (String) -> UpdateVerifierError
    ) throws {
        var args = ["--assess", "--type", type, "--ignore-cache"]
        if primarySignature { args += ["--context", "context:primary-signature"] }
        args.append(path.path)
        let result: (status: Int32, out: String)
        do {
            result = try runTool("/usr/sbin/spctl", args)
        } catch {
            throw UpdateVerifierError.toolingUnavailable("spctl: \(error.localizedDescription)")
        }
        guard result.status == 0 else {
            throw onReject("spctl rejected (\(result.status)) \(result.out.prefix(200))")
        }
    }

    // MARK: - hdiutil mount

    static func mountReadOnly(_ dmg: URL) throws -> (device: String, mountpoint: URL) {
        let result: (status: Int32, out: String)
        do {
            result = try runToolData("/usr/bin/hdiutil",
                ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountrandom", "/tmp", "-plist", dmg.path])
        } catch {
            throw UpdateVerifierError.mountFailed("hdiutil unavailable: \(error.localizedDescription)")
        }
        guard result.status == 0, let data = result.out.data(using: .utf8) else {
            throw UpdateVerifierError.mountFailed("hdiutil exit \(result.status)")
        }
        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
            let entities = plist["system-entities"] as? [[String: Any]]
        else { throw UpdateVerifierError.mountFailed("unparseable hdiutil plist") }

        var mountpoint: String?
        var topDevice: String?
        for e in entities {
            if let dev = e["dev-entry"] as? String {
                // The top-level device (e.g. /dev/disk5, no slice suffix) is what we detach.
                if topDevice == nil || dev.count < (topDevice?.count ?? .max) { topDevice = dev }
            }
            if let mp = e["mount-point"] as? String, !mp.isEmpty { mountpoint = mp }
        }
        guard let mp = mountpoint, let dev = topDevice else {
            // Best-effort detach anything we did attach, then fail.
            if let dev = topDevice { detach(device: dev) }
            throw UpdateVerifierError.mountFailed("no mount-point in hdiutil output")
        }
        return (dev, URL(fileURLWithPath: mp, isDirectory: true))
    }

    // MARK: - App location (exactly one, no symlink)

    static func locateSingleApp(onVolume volume: URL) throws -> URL {
        let fm = FileManager.default
        let entries: [String]
        do {
            entries = try fm.contentsOfDirectory(atPath: volume.path)
        } catch {
            throw UpdateVerifierError.noAppOnVolume
        }
        let apps = entries.filter { $0.hasSuffix(".app") }
        guard !apps.isEmpty else { throw UpdateVerifierError.noAppOnVolume }
        guard apps.count == 1 else { throw UpdateVerifierError.multipleAppsOnVolume(apps.count) }
        let appPath = volume.appendingPathComponent(apps[0])
        // Reject a symlink masquerading as the .app bundle (lstat: don't follow).
        let attrs = try? fm.attributesOfItem(atPath: appPath.path)
        if let type = attrs?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw UpdateVerifierError.symlinkMasquerade(apps[0])
        }
        return appPath
    }

    // MARK: - Info.plist

    static func readInfoPlist(appPath: URL) throws -> (shortVersion: String?, build: String?) {
        let plistURL = appPath.appendingPathComponent("Contents/Info.plist")
        guard
            let data = try? Data(contentsOf: plistURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { throw UpdateVerifierError.infoPlistUnreadable }
        return (dict["CFBundleShortVersionString"] as? String, dict["CFBundleVersion"] as? String)
    }

    // MARK: - Process helpers (fail closed: a launch error is a verification failure)

    @discardableResult
    static func runTool(_ launchPath: String, _ args: [String]) throws -> (status: Int32, out: String) {
        try runToolData(launchPath, args)
    }

    static func runToolData(_ launchPath: String, _ args: [String]) throws -> (status: Int32, out: String) {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            throw UpdateVerifierError.toolingUnavailable(launchPath)
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
}
#endif
