import Foundation

/// Gemini CLI (Google) spawner — v1.15.
///
/// Gemini has an `--approval-mode` flag with values
/// `default | auto_edit | yolo | plan` plus a `--yolo` shorthand.
/// There is no first-class hook protocol the helper can subscribe to.
///
/// `extraEnv` carries an optional `CLI_PULSE_GEMINI_YOLO=1` flag
/// when an opt-in YOLO toggle ships in the picker. The translation
/// logic — env var ⇒ `--yolo` argv flag — is implemented here so the
/// spawner is ready when the UI lands.
///
/// Future picker work (NOT in v1.15): explicit per-spawn
/// "Auto-approve all tools (yolo)" toggle. Until that UI ships, the
/// env var is never set by any caller and Gemini runs in `default`
/// mode.
///
/// Override the binary path via `CLI_PULSE_GEMINI_ARGV0`.
public struct GeminiSpawner: ProviderSpawner {
    public let name = "gemini"
    public init() {}
    public func isAvailable() -> Bool { defaultIsAvailable() }

    public func argv(
        extraEnv: [String: String],
        helperArgv0: String?
    ) -> [String] {
        var argv = defaultArgv0()
        // Truthy-aliases match the Python parity table: "1", "true",
        // "yes" all enable; everything else (incl. nil/empty) leaves
        // Gemini in default mode.
        if Self.envFlagEnabled(extraEnv["CLI_PULSE_GEMINI_YOLO"]) {
            argv.append("--yolo")
        }
        return argv
    }

    public func supportsRemoteApproval() -> Bool { false }

    /// Public for tests — the same truthy-aliases table the Python
    /// spawner ships, so the iOS picker can pass the same env value
    /// to both helpers without provider-specific shim logic.
    public static func envFlagEnabled(_ raw: String?) -> Bool {
        guard let raw else { return false }
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "1", "true", "yes": return true
        default: return false
        }
    }
}
