#if os(macOS)
import Foundation
import Network
import os
import AppKit

private let helperInstallerLog = Logger(
    subsystem: "com.cli-pulse.bar", category: "helper-installer"
)

/// v1.16 — drives the "Install / Update / Uninstall Companion CLI" UX in
/// the macOS app's Pairing settings.
///
/// State machine:
/// ```
///   .checking
///       │
///       ▼
///   .notInstalled ─── user clicks Install ───▶ .downloading(progress:)
///                                                       │
///                                                       ▼
///                                              .installing       (Installer.app
///                                                       │        opened with
///                                                       ▼        the .pkg)
///                                          .running(version:)    (UDS probe
///                                                       │        succeeds +
///                                                       │        helper version
///                                                       │        reported)
///                                                       │
///                       user clicks Check for Updates ──┤
///                                                       ▼
///                                       .updateAvailable(installed:, latest:)
///                                                       │
///                                                       └─▶ same install flow
/// ```
///
/// Liveness check uses `Network.framework`'s `NWConnection(to: .unix(path:))`
/// (per Gemini final-review of the plan: cleaner than raw `sockaddr_un`).
/// The MAS app has the `group.yyh.CLI-Pulse` app-group entitlement so it
/// can read the UDS at `~/Library/Group Containers/.../clipulse-helper.sock`
/// even when sandboxed.
///
/// SMAppService.agent(plistName:) does NOT work for externally-installed
/// agents (it only sees plists inside the calling app's bundle). UDS probe
/// is the correct alternative.
public final class HelperInstaller: ObservableObject, @unchecked Sendable {

    public enum State: Equatable, Sendable {
        case checking
        case notInstalled
        case downloading(progress: Double)
        case installing
        case running(version: String)
        case updateAvailable(installed: String, latest: String)
        case error(String)
    }

    /// Manifest fragment the public mirror repo serves at
    /// `https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/latest/latest.json`
    public struct Manifest: Sendable, Codable, Equatable {
        public let version: String
        public let arch: String
        public let url: String
        public let sha256: String
        public let sizeBytes: Int
        public let minOsVersion: String
        public let releaseNotesUrl: String?

        enum CodingKeys: String, CodingKey {
            case version, arch, url, sha256
            case sizeBytes = "size_bytes"
            case minOsVersion = "min_os_version"
            case releaseNotesUrl = "release_notes_url"
        }
    }

    @Published public private(set) var state: State = .checking
    @Published public private(set) var lastChecked: Date?

    private let manifestURL: URL
    private let udsPath: String
    private let helperDir: String
    private let urlSession: URLSession
    private let helloClient: () -> SessionControlClient

    public static let defaultManifestURL = URL(string:
        "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/latest/latest.json"
    )!

