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
        /// Helper binary is installed on disk but the liveness probe failed
        /// (socket path mismatch, mid-restart, wrong run-user, token issue,
        /// timeout). Distinct from `.notInstalled` so the UI offers "Re-check"
        /// / "Uninstall" instead of a misleading "Install". String = a short
        /// diagnostic (probed socket path + existence).
        case unreachable(String)
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
    /// v1.30.2 (RC-1): pairing state from the helper's last `hello` reply.
    /// nil = unknown (older helper or never probed); false = installed +
    /// running but not paired → the UI prompts the user to pair. Lets the
    /// `.running` UI add a "pair to activate managed sessions" hint without
    /// regressing to a misleading "not installed".
    @Published public private(set) var helperPaired: Bool?

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
        // Shared resolver: prefers the sandbox container, else the REAL-home
        // group container the helper binds in (NOT NSHomeDirectory(), which is
        // the app's private sandbox container — a path the helper never uses,
        // which made the post-install liveness probe target the wrong socket).
        self.udsPath = (LocalSessionControlClient.groupContainerBasePath() as NSString)
            .appendingPathComponent(LocalSessionControlClient.socketFilename)
        // v1.16 hotfix: NSHomeDirectory() / `~` expansion both honour
        // the App Sandbox redirect, returning
        // `~/Library/Containers/yyh.CLI-Pulse/Data` instead of the
        // user's real home. The helper .pkg installs to the REAL
        // `~/Library/CLI-Pulse-Helper/` (the postinstall script runs
        // unsandboxed as the user), so the macOS app must look there
        // too. `passwdHomeDirectory()` (thread-safe `getpwuid_r`) bypasses the
        // sandbox redirect on macOS and returns the actual home directory.
        let realHome: String = passwdHomeDirectory()
            ?? NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory()
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
        // v1.30.2 (RC-1): record pairing state from this probe. nil when
        // hello failed (unknown) or the helper predates the `paired` field.
        helperPaired = helperRunning?.paired

        switch (helperRunning, manifest) {
        case (nil, _):
            // hello() failed. Distinguish "installed but not responding" from
            // "not installed" using the SOCKET FILE in the group container —
            // NOT the helper binary under ~/Library/CLI-Pulse-Helper, which the
            // sandboxed app cannot stat (FileManager.fileExists would falsely
            // return false). The group container IS sandbox-accessible. A
            // socket present + hello failing = ECONNREFUSED/timeout against a
            // bound path → the helper is there but not answering
            // (.unreachable); no socket = ENOENT → nothing bound here
            // (.notInstalled). Showing .notInstalled for the former offered
            // only "Install" (wrong) and hid a re-checkable state.
            if FileManager.default.fileExists(atPath: udsPath) {
                state = .unreachable(
                    "Companion CLI socket exists but isn't responding (\(udsPath)). The helper may be restarting or mis-bound — try Re-check, or Uninstall and reinstall."
                )
            } else {
                state = .notInstalled
            }
        case (let hello?, nil):
            // Helper running but we couldn't reach the manifest — still
            // a working state, just no update info.
            state = .running(version: hello.helperVersion.isEmpty ? "older" : hello.helperVersion)
        case (let hello?, let m?):
            if hello.helperVersion.isEmpty {
                // Helper answered hello but reported no version (older
                // protocol that omits helper_version). We can't compare, and
                // it IS running — don't show a spurious, permanent "update
                // available" (the old `"0.0.0" < latest` path did exactly
                // that, so a working helper never showed plain .running).
                state = .running(version: "installed")
            } else if Self.compareVersions(hello.helperVersion, m.version) < 0 {
                state = .updateAvailable(installed: hello.helperVersion, latest: m.version)
            } else {
                state = .running(version: hello.helperVersion)
            }
        }
    }

    /// Pure decision for the popover-reopen / app-active re-probe hook (RC-2).
    /// Extracted so it's unit-testable with an injected clock.
    /// - Mid-flight states ({downloading, installing, checking}) never
    ///   re-probe — the install/refresh flow already owns the state, and a
    ///   re-probe mid-install would race it.
    /// - Every settled state ({notInstalled, unreachable, error, running,
    ///   updateAvailable}) re-probes when the last check is older than
    ///   `maxAge` (or never happened). This is what catches a helper that
    ///   bound its socket AFTER the one-shot launch probe — e.g. the user
    ///   finished Installer.app, the state settled `.notInstalled`, and on the
    ///   next popover open (> maxAge later) we re-probe and flip to `.running`.
    ///   The `maxAge` gate also stops rapid open/close toggling from hammering
    ///   the manifest endpoint with overlapping refreshes.
    public static func shouldReprobe(
        state: State, lastChecked: Date?, now: Date, maxAge: TimeInterval
    ) -> Bool {
        switch state {
        case .downloading, .installing, .checking:
            return false
        case .notInstalled, .unreachable, .error, .running, .updateAvailable:
            guard let lastChecked else { return true }
            return now.timeIntervalSince(lastChecked) >= maxAge
        }
    }

    /// Re-probe the helper when the menu-bar popover becomes active again
    /// (RC-2). `MenuBarExtra(.window)` reuses the popover's content view across
    /// open/close, so the one-shot `.task { refresh() }` never re-fires —
    /// without this hook a helper that bound its socket after install keeps
    /// showing its stale state until the user manually taps "Re-check".
    @MainActor
    public func refreshIfStale(now: Date = Date(), maxAge: TimeInterval = 8) async {
        guard Self.shouldReprobe(
            state: state, lastChecked: lastChecked, now: now, maxAge: maxAge
        ) else { return }
        await refresh()
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
            // F8 (deep-audit 2026-07-04): the manifest is unsigned, so before
            // trusting anything it declares, pin the download to the official
            // helper-release host and sanity-check the declared size. Then
            // refuse a downgrade — an attacker-controlled latest.json must not
            // be able to push an old, legitimately-signed but vulnerable helper
            // over a newer install. Installed version is a best-effort hello
            // probe (nil/empty on a fresh install → nothing to downgrade from).
            try HelperPkgVerifier.validatePkgURL(manifest.url)
            // Reject a non-numeric version BEFORE it flows into the on-disk
            // filename (which pkgutil echoes back) or the downgrade compare.
            try HelperPkgVerifier.validateVersion(manifest.version)
            try HelperPkgVerifier.validateSize(manifest.sizeBytes)
            if let installed = await currentInstalledVersion(), !installed.isEmpty {
                try HelperPkgVerifier.assertNotDowngrade(installed: installed, candidate: manifest.version)
            }
            let pkgURL = try await downloadPkg(manifest: manifest)
            state = .installing
            // Hand the .pkg to system Installer.app. From a sandboxed
            // parent app this is permitted by default — Installer.app runs
            // unsandboxed and lays down files outside our container.
            //
            // Use the ASYNC open API, not the legacy synchronous
            // `NSWorkspace.shared.open(_:)`. install() is @MainActor, and the
            // synchronous overload performs a blocking LaunchServices XPC
            // round-trip on the main thread — on a cold LS database / first
            // Installer.app launch / Gatekeeper assessment of the freshly
            // downloaded pkg that parks the main run loop for seconds,
            // freezing the menu-bar UI and tripping Sentry's app-hang
            // watchdog (APPLE-MACOS-C). The async overload suspends the actor
            // instead of blocking the thread, so the UI stays live while
            // LaunchServices works. (Mirrors the uninstall path's
            // `openApplication(at:configuration:)` below.)
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.open(pkgURL, configuration: cfg)
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
        func installerIsRunning() -> Bool {
            !NSRunningApplication.runningApplications(
                withBundleIdentifier: installerBundleID
            ).isEmpty
        }

        // RC-3: `NSWorkspace.open(pkg)` returns once LaunchServices ACCEPTS the
        // open request — which can be 50–200ms before Installer.app actually
        // registers in the running-apps list. The old code read "not running
        // right now" as "already terminated", entered the short post-quit
        // grace prematurely, and settled on `.notInstalled` before the user
        // had even seen the installer. Wait briefly for Installer.app to
        // APPEAR first; only if it never shows do we treat it as
        // already-terminated (install completed too fast to observe, or the
        // user cancelled before the pkg opened — the caller's helper probe
        // then decides the real outcome).
        if !installerIsRunning() {
            let appearDeadline = Date().addingTimeInterval(5)
            while Date() < appearDeadline {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if installerIsRunning() { break }
            }
            if !installerIsRunning() {
                return true
            }
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

        // F8: exact byte-size match vs the manifest (cheap first line of defense
        // before the SHA + signature work). A truncated / swapped payload trips
        // here.
        let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        let actualSize = (attrs?[.size] as? NSNumber)?.intValue ?? -1
        do {
            try HelperPkgVerifier.assertSizeMatch(expected: manifest.sizeBytes, actual: actualSize)
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }

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

        // F8: Developer ID Installer team-pin + notarization on the downloaded
        // .pkg. DEVID build only — the sandboxed MAS build cannot exec spctl/
        // pkgutil; there, Installer.app's own Gatekeeper install-assessment is
        // the backstop, and the URL/size/downgrade guards above still apply.
        #if DEVID_BUILD
        do {
            try HelperPkgVerifier.verifyPkgSignatureAndNotarization(finalURL)
        } catch {
            try? FileManager.default.removeItem(at: finalURL)
            throw error
        }
        #endif
        return finalURL
    }

    /// Best-effort currently-installed helper version via a fresh `hello`
    /// probe, for the F8 downgrade guard. Returns nil when the helper isn't
    /// reachable (fresh install) or predates the version field — the caller
    /// then skips the downgrade check rather than blocking a legitimate first
    /// install.
    private func currentInstalledVersion() async -> String? {
        guard let hello = try? await helloClient().hello() else { return nil }
        return hello.helperVersion
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
                            self.helperPaired = hello.paired
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
            // Installer terminated. Give the helper time to bind before we
            // settle the state. RC-3: the old 10×1s (10s) grace was far too
            // short — the LaunchAgent's first launch (postinstall bootstrap +
            // the daemon's own startup) can take longer, and settling on
            // `.notInstalled` after 10s produced the "installed but shows not
            // installed" report. Probe for up to 45s post-quit; the parallel
            // pollTask's 120s budget still covers a genuinely slow case.
            for _ in 0..<45 {
                if pollTask.isCancelled { break }
                if await probeHelperLiveness(timeout: 1.0),
                   let hello = try? await helloClient().hello() {
                    let v = hello.helperVersion.isEmpty ? expectedVersion : hello.helperVersion
                    state = .running(version: v)
                    helperPaired = hello.paired
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
