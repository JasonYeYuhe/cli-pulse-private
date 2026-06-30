import Foundation

/// Registry of `ProviderSpawner`s keyed by canonical lower-case
/// provider name. Mirrors the Python helper's `_REGISTRY` dict in
/// `helper/provider_spawners/__init__.py`.
///
/// `ManagedSessionManager` looks up spawners by provider string at
/// `startSession` time. `LocalSessionServer` queries
/// `availableProviderNames()` at hello-reply build time to populate
/// the `provider_availability` field the iOS / macOS spawn picker
/// uses for menu gray-out.
public final class ProviderSpawnerRegistry: @unchecked Sendable {
    private let spawners: [String: ProviderSpawner]

    public init(spawners: [ProviderSpawner]) {
        var byName: [String: ProviderSpawner] = [:]
        for spawner in spawners {
            byName[spawner.name.lowercased()] = spawner
        }
        self.spawners = byName
    }

    /// Default registry — Claude / Codex / Gemini, all default
    /// configs. Production daemon main wires the Claude spawner
    /// with the inline-settings builder so structured approvals
    /// continue to fire for managed Claude sessions.
    public static func standard(
        buildClaudeInlineSettings: (@Sendable (String) -> String?)? = nil
    ) -> ProviderSpawnerRegistry {
        ProviderSpawnerRegistry(spawners: [
            ClaudeSpawner(buildInlineSettings: buildClaudeInlineSettings),
            CodexSpawner(),
            GeminiSpawner(),
        ])
    }

    /// Lookup. Case-insensitive, whitespace-trimmed. Returns nil
    /// for unknown providers so the caller can surface
    /// `unsupportedProvider` cleanly.
    public func spawner(for provider: String) -> ProviderSpawner? {
        let normalized = provider
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        return spawners[normalized]
    }

    /// All registered provider names (whether their binary is on
    /// PATH or not). Used for diagnostics.
    public func allProviderNames() -> [String] {
        spawners.keys.sorted()
    }

    /// Provider names whose binary is currently runnable. The UDS
    /// hello reply ships this list as `provider_availability` so
    /// the iOS / macOS picker can gray out items the helper can't
    /// actually launch.
    public func availableProviderNames() -> [String] {
        spawners
            .filter { $0.value.isAvailable() }
            .keys
            .sorted()
    }

    /// Per-provider plan-auth status ("on_plan" / "off_plan" / "unknown") for the
    /// AVAILABLE providers — shipped in the hello reply as `provider_plan_status` so the
    /// picker can warn before silently launching an off-plan (billed) session. Omits
    /// `"unknown"` so older/indeterminate providers don't add noise (absent ⇒ no warning).
    public func planAuthStatuses(resolvedHome: String?) -> [String: String] {
        var out: [String: String] = [:]
        for (name, spawner) in spawners where spawner.isAvailable() {
            let status = spawner.planAuthStatus(resolvedHome: resolvedHome)
            if status != "unknown" { out[name] = status }
        }
        return out
    }
}
