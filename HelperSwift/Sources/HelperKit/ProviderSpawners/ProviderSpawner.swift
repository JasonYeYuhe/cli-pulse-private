import Foundation

/// Per-provider strategy for spawning the interactive REPL on the
/// helper side. Mirrors `helper/provider_spawners/__init__.py` so the
/// Swift helper (Phase 4D / 4E) and the legacy Python helper agree
/// on argv resolution and capability advertisement byte-for-byte.
///
/// Phase 4D shipped a Claude-only Swift helper; this protocol is the
/// v1.15 multi-CLI surface added so Codex / Gemini sessions don't
/// throw `unsupportedProvider` once the Swift helper takes over the
/// LaunchAgent slot.
///
/// All implementers MUST be `Sendable` — `ManagedSessionManager`
/// captures spawners across thread boundaries (drain loop, RPC
/// dispatcher, broker) and Swift 6 concurrency wants a clean
/// guarantee.
///
/// Per-method contract (called by `ManagedSessionManager.startSession`
/// in this exact order):
///
///   1. `isAvailable()` at registry construction — the
///      `available_providers()` snapshot uses this to advertise
///      capability via the UDS `hello` reply.
///   2. `argv(extraEnv:helperArgv0:)` at spawn time — final argv.
///      `helperArgv0` is the absolute path to the helper itself,
///      used by Claude's `--settings <json>` hook injection. Other
///      providers ignore it.
///   3. `envPatch(extraEnv:resolvedHome:)` at spawn time — provider-specific
///      env mutations (set + REMOVE) applied after the base+parent env merge.
///   4. `supportsRemoteApproval()` informational — only Claude has
///      a hook protocol; Codex/Gemini handle approvals inline in
///      the TUI. The iOS picker may use this to surface a "this
///      session can't be remote-approved" hint.
/// A set/remove patch applied to the spawned child's environment AFTER the manager's
/// base env and the parent (launchd) env are merged. `remove` is essential: a plain
/// dictionary merge cannot DELETE an inherited variable, and forcing Codex onto the
/// ChatGPT plan requires deleting any inherited `OPENAI_API_KEY`.
public struct ProviderEnvPatch: Sendable, Equatable {
    public var set: [String: String]
    public var remove: Set<String>
    public init(set: [String: String] = [:], remove: Set<String> = []) {
        self.set = set
        self.remove = remove
    }
    public static let none = ProviderEnvPatch()
}

public protocol ProviderSpawner: Sendable {
    /// Canonical lower-case provider name, e.g. `"claude"`. Used as
    /// the registry key.
    var name: String { get }

    /// Whether the provider's CLI binary is on PATH (or resolvable
    /// via `CLI_PULSE_<NAME>_ARGV0` env override). Probed once at
    /// daemon start; Mac PATH doesn't usually mutate at runtime.
    func isAvailable() -> Bool

    /// Final argv to exec. `extraEnv` is the spawn request's env
    /// dict (carries `CLI_PULSE_GEMINI_YOLO=1` and friends).
    /// `helperArgv0` is the helper binary's own path; Claude uses
    /// it to inject the structured-approval hook via `--settings`.
    func argv(extraEnv: [String: String], helperArgv0: String?) -> [String]

    /// Provider-specific env mutations applied AFTER the manager's base env and the
    /// parent (launchd) env are merged: `set` overlays keys, `remove` DELETES inherited
    /// keys. `resolvedHome` is the getpwuid home (nil if unresolvable/root). Default:
    /// no change. (Codex pins `CODEX_HOME` + removes `OPENAI_API_KEY`; Claude/Gemini
    /// don't need it.)
    func envPatch(extraEnv: [String: String], resolvedHome: String?) -> ProviderEnvPatch

    /// Does this provider's session route approvals through the
    /// helper's `kind='approval'` hook protocol? True for Claude
    /// (via `--settings` injection); false for Codex/Gemini
    /// because their TUIs handle approvals natively.
    func supportsRemoteApproval() -> Bool

    /// Whether a managed session for this provider would run on the user's PLAN vs the
    /// billed pay-per-token API. Surfaced in the UDS hello reply (`provider_plan_status`)
    /// so the picker can warn before silently launching an off-plan (billed) session.
    /// Returns `"on_plan"`, `"off_plan"`, or `"unknown"` (can't determine — the picker
    /// must NOT warn on unknown). `resolvedHome` is the getpwuid home (nil if
    /// unresolvable). Default `"unknown"`. (Codex: chatgpt-auth ⇒ on_plan, apikey ⇒
    /// off_plan. Gemini: agy resolvable ⇒ on_plan. Claude's on-plan-ness is signaled by
    /// the separate OAuth-floor gate, so it stays "unknown" here.)
    func planAuthStatus(resolvedHome: String?) -> String
}

public extension ProviderSpawner {
    func envPatch(extraEnv: [String: String], resolvedHome: String?) -> ProviderEnvPatch { .none }

    func planAuthStatus(resolvedHome: String?) -> String { "unknown" }

    /// Resolve the binary's argv0 from `CLI_PULSE_<NAME>_ARGV0` env
    /// (if set, whitespace-tokenized so multi-token argv0 like
    /// `/opt/local/bin/codex --theme=dark` work) else `[name]`.
    /// Mirrors Python's `_argv0_from_env_or_default`.
    func defaultArgv0() -> [String] {
        let envKey = "CLI_PULSE_\(name.uppercased())_ARGV0"
        if let raw = ProcessInfo.processInfo.environment[envKey],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        return [name]
    }

    /// PATH lookup helper. Returns true when an executable named
    /// `name` exists in PATH OR `CLI_PULSE_<NAME>_ARGV0` points at
    /// an existing executable file.
    func defaultIsAvailable() -> Bool {
        let envKey = "CLI_PULSE_\(name.uppercased())_ARGV0"
        if let raw = ProcessInfo.processInfo.environment[envKey] {
            let first = raw.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
            if !first.isEmpty,
               FileManager.default.isExecutableFile(atPath: first) {
                return true
            }
        }
        return Self.findOnPath(name) != nil
    }

    /// $PATH lookup. Public for tests; production callers use
    /// `defaultIsAvailable()`. Searches the AUGMENTED PATH (launchd PATH + Homebrew /
    /// local bin dirs) so the picker doesn't gray out a `claude`/`codex`/`agy` that
    /// lives in `/opt/homebrew/bin` outside the sparse launchd PATH — the same PATH
    /// the spawned child gets (see `HelperEnvironment`/`PtyTransport.buildChildEnv`).
    static func findOnPath(_ name: String) -> String? {
        let base = ProcessInfo.processInfo.environment["PATH"]
        let path = HelperEnvironment.augmentedPATH(base: base, home: HelperEnvironment.resolvedUserHome())
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
