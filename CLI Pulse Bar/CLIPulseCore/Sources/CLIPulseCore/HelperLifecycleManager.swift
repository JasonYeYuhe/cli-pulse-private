#if os(macOS)
import Foundation
import ServiceManagement
import OSLog

/// Phase 4 helper-bundling: register and supervise the embedded
/// `cli_pulse_helper` LaunchAgent so users don't need a Python install
/// or GitHub checkout to use the local fast-path Sessions feature.
///
/// Architecture rationale:
///
///   * The macOS app is sandboxed (`com.apple.security.app-sandbox`).
///     A sandboxed parent cannot spawn an unsandboxed child via
///     `Process` / `posix_spawn`; the child inherits the parent's
///     sandbox by default. The helper needs full user-level
///     filesystem + subprocess access (it reads
///     `~/.claude/settings.json`, walks git repos, spawns Claude
///     PTY children for managed sessions). So child-process
///     embedding is structurally wrong.
///
///   * `SMAppService.agent(plistName:)` (macOS 13+) registers a
///     LaunchAgent shipped inside the app bundle at
///     `Contents/Library/LaunchAgents/<name>.plist`. launchd then
///     starts the agent in the user's login session WITHOUT the
///     sandbox restrictions of the parent app — exactly the right
///     trust boundary for our daemon.
///
///   * Communication happens via the existing app-group container
///     UDS socket (`~/Library/Group Containers/group.yyh.CLI-Pulse/`).
///     The app accesses that path via its sandbox group entitlement;
///     the unsandboxed agent accesses the same path as a regular
///     directory under `$HOME/Library`. Both sides see the same
///     socket file.
///
/// The LaunchAgent plist on disk is rewritten on first registration
/// to substitute three placeholders:
///
///   * `__CLI_PULSE_HELPER_BIN__` → absolute path to the bundled
///     `Contents/Helpers/cli_pulse_helper` binary inside this build's
///     .app
///   * `__CLI_PULSE_SUPABASE_URL__`, `__CLI_PULSE_SUPABASE_ANON_KEY__`
///     → values copied from the app's Info.plist (same anon key the
///     SwiftUI HelperAPIClient uses; no new credential surface)
///   * `__HOME__` → the user's home directory (so log paths resolve
///     correctly even on multi-user Macs)
///
/// The substitution lives in `installAgentPlist()`; SMAppService
/// then registers the rewritten copy.
public actor HelperLifecycleManager {

    /// Current state of the agent registration. Drives the
    /// Settings → Helper status surface in SwiftUI so the user
    /// can see whether the embedded helper is running, missing,
    /// crashed-restarting, etc.
    public enum Status: Sendable, Equatable {
        /// First-launch state: app hasn't tried to register yet.
        case notRegistered
        /// `SMAppService.agent.register()` succeeded; launchd has
        /// the plist and is starting / supervising the helper.
        case registered
        /// User explicitly disabled the agent via
        /// `unregisterAgent()` (Settings → Helper → Stop).
        case userDisabled
        /// Registration call failed (sandbox, permissions, plist
        /// malformed, …). Detail string carries the localised
        /// reason for surfacing in the Settings panel.
        case registrationFailed(String)
        /// Build does NOT contain the embedded helper at the
        /// expected `Contents/Helpers/cli_pulse_helper` path. This
        /// is the expected state for development builds before the
        /// "Build Helper Binary" Run Script phase has run, OR for
        /// any build where the Copy Files phase was skipped. UI
        /// shows a "embedded helper missing — falling back to
        /// manually-started daemon" hint.
        case bundledBinaryMissing
    }

    private let logger = Logger(subsystem: "yyh.CLI-Pulse", category: "HelperLifecycle")

    /// `Label` field of the LaunchAgent plist; MUST match the
    /// filename in `Contents/Library/LaunchAgents/` (Apple's
    /// resolver pairs them by exact match).
    public static let agentLabel = "yyh.CLI-Pulse.helper"
    public static let agentPlistName = "yyh.CLI-Pulse.helper.plist"

    /// Template plist filename inside the .app bundle's main
    /// resources (NOT the LaunchAgents subdirectory). The on-disk
    /// install path is `Contents/Library/LaunchAgents/` once
    /// substitution has run; we keep the template as a Resources
    /// item so the build phase doesn't have to copy anything
    /// special — Xcode handles both.
    public static let plistResourceName = "HelperAgent"

    private var lastKnownStatus: Status = .notRegistered

    public init() {}

    // MARK: - Public entry points

    /// Idempotent: ensure the embedded helper is registered with
    /// launchd. Safe to call on every app launch — re-registering
    /// the same plist with the same label is a no-op for
    /// SMAppService.
    @discardableResult
    public func ensureRegistered() async -> Status {
        guard let helperBinaryURL = Self.locateBundledHelperBinary() else {
            logger.error("embedded helper binary missing at Contents/Helpers/cli_pulse_helper")
            lastKnownStatus = .bundledBinaryMissing
            return lastKnownStatus
        }

        do {
            try installAgentPlist(helperBinary: helperBinaryURL)
        } catch {
            let message = "rewrite plist: \(error.localizedDescription)"
            logger.error("\(message)")
            lastKnownStatus = .registrationFailed(message)
            return lastKnownStatus
        }

        // SMAppService.agent registers the .plist by NAME (not path);
        // the framework looks under the calling app's
        // Contents/Library/LaunchAgents/. Phase 4 build phase
        // copies the rewritten plist into that directory.
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            try service.register()
            logger.info("registered LaunchAgent \(Self.agentLabel, privacy: .public)")
            lastKnownStatus = .registered
        } catch let error as NSError {
            // SMAppService.Error.unsupportedFile (1010) on dev
            // builds without proper signing — surface as a clear
            // diagnostic. Other codes (already-registered,
            // permission-denied) propagate verbatim.
            let detail = "SMAppService.register failed: \(error.domain)/\(error.code) \(error.localizedDescription)"
            logger.error("\(detail)")
            lastKnownStatus = .registrationFailed(detail)
        }
        return lastKnownStatus
    }

    /// Tear down the agent. Used by the Settings → "Stop helper"
    /// button when the user wants to opt out of local Sessions.
    /// Returns the new status (`.userDisabled` on success).
    @discardableResult
    public func unregisterAgent() async -> Status {
        let service = SMAppService.agent(plistName: Self.agentPlistName)
        do {
            try await service.unregister()
            logger.info("unregistered LaunchAgent \(Self.agentLabel, privacy: .public)")
            lastKnownStatus = .userDisabled
        } catch let error as NSError {
            let detail = "SMAppService.unregister failed: \(error.domain)/\(error.code) \(error.localizedDescription)"
            logger.error("\(detail)")
            lastKnownStatus = .registrationFailed(detail)
        }
        return lastKnownStatus
    }

    public func currentStatus() -> Status { lastKnownStatus }

    // MARK: - Internals

    /// Resolve the embedded helper binary path inside this build's
    /// .app bundle. Returns `nil` when the binary is missing — the
    /// caller surfaces `.bundledBinaryMissing` rather than failing
    /// the registration outright (development builds may not have
    /// run the build phase yet).
    public static func locateBundledHelperBinary() -> URL? {
        // App bundle layout (macOS .app):
        //   CLI Pulse Bar.app/             ← Bundle.main.bundleURL
        //     Contents/
        //       MacOS/CLI Pulse Bar         ← Bundle.main.executableURL
        //       Helpers/cli_pulse_helper    ← what we want
        //       Library/LaunchAgents/yyh.CLI-Pulse.helper.plist
        guard let contents = appContentsDir() else { return nil }
        let helper = contents
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("cli_pulse_helper")
        return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
    }

    /// Path SMAppService expects the agent plist to live at: the
    /// Contents/Library/LaunchAgents/ subdirectory of the calling
    /// app's bundle. The template plist gets rewritten in place
    /// here every registration so credential / path drift between
    /// builds is corrected automatically.
    public static func agentPlistPath() -> URL? {
        return appContentsDir()?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .appendingPathComponent(agentPlistName)
    }

    /// Resolve `<.app>/Contents/` for the running bundle. Uses
    /// `Bundle.main.bundleURL` rather than walking from
    /// `executableURL`, because xctest runtimes have an executable
    /// path two levels up from a non-.app directory and walking up
    /// from there produces nonsense paths under
    /// `/Applications/Xcode.app/Contents/Developer/usr/...`.
    /// Returns nil for non-.app bundles (xctest, command-line tools)
    /// — the caller surfaces `.bundledBinaryMissing` for those.
    private static func appContentsDir() -> URL? {
        let bundleURL = Bundle.main.bundleURL
        // .app bundles end with `.app`; if not, we're inside a
        // test runner / cli tool and the `Contents/` shim doesn't
        // exist.
        guard bundleURL.pathExtension == "app" else { return nil }
        return bundleURL.appendingPathComponent("Contents", isDirectory: true)
    }

    /// Read the template plist from the app bundle resources,
    /// substitute the four placeholders, and write the result to
    /// `Contents/Library/LaunchAgents/<plistName>`. The build phase
    /// already copies the template into Resources/; this rewrite
    /// produces the materialised version SMAppService needs.
    private func installAgentPlist(helperBinary: URL) throws {
        guard let templateURL = Bundle.main.url(
            forResource: Self.plistResourceName, withExtension: "plist"
        ) else {
            throw HelperLifecycleError.templatePlistMissing
        }
        guard let agentDir = Self.agentPlistPath()?.deletingLastPathComponent() else {
            throw HelperLifecycleError.bundleLayoutBroken
        }
        try FileManager.default.createDirectory(
            at: agentDir, withIntermediateDirectories: true
        )

        let template = try String(contentsOf: templateURL, encoding: .utf8)

        // Pull SUPABASE_* from the app's own Info.plist — same
        // values HelperAPIClient already uses, so no new secret
        // surface and no chance of agent / app drift.
        let supabaseURL = (
            Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String
        ) ?? "https://gkjwsxotmwrgqsvfijzs.supabase.co"
        let supabaseKey = (
            Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String
        ) ?? ""
        let homePath = NSHomeDirectory()

        let rewritten = Self.substitutePlistTemplate(
            template,
            helperBinaryPath: helperBinary.path,
            supabaseURL: supabaseURL,
            supabaseAnonKey: supabaseKey,
            homePath: homePath
        )

        let outputURL = agentDir.appendingPathComponent(Self.agentPlistName)
        try rewritten.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    /// Pure string-substitution: extracted from `installAgentPlist`
    /// so unit tests can pin the four placeholder names without
    /// instantiating SMAppService or the bundle. Phase 4: any
    /// future change to placeholder syntax MUST update both
    /// `HelperAgent.plist` and this method's expected token list.
    public static func substitutePlistTemplate(
        _ template: String,
        helperBinaryPath: String,
        supabaseURL: String,
        supabaseAnonKey: String,
        homePath: String
    ) -> String {
        return template
            .replacingOccurrences(of: "__CLI_PULSE_HELPER_BIN__", with: helperBinaryPath)
            .replacingOccurrences(of: "__CLI_PULSE_SUPABASE_URL__", with: supabaseURL)
            .replacingOccurrences(of: "__CLI_PULSE_SUPABASE_ANON_KEY__", with: supabaseAnonKey)
            .replacingOccurrences(of: "__HOME__", with: homePath)
    }
}

/// Setup-time errors that prevent registration from being attempted.
/// Surface each as a `.registrationFailed(detail)` status with a
/// human-readable message so the Settings panel can render
/// something actionable.
public enum HelperLifecycleError: Error, LocalizedError {
    case templatePlistMissing
    case bundleLayoutBroken

    public var errorDescription: String? {
        switch self {
        case .templatePlistMissing:
            return "HelperAgent.plist resource is not in the app bundle. The Xcode build target is missing a Copy Files phase that includes HelperAgent.plist in Resources."
        case .bundleLayoutBroken:
            return "Cannot resolve Contents/Library/LaunchAgents path from the running executable. Bundle layout is unexpected — running from a non-standard location."
        }
    }
}
#endif
