import SwiftUI

/// Provider-aware display strings + glyphs for the Sessions UI.
/// Added in v1.15 (round-4 hardening) when the iOS user reported that
/// codex / gemini sessions still showed "Claude" everywhere — header,
/// row label, brain icon, orange provider color. Pre-v1.15 the entire
/// managed-sessions surface was Claude-only so hardcoding was fine;
/// v1.15 introduced multi-CLI but missed the rendering layer.
///
/// Usage from a SwiftUI row:
///
///     let label = session.client_label ?? ProviderDisplay.defaultLabel(for: session.provider)
///     Image(systemName: ProviderDisplay.iconSymbol(for: session.provider))
///         .foregroundStyle(ProviderDisplay.color(for: session.provider))
///     Text(label)
///
/// All accessors normalize the provider string (case-insensitive,
/// whitespace-trimmed) so "Claude" / "claude" / "  CLAUDE " all
/// resolve to the same surface.
public enum ProviderDisplay {
    /// Canonical display name. Pre-v1.15 callers passed `"Claude"`
    /// to `PulseTheme.providerColor`; this normalizer reuses that
    /// table so the orange/codex-blue/gemini-* palette stays in one
    /// place.
    public static func displayName(for provider: String) -> String {
        switch normalize(provider) {
        case "codex":  return "Codex"
        case "gemini": return "Gemini"
        default:       return "Claude"
        }
    }

    /// SF Symbol used for the provider's row glyph + the spawn-picker
    /// icon. Matches the picker (Claude=sparkles, Codex=chevron-slash,
    /// Gemini=diamond) so the same shape carries from picker → row →
    /// detail view.
    public static func iconSymbol(for provider: String) -> String {
        switch normalize(provider) {
        case "codex":  return "chevron.left.slash.chevron.right"
        case "gemini": return "diamond"
        default:       return "sparkles"
        }
    }

    /// Provider tint color. Delegates to `PulseTheme.providerColor`
    /// with the canonical capitalized name so the existing palette
    /// applies.
    public static func color(for provider: String) -> Color {
        PulseTheme.providerColor(displayName(for: provider))
    }

    /// Fallback used when the row's `client_label` is nil/empty.
    /// Pre-v1.15 every code path used the literal `"Claude session"`;
    /// post-v1.15 the fallback respects the provider.
    public static func defaultLabel(for provider: String) -> String {
        "\(displayName(for: provider)) session"
    }

    /// Section header for the managed-sessions list. Pre-v1.15 the UI
    /// hardcoded `"Managed Claude sessions"`. With multi-CLI shipping,
    /// the static header drops the provider name (it's unknown until
    /// the user picks one in the New menu).
    public static let managedSectionHeader = "Managed sessions"

    private static func normalize(_ provider: String) -> String {
        provider.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
