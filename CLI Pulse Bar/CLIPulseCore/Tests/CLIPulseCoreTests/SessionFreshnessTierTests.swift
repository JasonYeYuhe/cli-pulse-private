import XCTest
@testable import CLIPulseCore

/// Pin the Active/Recent tier classification used by the macOS / iOS
/// Sessions tab section split. Coexists with the existing
/// `SessionFreshnessFilterTests` — `filterCurrent` still drops the
/// same rows the new tier classifier marks `.hidden`, so the cloud
/// filter contract is unchanged.
final class SessionFreshnessTierTests: XCTestCase {
    private typealias C = SessionFreshnessTierClassifier
    private let isoFormatter = ISO8601DateFormatter()

    /// Use a fixed "now" so ISO8601 second-truncation is deterministic.
    /// A `Date()`-derived now would have sub-second drift that pushes
    /// boundary cases just past the window after a string round-trip.
    private let referenceNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func make(
        id: String,
        name: String = "Claude · cli-pulse",
        device: String = "MacBook Pro",
        ageSeconds: TimeInterval,
        now: Date,
        status: String = "running"
    ) -> SessionRecord {
        let lastActive = now.addingTimeInterval(-ageSeconds)
        return SessionRecord(
            id: id,
            name: name,
            provider: "Claude",
            project: "cli-pulse",
            device_name: device,
            started_at: isoFormatter.string(from: lastActive),
            last_active_at: isoFormatter.string(from: lastActive),
            status: status,
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 0,
            error_count: 0
        )
    }

    // MARK: - process-confirmed sessions

