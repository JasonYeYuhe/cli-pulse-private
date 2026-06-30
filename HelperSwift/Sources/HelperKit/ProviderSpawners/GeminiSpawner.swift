import Foundation

/// Gemini spawner — v1.35: route managed Gemini through the `agy` wrapper so the session
/// runs on the user's GEMINI PLAN (OAuth via `~/.gemini/oauth_creds.json`, which `agy`
/// self-refreshes) instead of bare `gemini` (which may run API/off-plan). `agy` is the
/// proven path (feedback_managed_claude_agy_auth: `agy` stays interactive under the PTY
/// with no IneligibleTierError).
///
/// We launch BARE `agy` (an interactive REPL). We deliberately do NOT seed a prompt via
/// argv/env — argv + env leak to same-user `ps`/process inspection and subprocesses; if a
/// seed is ever needed it must be written to the PTY after spawn.
///
/// Binary resolution order: `CLI_PULSE_GEMINI_ARGV0` (explicit override, also the
/// flag-drift escape hatch) → `/opt/homebrew/bin/agy` → `agy` on the augmented PATH.
public struct GeminiSpawner: ProviderSpawner {
    public let name = "gemini"
    public init() {}

    public func isAvailable() -> Bool { Self.resolveAgyArgv0() != nil }

    public func argv(
        extraEnv: [String: String],
        helperArgv0: String?
    ) -> [String] {
        let argv0 = Self.resolveAgyArgv0() ?? ["agy"]   // last-resort bare name
        let yolo = Self.envFlagEnabled(extraEnv["CLI_PULSE_GEMINI_YOLO"])
        // Only probe `agy --help` when YOLO is actually requested (rare; no UI ships it
        // yet) so the common path stays subprocess-free.
        let help = yolo ? Self.agyHelpText(argv0: argv0) : nil
        return Self.buildArgv(argv0: argv0, yoloRequested: yolo, helpText: help)
    }

    public func supportsRemoteApproval() -> Bool { false }

    // MARK: - Pure helpers (testable)

    /// Decide the final argv. Default is bare interactive `agy`. When YOLO is requested,
    /// append `--dangerously-skip-permissions` ONLY if this `agy` advertises it — else
    /// fail SAFE (degrade to interactive approvals) rather than spawn an unknown flag
    /// (agy is a fast-moving 3rd-party CLI; a flag rename must not break spawning).
    static func buildArgv(argv0: [String], yoloRequested: Bool, helpText: String?) -> [String] {
        var argv = argv0
        if yoloRequested, (helpText ?? "").contains("--dangerously-skip-permissions") {
            argv.append("--dangerously-skip-permissions")
        }
        return argv
    }

    /// Resolve the `agy` argv0 tokens. `CLI_PULSE_GEMINI_ARGV0` wins (whitespace-tokenized
    /// so `/path/agy --foo` works); else the Homebrew path; else PATH (augmented).
    static func resolveAgyArgv0(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String]? {
        if let raw = env["CLI_PULSE_GEMINI_ARGV0"],
           !raw.trimmingCharacters(in: .whitespaces).isEmpty {
            return raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        let brew = "/opt/homebrew/bin/agy"
        if FileManager.default.isExecutableFile(atPath: brew) { return [brew] }
        if let onPath = Self.findOnPath("agy") { return [onPath] }
        return nil
    }

    /// `<agy> --help` text (best-effort; nil on any failure → caller fails safe).
    static func agyHelpText(argv0: [String]) -> String? {
        guard let exe = argv0.first else { return nil }
        let resolved = exe.hasPrefix("/") ? exe : (Self.findOnPath(exe) ?? exe)
        guard FileManager.default.isExecutableFile(atPath: resolved) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: resolved)
        proc.arguments = Array(argv0.dropFirst()) + ["--help"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        guard (try? proc.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// Truthy aliases (Python parity): "1"/"true"/"yes" enable; else default mode.
    public static func envFlagEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "1", "true", "yes": return true
        default: return false
        }
    }
}
