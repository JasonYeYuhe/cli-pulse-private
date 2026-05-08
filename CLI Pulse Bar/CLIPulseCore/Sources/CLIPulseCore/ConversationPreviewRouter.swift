import Foundation

/// Dispatches conversation-preview formatting to the right per-provider
/// formatter for the Sessions tab on iOS / macOS. Added in v1.15 when
/// managed sessions gained Codex CLI and Gemini CLI support.
///
/// Why a dispatcher instead of a protocol with downcasts: each
/// formatter is a `public enum` with `static` methods (no instance
/// state, no init), which is the right shape for pure pipeline
/// transforms but doesn't fit a protocol cleanly. A small dispatcher
/// keeps the call sites in `SessionsTab.swift` / `iOSSessionsTab.swift`
/// to one line, and is easy to test against synthetic providers.
///
/// Provider strings come from `RemoteSession.provider` and match the
/// helper-side spawner registry in `helper/provider_spawners/`. The
/// dispatcher is permissive: an unknown provider falls back to the
/// Claude formatter (history bias — every shipped session before
/// v1.15 is `claude`) so a stale row from a future schema does not
/// blank out.
public enum ConversationPreviewRouter {
    /// Format event payloads for the given provider. Always returns a
    /// human-readable string suitable for `Text(...)`; never throws.
    public static func format(provider: String, eventPayloads: [String]) -> String {
        switch normalize(provider) {
        case "codex":
            return CodexConversationPreviewFormatter.format(eventPayloads: eventPayloads)
        case "gemini":
            return GeminiConversationPreviewFormatter.format(eventPayloads: eventPayloads)
        default:
            return ClaudeConversationPreviewFormatter.format(eventPayloads: eventPayloads)
        }
    }

    /// Per-provider empty fallback string. The Sessions tab compares
    /// the transcript against this to decide whether to render
    /// `Color.secondary` (still waiting) or `Color.primary` (real
    /// conversation surfaced).
    public static func emptyFallback(for provider: String) -> String {
        switch normalize(provider) {
        case "codex":
            return CodexConversationPreviewFormatter.emptyFallback
        case "gemini":
            return GeminiConversationPreviewFormatter.emptyFallback
        default:
            return ClaudeConversationPreviewFormatter.emptyFallback
        }
    }

    /// Per-provider header label for the Sessions tab. iOS used to
    /// hardcode "Claude conversation preview"; v1.15 promotes it to
    /// the active provider's name so the user is not confused by a
    /// Codex-routed session that says "Claude".
    public static func headerLabel(for provider: String) -> String {
        switch normalize(provider) {
        case "codex":  return "Codex conversation preview"
        case "gemini": return "Gemini conversation preview"
        default:       return "Claude conversation preview"
        }
    }

    private static func normalize(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
