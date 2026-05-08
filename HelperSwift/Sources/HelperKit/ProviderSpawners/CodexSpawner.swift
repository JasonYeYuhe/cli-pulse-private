import Foundation

/// Codex CLI (OpenAI) spawner — v1.15.
///
/// Codex 0.128.x defaults to interactive PTY mode. There is no
/// hook protocol the helper can subscribe to (approvals run
/// inline in Codex's TUI), so `supportsRemoteApproval()` is false
/// and the iOS picker labels these sessions accordingly.
///
/// Override the binary path via `CLI_PULSE_CODEX_ARGV0` (same
/// shape as Claude/Gemini overrides).
public struct CodexSpawner: ProviderSpawner {
    public let name = "codex"
    public init() {}
    public func isAvailable() -> Bool { defaultIsAvailable() }
    public func argv(
        extraEnv: [String: String],
        helperArgv0: String?
    ) -> [String] {
        defaultArgv0()
    }
    public func supportsRemoteApproval() -> Bool { false }
}
