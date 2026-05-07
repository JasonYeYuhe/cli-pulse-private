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

    /// Display name for the Sessions panel — typically a compacted
    /// version of `command` truncated to 48 chars. `nil` until Slice 2a
    /// fills it during process row → session conversion.
    public let name: String?

    /// Provider name as reported by the system collector. **Capitalized
    /// human-readable form** matching Python's `PROCESS_PATTERNS` first
    /// tuple element: `"Claude"`, `"Codex"`, `"Gemini"`, `"Cursor"`,
    /// `"OpenCode"`, etc. NOT lowercase — the macOS app keys on the
    /// exact string.
    public let provider: String

    /// Display name for the project (basename of `projectRoot`, or the
    /// inferred fallback). `nil` when not derivable from the command line.
    public let project: String?

    /// Lifecycle status as displayed in the Sessions panel. Slice 2a
    /// always emits `"Running"` for live processes (matches Python).
    public let status: String?

    /// Heuristic usage estimate: `max(500, elapsed_seconds *
    /// max(1.5, cpu + 1.0))`. Stable across re-collections of the same
    /// long-running process so the chart doesn't flicker.
    public let totalUsage: Int?

    /// Heuristic request count: `max(1, elapsed_seconds // 45)` —
    /// approximates a request every 45 s. Stable across re-collections.
    public let requests: Int?

    /// Always 0 in Slice 2a; populated by Slice 2b's AlertGenerator
    /// when it correlates session lifecycle with error events.
    public let errorCount: Int?

    /// ISO-8601 absolute start time, derived from `now() - elapsed`
    /// where elapsed is parsed from `ps`'s `etime` column.
    public let startedAt: String?

    /// ISO-8601 timestamp of the most recent collection cycle; the
    /// macOS app shows this as "active 30 s ago".
    public let lastActiveAt: String?

    /// Optional exact cost (USD) when known from a quota fetcher;
    /// `nil` for the heuristic-only Slice 2a path.
    public let exactCost: Double?

    /// Live CPU% as reported by `ps -o pcpu`. Used by the Sessions
    /// panel to render the in-row activity dot.
    public let cpuUsage: Double?

    /// The raw `ps` command line, redacted by the uploader before
    /// being sent to Supabase. Slice 2a stores it verbatim; Slice 2c's
    /// snapshot writer is responsible for redaction.
    public let command: String?

    /// Provider-detection confidence: `"high"`, `"medium"`, `"low"`.
    /// Drives dedup tie-breaking — multiple processes for the same
    /// provider+project are merged with the highest-confidence row
    /// becoming the primary representative.
    public let collectionConfidence: String?

    /// HMAC-SHA256(secret, utf8(absolute_project_path)) hex.
    /// Same scheme as `GitCollector.computeProjectHashHex`; pinned by
    /// the parity harness against Python's `user_secret.project_hash`.
    /// `nil` when `projectRoot` couldn't be inferred from the command.
    public let projectHash: String?

    /// Absolute path of the project root the session is rooted at.
    /// `nil` when the session is not bound to a project (e.g., a
    /// REPL launched without `--cwd`, or the helper's self-test
    /// session). `GitProjectPaths.extract` skips `nil` entries.
    /// **Privacy invariant:** this field is local-only — the snapshot
    /// writer in Slice 2c MUST drop it before uploading to Supabase
    /// (only `projectHash` is uploaded).
    public let projectRoot: URL?

    /// Wire-shape parity with the Python `system_collector.py` payload:
    /// snake_case keys cross both the Supabase RPC envelope AND the
    /// snapshot files the macOS app reads. Without explicit `CodingKeys`,
    /// Swift's synthesized `Codable` would emit camelCase, breaking the
    /// contract. Pinned by Slice 2's parity harness.
    private enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case name
        case provider
        case project
        case status
        case totalUsage = "total_usage"
        case requests
        case errorCount = "error_count"
        case startedAt = "started_at"
        case lastActiveAt = "last_active_at"
        case exactCost = "exact_cost"
        case cpuUsage = "cpu_usage"
        case command
        case collectionConfidence = "collection_confidence"
        case projectHash = "project_hash"
        case projectRoot = "project_root"
    }

    /// Slice 1 minimal init — kept for `GitProjectPaths.extract` and
    /// callers that only need the project root. All new Slice 2a fields
    /// default to `nil`, so the wire shape matches Python's "key present
    /// but value null" only for the Slice 1 callers; Slice 2a's
    /// `SessionDetector` uses the full init below.
    public init(sessionId: String, provider: String, projectRoot: URL?) {
        self.init(
            sessionId: sessionId,
            name: nil,
            provider: provider,
            project: nil,
            status: nil,
            totalUsage: nil,
            requests: nil,
            errorCount: nil,
            startedAt: nil,
            lastActiveAt: nil,
            exactCost: nil,
            cpuUsage: nil,
            command: nil,
            collectionConfidence: nil,
            projectHash: nil,
            projectRoot: projectRoot
        )
    }

    /// Slice 2a full init — used by `SessionDetector.collectSessions`.
    public init(
        sessionId: String,
        name: String?,
        provider: String,
        project: String?,
        status: String?,
        totalUsage: Int?,
        requests: Int?,
        errorCount: Int?,
        startedAt: String?,
        lastActiveAt: String?,
        exactCost: Double?,
        cpuUsage: Double?,
        command: String?,
        collectionConfidence: String?,
        projectHash: String?,
        projectRoot: URL?
    ) {
        self.sessionId = sessionId
        self.name = name
        self.provider = provider
        self.project = project
        self.status = status
        self.totalUsage = totalUsage
        self.requests = requests
        self.errorCount = errorCount
        self.startedAt = startedAt
        self.lastActiveAt = lastActiveAt
        self.exactCost = exactCost
        self.cpuUsage = cpuUsage
        self.command = command
        self.collectionConfidence = collectionConfidence
        self.projectHash = projectHash
        self.projectRoot = projectRoot
    }
}

/// Snapshot of host CPU + memory utilization at one collection tick.
/// Mirrors `helper/system_collector.py::DeviceSnapshot`. Both fields
/// are integer percentages clamped to 0…100; the JSON wire shape is
/// `{"cpu_usage": int, "memory_usage": int}`.
public struct DeviceSnapshot: Codable, Sendable, Equatable {

    /// CPU utilization, 0…100. Derived from 1-minute load average
    /// divided by the host's logical CPU count, capped at 100.
    /// Returns 0 if the load average can't be read.
    public let cpuUsage: Int

    /// Memory utilization, 0…100. Derived from `vm_stat` page counts:
    /// `(active + wired + compressed) / (free + speculative + active +
    /// wired + compressed + inactive)`. Returns 0 on parse failure.
    public let memoryUsage: Int

    private enum CodingKeys: String, CodingKey {
        case cpuUsage = "cpu_usage"
        case memoryUsage = "memory_usage"
    }

    public init(cpuUsage: Int, memoryUsage: Int) {
        self.cpuUsage = cpuUsage
        self.memoryUsage = memoryUsage
    }
}
