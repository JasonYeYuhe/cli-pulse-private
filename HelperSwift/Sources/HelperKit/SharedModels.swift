import Foundation

/// Shared data models used across HelperKit collector modules. Slice 1
/// (Phase 4E) introduces the minimal `CollectedSession` shape so the
/// `GitCollector`'s `GitProjectPaths.extract` helper can compile
/// standalone. Slice 2 (the `SystemCollector` port) expands the same
/// struct additively with the full session shape: pid, cpuPercent,
/// etimeSeconds, and so on.
///
/// Adding fields is non-breaking under `Codable`'s synthesized
/// implementation as long as the new fields are `Optional` (or have
/// a sensible default at decode), so existing snapshot files written
/// by older Python helpers parse cleanly during the upgrade window.
public struct CollectedSession: Codable, Sendable, Equatable {

    /// Stable opaque session identifier. The macOS app uses this as
    /// the row key on the Sessions tab.
    public let sessionId: String

    /// Provider name as reported by the system collector — `"claude"`,
    /// `"codex"`, `"gemini"`, etc. Slice 2 sets this; Slice 1's
    /// `GitProjectPaths.extract` ignores it.
    public let provider: String

    /// Absolute path of the project root the session is rooted at.
    /// `nil` when the session is not bound to a project (e.g., a
    /// REPL launched without `--cwd`, or the helper's self-test
    /// session). `GitProjectPaths.extract` skips `nil` entries.
    public let projectRoot: URL?

    /// Wire-shape parity with the Python `system_collector.py` payload:
    /// snake_case keys cross both the Supabase RPC envelope AND the
    /// snapshot files the macOS app reads. Without explicit `CodingKeys`,
    /// Swift's synthesized `Codable` would emit camelCase, breaking the
    /// contract. Pinned in `GitCollectorTests` indirectly (via JSON
    /// fixtures) and explicitly in Slice 2's snapshot parity tests.
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case provider
        case projectRoot = "project_root"
    }

    public init(sessionId: String, provider: String, projectRoot: URL?) {
        self.sessionId = sessionId
        self.provider = provider
        self.projectRoot = projectRoot
    }
}