    func test_process_session_within_window_is_activeProcess() {
        let now = referenceNow
        let s = make(id: "proc-12345", ageSeconds: 30, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    func test_process_session_at_exact_window_is_activeProcess() {
        let now = referenceNow
        // 180s window — boundary inclusive.
        let s = make(id: "proc-12345", ageSeconds: 180, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeProcess)
    }

    func test_process_session_past_window_is_hidden_not_recent() {
        // Process-confirmed evidence becomes meaningless once the
        // helper has stopped refreshing — don't demote to Recent
        // (which is a JSONL-only signal), just hide.
        let now = referenceNow
        let s = make(id: "proc-12345", ageSeconds: 200, now: now)
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - JSONL-synthesized sessions

    func test_jsonl_session_under_5min_is_activeJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 60, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeJsonl)
    }

    func test_jsonl_session_at_exact_5min_is_activeJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 300, now: now)
        XCTAssertEqual(C.classify(s, now: now), .activeJsonl)
    }

    func test_jsonl_session_between_5min_and_30min_is_recentJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 600, now: now)
        XCTAssertEqual(C.classify(s, now: now), .recentJsonl)
    }

    func test_jsonl_session_at_exact_30min_is_recentJsonl() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 1800, now: now)
        XCTAssertEqual(C.classify(s, now: now), .recentJsonl)
    }

    func test_jsonl_session_past_30min_is_hidden() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-abc", ageSeconds: 1801, now: now)
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - cloud rows from other devices (no prefix)

    func test_cloud_row_without_prefix_uses_jsonl_age_tiers() {
        // Cloud sessions uploaded by other devices may not carry the
        // `proc-` / `jsonl-` prefix. Treat them as JSONL-equivalent —
        // we don't know whether a remote process is alive, only what
        // Supabase last persisted.
        let now = referenceNow
        let id = "cloud-uuid-from-other-device"
        let fresh = make(id: id, ageSeconds: 60, now: now)
        let stale = make(id: id, ageSeconds: 600, now: now)
        let dropped = make(id: id, ageSeconds: 2000, now: now)
        XCTAssertEqual(C.classify(fresh, now: now), .activeJsonl)
        XCTAssertEqual(C.classify(stale, now: now), .recentJsonl)
        XCTAssertEqual(C.classify(dropped, now: now), .hidden)
    }

    // MARK: - artifacts always hidden, even with proc- prefix

    func test_application_path_artifact_hidden_regardless_of_age() {
        let now = referenceNow
        let s = make(
            id: "proc-12345",
            name: "/Applications/Claude.app/Contents/MacOS/Claude",
            ageSeconds: 30,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_node_no_warnings_artifact_hidden() {
        let now = referenceNow
        let s = make(
            id: "proc-99",
            name: "node --no-warnings /usr/local/lib/codex/cli.js",
            ageSeconds: 5,
            now: now
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - garbage / future timestamp

    func test_unparseable_last_active_is_hidden() {
        let now = referenceNow
        let s = SessionRecord(
            id: "proc-1",
            name: "Claude",
            provider: "Claude",
            project: "x",
            device_name: "Mac",
            started_at: "not-a-timestamp",
            last_active_at: "also-bad",
            status: "running",
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 0,
            error_count: 0
        )
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_future_last_active_is_hidden() {
        let now = referenceNow
        // Negative age = clock skew on the helper. Don't trust.
        let s = make(id: "proc-1", ageSeconds: -10, now: now)
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    // MARK: - partition()

    func test_partition_bins_active_and_recent_correctly() {
        let now = referenceNow
        let activeProc = make(id: "proc-1", ageSeconds: 30, now: now)
        let activeJsonl = make(id: "jsonl-claude-a", ageSeconds: 100, now: now)
        let recentJsonl = make(id: "jsonl-claude-b", ageSeconds: 900, now: now)
        let hidden = make(id: "jsonl-claude-c", ageSeconds: 3600, now: now)
        let (active, recent) = C.partition(
            [hidden, recentJsonl, activeJsonl, activeProc],
            now: now
        )
        XCTAssertEqual(active.map(\.id), ["proc-1", "jsonl-claude-a"])
        XCTAssertEqual(recent.map(\.id), ["jsonl-claude-b"])
    }

    func test_partition_sorts_each_bucket_by_recency_desc() {
        let now = referenceNow
        let older = make(id: "proc-1", ageSeconds: 120, now: now)
        let newer = make(id: "proc-2", ageSeconds: 30, now: now)
        let (active, _) = C.partition([older, newer], now: now)
        XCTAssertEqual(active.map(\.id), ["proc-2", "proc-1"])
    }

    // MARK: - tier metadata

    func test_isVisible_matches_section_assignment() {
        XCTAssertTrue(FreshnessTier.activeProcess.isVisible)
        XCTAssertTrue(FreshnessTier.activeJsonl.isVisible)
        XCTAssertTrue(FreshnessTier.recentJsonl.isVisible)
        XCTAssertFalse(FreshnessTier.hidden.isVisible)
    }

    func test_section_assignment() {
        XCTAssertEqual(FreshnessTier.activeProcess.section, .active)
        XCTAssertEqual(FreshnessTier.activeJsonl.section, .active)
        XCTAssertEqual(FreshnessTier.recentJsonl.section, .recent)
        XCTAssertEqual(FreshnessTier.hidden.section, .hidden)
    }

    func test_badge_strings_are_short_and_distinct() {
        XCTAssertEqual(FreshnessTier.activeProcess.badge, "running")
        XCTAssertEqual(FreshnessTier.activeJsonl.badge,   "recent activity")
        XCTAssertEqual(FreshnessTier.recentJsonl.badge,   "recent")
        XCTAssertEqual(FreshnessTier.hidden.badge,        "")
    }

    // MARK: - intentional divergence from filterCurrent

    /// Documents that the classifier intentionally diverges from the
    /// older `filterCurrent` 300s rule:
    ///   * Process-confirmed rows are TIGHTER (180s) — helper refreshes
    ///     them every cycle, so a stale `proc-` row is genuinely dead.
    ///   * JSONL rows older than 300s are LOOSER — `filterCurrent`
    ///     drops them, the new tier system shows them in the Recent
    ///     section up to 30 min.
    /// `filterCurrent` itself is unchanged so the cloud merge route
    /// keeps its prior contract; the partition is the new surface.
    func test_classifier_diverges_from_filterCurrent_at_proc_180_to_300() {
        let now = referenceNow
        let s = make(id: "proc-1", ageSeconds: 200, now: now)
        // filterCurrent (300s window) keeps it…
        XCTAssertEqual(
            SessionFreshnessFilter.filterCurrent([s], now: now).count, 1
        )
        // …but the new tier classifier hides it (process window 180s).
        XCTAssertEqual(C.classify(s, now: now), .hidden)
    }

    func test_classifier_keeps_jsonl_past_filterCurrent_window() {
        let now = referenceNow
        let s = make(id: "jsonl-claude-a", ageSeconds: 600, now: now)
        // filterCurrent (300s window) drops it…
        XCTAssertEqual(
            SessionFreshnessFilter.filterCurrent([s], now: now).count, 0
        )
        // …but the new tier classifier surfaces it in the Recent
        // section.
        XCTAssertEqual(C.classify(s, now: now), .recentJsonl)
    }
}
