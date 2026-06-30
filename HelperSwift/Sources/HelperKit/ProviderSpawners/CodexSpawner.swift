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

    /// v1.35: make a managed Codex session run on the user's CHATGPT PLAN, not the
    /// pay-per-token API. Codex is file-driven — it reads `~/.codex/auth.json`, honors
    /// `CODEX_HOME`, and self-refreshes its own token on launch — so we don't inject a
    /// token. We:
    ///   - pin `CODEX_HOME=<home>/.codex` so codex reads the right dir even when a
    ///     launchd `HOME` drifted; and
    ///   - DELETE any inherited `OPENAI_API_KEY` so codex can't silently fall back to the
    ///     billed API — but ONLY when the user has a VERIFIED ChatGPT login
    ///     (`auth_mode=="chatgpt"` + a non-empty access/refresh token). For an api-key
    ///     user (`auth_mode=="apikey"`) or a missing/unreadable auth.json we DON'T scrub,
    ///     leaving their own auth intact (no worse than today).
    public func envPatch(extraEnv: [String: String], resolvedHome: String?) -> ProviderEnvPatch {
        var patch = ProviderEnvPatch()
        // If the home can't be resolved, do NOTHING — neither pin CODEX_HOME nor scrub.
        // Scrubbing while skipping the pin would be self-inconsistent (and would key the
        // auth check off a DIFFERENT home than the pin via hasVerifiedChatGPTAuth's
        // fallback). Honor the documented invariant: unresolvable home => no pin, no scrub.
        guard let home = resolvedHome else { return patch }
        patch.set["CODEX_HOME"] = "\(home)/.codex"
        if Self.hasVerifiedChatGPTAuth(home: home) {
            patch.remove.insert("OPENAI_API_KEY")
        }
        return patch
    }

    /// True iff `~/.codex/auth.json` is a verified ChatGPT-plan login: `auth_mode ==
    /// "chatgpt"` AND a non-empty `tokens.access_token` or `tokens.refresh_token`.
    /// `fileLoader` is injectable for tests.
    static func hasVerifiedChatGPTAuth(
        home: String?,
        fileLoader: ((URL) -> Data?)? = nil
    ) -> Bool {
        let url: URL = {
            if let home, home.hasPrefix("/") {
                return URL(fileURLWithPath: home).appendingPathComponent(".codex/auth.json")
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        }()
        let load = fileLoader ?? { try? Data(contentsOf: $0) }
        guard let data = load(url),
              let outer = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        guard (outer["auth_mode"] as? String)?.lowercased() == "chatgpt" else { return false }
        // Reuse CodexQuotaFetcher's flat/nested tokens.access_token reader.
        if CodexQuotaFetcher.extractAccessToken(from: outer) != nil { return true }
        if let tokens = outer["tokens"] as? [String: Any],
           let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty {
            return true
        }
        return false
    }

    /// "on_plan" when a verified ChatGPT login exists (the scrub fires → runs on the
    /// plan); "off_plan" when an api-key/other login means codex would bill the API;
    /// "unknown" when the home is unresolvable. Lets the picker warn before silently
    /// launching a billed session.
    public func planAuthStatus(resolvedHome: String?) -> String {
        guard resolvedHome != nil else { return "unknown" }
        return Self.hasVerifiedChatGPTAuth(home: resolvedHome) ? "on_plan" : "off_plan"
    }
}
