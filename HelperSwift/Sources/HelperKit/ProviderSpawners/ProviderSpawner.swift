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
///   3. `envOverrides(extraEnv:)` at spawn time — provider-specific
///      env merged onto the manager's base env.
///   4. `supportsRemoteApproval()` informational — only Claude has
///      a hook protocol; Codex/Gemini handle approvals inline in
///      the TUI. The iOS picker may use this to surface a "this
///      session can't be remote-approved" hint.
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

    /// Provider-specific env additions beyond what the manager
    /// already injects (`CLI_PULSE_LOCAL_HOOK_TOKEN`, etc.).
    /// Default is empty — most providers don't need anything.
    func envOverrides(extraEnv: [String: String]) -> [String: String]

    /// Does this provider's session route approvals through the
    /// helper's `kind='approval'` hook protocol? True for Claude
    /// (via `--settings` injection); false for Codex/Gemini
    /// because their TUIs handle approvals natively.
    func supportsRemoteApproval() -> Bool
}

public extension ProviderSpawner {
    func envOverrides(extraEnv: [String: String]) -> [String: String] { [:] }

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
    /// `defaultIsAvailable()`.
    static func findOnPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