    public init(
        manifestURL: URL = defaultManifestURL,
        urlSession: URLSession = .shared,
        helloClient: @escaping () -> SessionControlClient = { LocalSessionControlClient() }
    ) {
        self.manifestURL = manifestURL
        self.urlSession = urlSession
        self.helloClient = helloClient
        let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: LocalSessionControlClient.appGroupID
        )
        let base = groupURL?.path ?? NSHomeDirectory()
        self.udsPath = (base as NSString)
            .appendingPathComponent(LocalSessionControlClient.socketFilename)
        // v1.16 hotfix: NSHomeDirectory() / `~` expansion both honour
        // the App Sandbox redirect, returning
        // `~/Library/Containers/yyh.CLI-Pulse/Data` instead of the
        // user's real home. The helper .pkg installs to the REAL
        // `~/Library/CLI-Pulse-Helper/` (the postinstall script runs
        // unsandboxed as the user), so the macOS app must look there
        // too. `getpwuid(getuid())->pw_dir` bypasses the sandbox
        // redirect on macOS and returns the actual home directory.
        let realHome: String = {
            if let pw = getpwuid(getuid()), let cstr = pw.pointee.pw_dir {
                return String(cString: cstr)
            }
            return NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
        }()
        self.helperDir = (realHome as NSString)
            .appendingPathComponent("Library/CLI-Pulse-Helper")
    }

    // MARK: - Public API

    /// Refresh the state by probing the local helper + comparing against
    /// the latest manifest. Called on app launch + once per 24h while
    /// running + on user-clicked "Check for Updates".
    @MainActor
    public func refresh() async {
        state = .checking
        let helperRunning: SessionControlHello?
        do {
            helperRunning = try await helloClient().hello()
        } catch {
            helperInstallerLog.info("hello failed (helper not running?): \(error.localizedDescription, privacy: .public)")
            helperRunning = nil
        }
        let manifest: Manifest?
        do {
            manifest = try await fetchManifest()
        } catch {
            helperInstallerLog.warning("manifest fetch failed: \(error.localizedDescription, privacy: .public)")
            manifest = nil
        }
        lastChecked = Date()

        switch (helperRunning, manifest) {
        case (nil, _):
            state = .notInstalled
        case (let hello?, nil):
            // Helper running but we couldn't reach the manifest — still
            // a working state, just no update info.
            state = .running(version: hello.helperVersion.isEmpty ? "older" : hello.helperVersion)
        case (let hello?, let m?):
            let installed = hello.helperVersion.isEmpty ? "0.0.0" : hello.helperVersion
            if Self.compareVersions(installed, m.version) < 0 {
                state = .updateAvailable(installed: installed, latest: m.version)
            } else {
                state = .running(version: installed)
            }
        }
    }

    /// Trigger the install (or update — the flow is identical: download
    /// .pkg, hand off to Installer.app). Polls helper liveness until it
    /// answers `hello` or the timeout elapses. Watches NSWorkspace's
    /// did-terminate notification for `com.apple.installer` so we exit
    /// the .installing state promptly when the user cancels Installer.app.
    @MainActor
    public func install() async {
        state = .downloading(progress: 0)
        do {
            let manifest = try await fetchManifest()
            try Self.assertArchitectureMatches(manifest)
            let pkgURL = try await downloadPkg(manifest: manifest)
            state = .installing
            // NSWorkspace.open hands the .pkg to system Installer.app.
            // From a sandboxed parent app, this path is permitted by
            // default — Installer.app runs unsandboxed and lays down
            // files outside our container.
            NSWorkspace.shared.open(pkgURL)
            await pollHelperUntilReady(timeout: 120, expectedVersion: manifest.version)
        } catch {
            helperInstallerLog.error("install failed: \(error.localizedDescription, privacy: .public)")
            state = .error(error.localizedDescription)
            lastChecked = Date()
        }
    }

    /// Returns when Installer.app terminates, or after timeout.
    /// Used by pollHelperUntilReady to short-circuit the 120s wait
    /// when the user cancels — no point polling a UDS the installer
    /// will never bring up.
    private func waitForInstallerToTerminate(timeout: TimeInterval) async -> Bool {
        let installerBundleID = "com.apple.installer"

        // If Installer.app isn't running by the time we get here, treat
        // as already-terminated (could mean: install completed too fast
        // to observe, or user canceled before pkg opened).
        let runningInstallers = NSRunningApplication.runningApplications(
            withBundleIdentifier: installerBundleID
        )
        if runningInstallers.isEmpty {
            return true
        }

        return await withCheckedContinuation { continuation in
            var observer: NSObjectProtocol?
            var resolved = false
            let resolveOnce: (Bool) -> Void = { value in
                guard !resolved else { return }
                resolved = true
                // v1.16 hotfix: observer was added to
                // NSWorkspace.shared.notificationCenter but the pre-fix
                // path tried to remove it from NotificationCenter.default
                // (different center) — so removal silently failed and
                // every install leaked another observer that watched
                // every app termination forever, flooding the Xcode
                // console with XPC `<decode: bad range>` warnings as
                // the system XPC machinery decoded each termination's
                // userInfo on N orphaned observers. Use the matching
                // workspace center for removal.
                if let observer {
                    NSWorkspace.shared.notificationCenter.removeObserver(observer)
                }
                continuation.resume(returning: value)
            }
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   app.bundleIdentifier == installerBundleID {
                    resolveOnce(true)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                resolveOnce(false)
            }
        }
    }

    /// Launch the Helper Uninstaller.app (which lives inside the helper
    /// install dir). The MAS app's role is to launch it; the actual
    /// uninstall logic runs inside the .app per `helper-uninstaller/main.swift`.
    /// Falls back to revealing the .app in Finder if the sandbox blocks
    /// `openApplication` (Gemini slice 4E.2 review flagged this as a real
    /// risk for paths outside the app-group container).
    @MainActor
    public func uninstall() async {
        let uninstallerURL = URL(
            fileURLWithPath: helperDir
        ).appendingPathComponent("CLI Pulse Helper Uninstaller.app")
        // v1.16 hotfix: skip the pre-existence FileManager check —
        // App Sandbox can return false for paths under /Users that
        // exist on disk but aren't reachable through the container's
        // POSIX view, even though LaunchServices (used by
        // openApplication below) ignores those restrictions and can
        // still launch the app. The pre-check produced a false-
        // negative "Uninstaller missing" error for installs that were
        // actually present at ~/Library/CLI-Pulse-Helper/. If the URL
        // really is missing, openApplication throws below and we fall
        // through to the Finder-reveal recovery path.
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: uninstallerURL, configuration: cfg)
            // Uninstaller.app does its work + trampolines deletion of
            // helperDir. Wait a few seconds, then refresh — should land
            // on .notInstalled.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            await refresh()
        } catch {
            // Sandbox may block direct openApplication on paths outside
            // our group container. Fall back to revealing the .app in
            // Finder — user double-clicks to run, equally effective.
            helperInstallerLog.warning("openApplication failed (\(error.localizedDescription, privacy: .public)); falling back to Finder reveal")
            NSWorkspace.shared.activateFileViewerSelecting([uninstallerURL])
            state = .error("Open the Uninstaller manually from Finder (revealed). It was placed at \(uninstallerURL.path).")
        }
    }

    /// UDS liveness probe via Network.framework — cleaner than raw
    /// sockaddr_un (per Gemini final-review of plan §1.8). Uses a single
    /// resume-once primitive so neither the state callback nor the
    /// timeout can resume the continuation twice. The connection runs
    /// on its own serialized queue, which is a single-writer surface,
    /// so the state-update callback is naturally serialized — no lock
    /// needed inside it.
    public func probeHelperLiveness(timeout: TimeInterval = 1.0) async -> Bool {
        let probeQueue = DispatchQueue(label: "com.cli-pulse.helper-installer.probe")
        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.unix(path: udsPath)
            let conn = NWConnection(to: endpoint, using: .tcp)

            // Box the continuation so both callbacks see the same shared
            // state. ResumedOnce is set on FIRST resolution and ignored
            // afterwards. The probeQueue serializes all reads/writes so
            // we don't need an extra lock.
            final class Resolver {
                var done = false
            }
            let resolver = Resolver()

            let resolveOnce: (Bool) -> Void = { value in
                probeQueue.async {
                    guard !resolver.done else { return }
                    resolver.done = true
                    conn.cancel()
                    continuation.resume(returning: value)
                }
            }

            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resolveOnce(true)
                case .failed, .cancelled:
                    resolveOnce(false)
                default:
                    break  // .setup / .preparing / .waiting — stay in flight
                }
            }
            conn.start(queue: probeQueue)
            probeQueue.asyncAfter(deadline: .now() + timeout) {
                resolveOnce(false)
            }
        }
    }

    // MARK: - Internals

    private func fetchManifest() async throws -> Manifest {
        // v1.19 G7: default URLSession cache can hide newly-published
        // manifests for hours. Force a network round-trip every time
        // so users see new helper releases as soon as we publish them.
        var request = URLRequest(url: manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "HelperInstaller",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Manifest fetch HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"]
            )
        }
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private func downloadPkg(manifest: Manifest) async throws -> URL {
        guard let url = URL(string: manifest.url) else {
            throw NSError(
                domain: "HelperInstaller",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid manifest URL: \(manifest.url)"]
            )
        }
        let (tempURL, response) = try await urlSession.download(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "HelperInstaller",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Pkg download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"]
            )
        }
        // Move to a stable temp path so NSWorkspace.open has a valid URL after
        // URLSession's tempURL gets cleaned up.
        let finalURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-pulse-helper-\(manifest.version)-\(manifest.arch).pkg")
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempURL, to: finalURL)

        // Verify SHA-256 of the downloaded pkg against the manifest. v1.21 D4:
        // hashed off-main via Task.detached so the install-progress UI stays
        // responsive while a 30-80 MB pkg is being fingerprinted.
        let actualSHA = try await Task.detached {
            try CryptoHelpers.sha256Hex(of: finalURL)
        }.value
        guard actualSHA.lowercased() == manifest.sha256.lowercased() else {
            try? FileManager.default.removeItem(at: finalURL)
            throw NSError(
                domain: "HelperInstaller",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Pkg SHA-256 mismatch (expected \(manifest.sha256), got \(actualSHA))"]
            )
        }
        return finalURL
    }

    @MainActor
    private func pollHelperUntilReady(timeout: TimeInterval, expectedVersion: String) async {
        // Run two waits in parallel:
        //   (a) installer-terminate observer — fires when Installer.app
        //       quits (success OR cancellation, can't tell which)
        //   (b) helper-up poller — fires when UDS answers hello
        // Whichever wins first decides the next state. If installer
        // quits and helper STILL isn't up after a short post-quit wait,
        // we go to .notInstalled (user cancelled or install failed
        // visibly in Installer.app's UI).
        let pollTask: Task<Bool, Never> = Task {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if Task.isCancelled { return false }
                if await self.probeHelperLiveness(timeout: 1.0) {
                    if let hello = try? await self.helloClient().hello() {
                        await MainActor.run {
                            let v = hello.helperVersion.isEmpty ? expectedVersion : hello.helperVersion
                            self.state = .running(version: v)
                        }
                        return true
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            return false
        }

        let installerQuit = await waitForInstallerToTerminate(timeout: timeout)

        if installerQuit {
            // Installer terminated. Give the helper one more shot at
            // bind (postinstall.sh may still be in its 10s wait), then
            // decide.
            for _ in 0..<10 {
                if pollTask.isCancelled { break }
                if await probeHelperLiveness(timeout: 1.0),
                   let hello = try? await helloClient().hello() {
                    let v = hello.helperVersion.isEmpty ? expectedVersion : hello.helperVersion
                    state = .running(version: v)
                    pollTask.cancel()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            // Helper not up post-installer-quit → user canceled or install
            // failed. Re-checking refresh() lets us land on .notInstalled
            // or .running depending on what actually exists.
            pollTask.cancel()
            await refresh()
            return
        }

        // Installer didn't terminate within timeout AND helper didn't come
        // up. Either the user is sitting on the installer screen, or the
        // installer is hung. pollTask result reveals which.
        let pollResult = await pollTask.value
        if !pollResult {
            state = .error("Helper did not become ready within \(Int(timeout))s. Check ~/Library/Logs/CLI-Pulse-Helper/")
        }
    }

    // MARK: - Helpers

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
                domain: "HelperInstaller",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Manifest is for \(manifest.arch) but this Mac is \(host). Wait for \(host) build."]
            )
        }
    }

}
// v1.21 D4: removed local sha256(of:) — callers route through CryptoHelpers.
// CommonCrypto import removed in favor of CryptoKit (via CryptoHelpers).

#endif
