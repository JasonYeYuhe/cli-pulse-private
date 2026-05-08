import Foundation

/// Claude Code CLI spawner. Preserves the Phase 4D iter10 hook
/// injection semantics:
///   * `claude` argv comes from PATH (override via
///     `CLI_PULSE_CLAUDE_ARGV0`).
///   * If `helperArgv0` is non-nil AND the
///     `buildInlineSettings(helperPath:)` callback yields JSON, we
///     append `--settings <json>` so structured approvals fire for
///     this session WITHOUT mutating the user's
///     `~/.claude/settings.json`.
public struct ClaudeSpawner: ProviderSpawner {
    public let name = "claude"

    /// Closure that produces an inline-settings JSON string for the
    /// `--settings` flag. Set to nil to disable hook injection (used
    /// by tests that don't need approvals wired). The closure
    /// receives the helper's absolute path so the hook's `command`
    /// field points at the right binary.
    private let buildInlineSettings: (@Sendable (String) -> String?)?

    public init(
        buildInlineSettings: (@Sendable (String) -> String?)? = nil
    ) {
        self.buildInlineSettings = buildInlineSettings
    }

    public func isAvailable() -> Bool { defaultIsAvailable() }

    public func argv(
        extraEnv: [String: String],
        helperArgv0: String?
    ) -> [String] {
        var argv = defaultArgv0()
        if let helperArgv0,
           let builder = buildInlineSettings,
           let inlineJson = builder(helperArgv0) {
            argv.append(contentsOf: ["--settings", inlineJson])
        }
        return argv
    }

    public func supportsRemoteApproval() -> Bool { true }
}
