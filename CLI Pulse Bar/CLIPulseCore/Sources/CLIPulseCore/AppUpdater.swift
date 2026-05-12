#if os(macOS)
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
///   .downloading(progress:)
///       │
///       ▼
///   .readyToInstall(dmgURL:)
///       │
///       │ user clicks "Install Update"
///       ▼
///   open DMG in Finder; NSApp.terminate(nil) ~500ms later
///   (user drags new .app over old in /Applications; relaunches manually)
/// ```
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
            state = .error(error.localizedDescription)
            return
        }

        if Self.compareVersions(installed, m.version) < 0 {
            state = .updateAvailable(installed: installed, latest: m.version)
        } else {
            state = .upToDate(version: installed)
        }
    }

    /// Download the update .dmg. On success transitions to
    /// `.readyToInstall(dmgURL:)`; the user then triggers `install()`.
    @MainActor
    public func download() async {
        state = .downloading(progress: 0)
        do {
            let manifest = try await fetchManifest()
            try Self.assertArchitectureMatches(manifest)
            let dmgURL = try await downloadDmg(manifest: manifest)
            state = .readyToInstall(dmgURL: dmgURL)
        } catch {
            appUpdaterLog.error("download failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
        }
    }

    /// Open the downloaded .dmg in Finder + quit self so the user can
    /// drag-replace the .app in /Applications. The 500ms delay lets
    /// Finder focus the DMG window before the menubar app vanishes.
    @MainActor
    public func install() {
        guard case .readyToInstall(let dmgURL) = state else {
            appUpdaterLog.warning("install() called from non-ready state: \(String(describing: self.state))")
            return
        }
        appUpdaterLog.info("opening DMG and quitting for user drag-replace")
        // NSWorkspace.shared.open mounts the .dmg + shows its window in
        // Finder. The user then drags "CLI Pulse.app" over the old one
        // in /Applications. macOS Finder + Gatekeeper handle the
        // "Replace?" confirmation. After the replace + relaunch, the
        // new version's AppUpdater will resolve to `.upToDate`.
        NSWorkspace.shared.open(dmgURL)
        // Give Finder ~500ms to focus the DMG window before we quit
        // ourselves. If we terminate too eagerly the user might miss
        // where the DMG opened.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
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
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func downloadDmg(manifest: Manifest) async throws -> URL {
        guard let url = URL(string: manifest.url) else {
            throw NSError(
                domain: "AppUpdater",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest URL: \(manifest.url)"]
            )
        }
        let (tempURL, response) = try await urlSession.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "AppUpdater",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "DMG download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"]
            )
        }
        // Move to a stable temp path so NSWorkspace.open has a valid URL
        // after URLSession's temp file gets cleaned up by the system.
        let finalURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CLI-Pulse-\(manifest.version)-\(manifest.arch).dmg")
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        // Verify SHA-256 of the downloaded DMG against the manifest.
        let actualSHA = try Self.sha256(of: finalURL)
        guard actualSHA.lowercased() == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: finalURL)
            throw NSError(
                domain: "AppUpdater",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "DMG SHA-256 mismatch (expected \(manifest.sha256), got \(actualSHA))"]
            )
        }
        return finalURL
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

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            let buf = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            CC_SHA256(buf, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CommonCrypto bridge

import CommonCrypto

#endif
