// v1.21 D5: gate AppUpdater on `#if DEVID_BUILD` in addition to os(macOS).
// MAS builds never construct AppUpdater (consumers in AppState/SettingsTab
// already wrap their access in `#if DEVID_BUILD`), so the class was dead code
// in MAS binaries. AppUpdaterTests is similarly gated below.
#if os(macOS) && DEVID_BUILD
import Foundation
import os
import AppKit

private let appUpdaterLog = Logger(
    subsystem: "com.cli-pulse.bar", category: "app-updater"
)

/// v1.19 — drives the "Check for Updates / Install Update" UX in the
/// Developer ID DMG channel's macOS app. Mirrors the structure of
/// `HelperInstaller` (manifest fetch → SHA-256 verify → URLSession
/// download), but the install handoff differs: instead of opening a
/// .pkg via Installer.app, we open a .dmg in Finder and quit ourselves
/// so the user can drag-replace the .app in /Applications.
///
/// State machine:
/// ```
///   .checking
///       │
///       ▼
///   .upToDate(version:) ────── user clicks "Check for Updates" ──┐
///                                                                 │
///   .updateAvailable(installed:, latest:) ◀──────────────────────┘
///       │
///       │ user clicks "Download Update"
///       ▼
///   .downloading(progress:)  — download + SHA + ARTIFACT VERIFICATION
///       │                       (container sig/notarization before mount, then inner
///       │                        .app sig/notarization + version/build + downgrade
///       ▼                        guard; see UpdateVerifier)
///   .readyToInstall(dmgURL:)  — DMG is mounted + fully verified, mount held
///       │
///       │ user clicks "Install Update"
///       ▼
///   reveal the VERIFIED mounted volume in Finder; NSApp.terminate(nil) ~500ms later
///   (user drags new .app over old in /Applications; relaunches manually)
/// ```
///
/// Trust Hardening v2 (2026-06-30): `download()` no longer trusts the manifest's
/// url/sha alone (a manifest attacker controls both). It verifies the artifact is a
/// genuine, current, Jason-notarized CLI Pulse build before `.readyToInstall`, and
/// `install()` hands off the already-verified mounted volume (no detach/reopen TOCTOU).
///
/// Gemini G2 mitigation: macOS Finder hard-blocks "drag .app to /Applications"
/// when the target is running. The "Install Update" action must
/// terminate self before the drag-replace can complete.
///
/// Gemini G7 mitigation: URLSession default cache policy can mask
/// newly-published manifests. All manifest fetches use
/// `.reloadIgnoringLocalCacheData`.
///
/// Gemini G3 caveat: the .dmg is downloaded to `NSTemporaryDirectory()`
/// which under sandbox redirects to the container's tmp dir
/// (`~/Library/Containers/.../Data/tmp/`). Mirroring HelperInstaller's
/// proven pattern — Finder/diskarbitrationd can mount via
/// `NSWorkspace.open(...)` from there (LaunchServices traverses
/// sandbox boundaries). If clean-Mac smoke shows Finder refuses,
/// v1.19.x will route through `~/Downloads/` instead.
///
/// This class is compiled into CLIPulseCore unconditionally so the API
/// surface stays uniform across MAS / DEVID, but consumers should gate
/// with `#if DEVID_BUILD` — MAS builds should never construct an
/// AppUpdater because the manifest URL points to a public repo that
/// MAS users won't see in any UI.
public final class AppUpdater: ObservableObject, @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case checking
        case upToDate(version: String)
        case updateAvailable(installed: String, latest: String)
        case downloading(progress: Double)
        case readyToInstall(dmgURL: URL)
        case error(String)
    }

    /// Manifest fragment served at the public mirror repo:
    /// `https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/latest/latest.json`.
    /// Mirrors HelperInstaller.Manifest but adds `build` + `channel`
    /// fields so future server-side channel routing can read them.
    public struct Manifest: Sendable, Codable, Equatable {
        public let version: String
        public let build: String?
        public let channel: String?
        public let arch: String
        public let url: String
        public let sha256: String
        public let sizeBytes: Int
        public let minOsVersion: String
        public let releaseNotesUrl: String?

        enum CodingKeys: String, CodingKey {
            case version, build, channel, arch, url, sha256
            case sizeBytes = "size_bytes"
            case minOsVersion = "min_os_version"
            case releaseNotesUrl = "release_notes_url"
        }
    }

    @Published public private(set) var state: State = .checking
    @Published public private(set) var lastChecked: Date?

    private let manifestURL: URL
    private let urlSession: URLSession
    /// Manifest captured by the most recent `refresh()`. `download()`
    /// reuses this to avoid a TOCTOU race where a new release could
    /// publish between the user seeing "v1.19.1 available" and
    /// clicking "Download Update", leaving the version label out of
    /// sync with the downloaded artifact. Cleared on error.
    private var cachedManifest: Manifest?

    /// The live, already-verified DMG mount produced by `download()`. `install()` hands
    /// THIS volume to Finder (no detach/reopen) so there's no TOCTOU window between
    /// verification and the user's drag-install. Owned on the main actor; detached on the
    /// next download or on error.
    private var verifiedMount: (device: String, mountpoint: URL, appPath: URL)?

    public static let defaultManifestURL = URL(string:
        "https://github.com/JasonYeYuhe/cli-pulse-distrib/releases/download/latest/latest.json"
    )!

    public init(
        manifestURL: URL = defaultManifestURL,
        urlSession: URLSession = .shared
    ) {
        self.manifestURL = manifestURL
        self.urlSession = urlSession
    }

    // MARK: - Public API

    /// Refresh by fetching the latest manifest and comparing to the
    /// installed version. Called on app launch, once per 24h while
    /// running, and on user-clicked "Check for Updates".
    @MainActor
    public func refresh() async {
        state = .checking
        let installed = Self.installedVersion()
        let manifest: Manifest?
        do {
            manifest = try await fetchManifest()
        } catch {
            appUpdaterLog.warning("manifest fetch failed: \(error.localizedDescription, privacy: .public)")
            state = .error("Couldn't reach updates server: \(error.localizedDescription)")
            lastChecked = Date()
            return
        }
        lastChecked = Date()

        guard let m = manifest else {
            state = .error("Empty manifest")
            return
        }

        do {
            try Self.assertArchitectureMatches(m)
        } catch {
            cachedManifest = nil
            state = .error(error.localizedDescription)
            return
        }

        // Cache so `download()` can use the same manifest the user saw
        // in the "update available" prompt.
        cachedManifest = m

        if Self.compareVersions(installed, m.version) < 0 {
            state = .updateAvailable(installed: installed, latest: m.version)
        } else {
            state = .upToDate(version: installed)
        }
    }

    /// Download the update .dmg. Reuses the manifest captured by the
    /// most recent `refresh()` so the downloaded artifact matches the
    /// version the user saw in the UI (avoids a TOCTOU where a new
    /// release publishes mid-click). Falls back to a fresh fetch only
    /// if no cached manifest exists (e.g., direct `download()` call
    /// without a prior `refresh()`).
    @MainActor
    public func download() async {
        // Detach any volume left mounted by a prior download/verify pass.
        detachVerifiedMount()
        state = .downloading(progress: 0)
        do {
            let manifest: Manifest
            if let cached = cachedManifest {
                manifest = cached
            } else {
                manifest = try await fetchManifest()
            }
            try Self.assertArchitectureMatches(manifest)
            let verified = try await downloadAndVerify(manifest: manifest)
            verifiedMount = verified.mount
            state = .readyToInstall(dmgURL: verified.dmgURL)
        } catch {
            appUpdaterLog.error("download failed: \(error.localizedDescription, privacy: .public)")
            cachedManifest = nil
            detachVerifiedMount()
            state = .error(error.localizedDescription)
        }
    }

    /// Open the downloaded .dmg in Finder + quit self so the user can
    /// drag-replace the .app in /Applications. The 500ms delay lets
    /// Finder focus the DMG window before the menubar app vanishes.
    @MainActor
    public func install() {
        guard case .readyToInstall = state, let mount = verifiedMount else {
            appUpdaterLog.warning("install() called without a verified mount: \(String(describing: self.state))")
            // Fail safe: never present an unverified artifact for install.
            state = .error("Update not verified — please re-download.")
            return
        }
        appUpdaterLog.info("revealing verified update volume and quitting for user drag-replace")
        // Reveal the ALREADY-VERIFIED, still-mounted volume in Finder. We do NOT
        // re-open the .dmg file (that detach→reopen would reintroduce a TOCTOU window
        // the artifact verification just closed — Apple's SecStaticCode docs warn the
        // verdict is only valid while the code is not concurrently modified). The user
        // drags "CLI Pulse.app" from the verified volume over the old one in
        // /Applications; Finder handles the "Replace?" confirmation. After replace +
        // relaunch, the new version's AppUpdater resolves to `.upToDate`.
        //
        // Off the main thread: selectFile does a blocking LaunchServices XPC round-trip
        // (same main-thread-hang class as the helper-install path). The verified volume
        // stays mounted so the drag can complete after we quit.
        let appPath = mount.appPath.path
        let volumePath = mount.mountpoint.path
        Task.detached { NSWorkspace.shared.selectFile(appPath, inFileViewerRootedAtPath: volumePath) }
        // Give Finder ~500ms to focus the volume window before we quit ourselves.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    /// Detach the verified volume (if any) and forget it. Best-effort; the volume is
    /// read-only so a leaked mount is harmless, but we tidy up on each new download.
    @MainActor
    private func detachVerifiedMount() {
        if let mount = verifiedMount {
            UpdateVerifier.detach(device: mount.device)
            verifiedMount = nil
        }
    }

    // MARK: - Internals

    /// Fetch the manifest with explicit cache-policy override.
    /// Gemini G7: default URLSession cache can hide newly-published
    /// manifests for hours. Force a network round-trip every time.
    private func fetchManifest() async throws -> Manifest {
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "AppUpdater",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Manifest fetch HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"]
            )
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        // Trust Hardening v2: manifest hardening — reject any update URL that is not
        // https under the official cli-pulse-distrib release prefix, and any insane size.
        // This runs on every refresh() so a tampered/redirected manifest is rejected
        // before the user is ever offered the "update available" prompt.
        try UpdateVerifier.validateManifestURL(manifest.url)
        try UpdateVerifier.validateSize(manifest.sizeBytes)
        return manifest
    }

    /// Download the DMG to a fresh private directory, then prove it is a genuine,
    /// current, Jason-notarized CLI Pulse build BEFORE presenting it for install:
    /// size + SHA-256 (integrity) → DMG-container signature/notarization (authenticity,
    /// verified before mounting) → mount read-only + inner-app signature/notarization +
    /// version/build match + strictly-newer (downgrade protection). Returns the dmg URL
    /// and the live verified mount; the caller hands that mount to Finder.
    private func downloadAndVerify(
        manifest: Manifest
    ) async throws -> (dmgURL: URL, mount: (device: String, mountpoint: URL, appPath: URL)) {
        guard let url = URL(string: manifest.url) else {
            throw NSError(
                domain: "AppUpdater", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest URL: \(manifest.url)"]
            )
        }
        let (tempURL, response) = try await urlSession.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "AppUpdater", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "DMG download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"]
            )
        }
        // Download into a fresh, private (0700) per-update directory rather than a
        // predictable NSTemporaryDirectory() path — removes a local file-swap race.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLI-Pulse-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let finalURL = dir.appendingPathComponent("CLI-Pulse-\(manifest.version)-\(manifest.arch).dmg")
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        // Size must match the manifest exactly.
        let attrs = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        try UpdateVerifier.assertSizeMatch(expected: manifest.sizeBytes, actual: (attrs[.size] as? Int) ?? -1)

        // SHA-256 (download integrity). v1.21 D4: hashing a 50-150 MB file is CPU-bound —
        // run off the @MainActor download() path to avoid freezing the popover.
        let actualSHA = try await Task.detached {
            try CryptoHelpers.sha256Hex(of: finalURL)
        }.value
        guard actualSHA.lowercased() == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: dir)
            throw NSError(
                domain: "AppUpdater", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "DMG SHA-256 mismatch (expected \(manifest.sha256), got \(actualSHA))"]
            )
        }

        // Authenticity + downgrade protection (blocking codesign/spctl/hdiutil work →
        // off the main actor). Verifies the container BEFORE mounting, then the inner app.
        let installed = Self.installedVersion()
        let version = manifest.version
        let build = manifest.build
        do {
            let mount = try await Task.detached { () -> (device: String, mountpoint: URL, appPath: URL) in
                try UpdateVerifier.verifyDMGContainer(finalURL)
                return try UpdateVerifier.mountAndVerifyApp(
                    dmg: finalURL, manifestVersion: version,
                    manifestBuild: build, installedVersion: installed)
            }.value
            return (finalURL, mount)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            throw error
        }
    }

    // MARK: - Helpers

    static func installedVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func compareVersions(_ a: String, _ b: String) -> Int {
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

    static func assertArchitectureMatches(_ manifest: Manifest) throws {
        let host: String
        #if arch(arm64)
        host = "arm64"
        #elseif arch(x86_64)
        host = "x86_64"
        #else
        host = "unknown"
        #endif
        if manifest.arch != host {
            throw NSError(
                domain: "AppUpdater",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Manifest is for \(manifest.arch) but this Mac is \(host). Wait for \(host) build."]
            )
        }
    }

}
// v1.21 D4: removed local sha256(of:) — callers route through CryptoHelpers.
// CommonCrypto import removed; CryptoKit is the single SHA-256 path now.

#endif
