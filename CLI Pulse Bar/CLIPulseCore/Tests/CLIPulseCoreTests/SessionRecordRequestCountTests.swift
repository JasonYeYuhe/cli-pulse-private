import XCTest
@testable import CLIPulseCore

/// Pin `SessionRecord.hasMeaningfulRequestCount` so the macOS / iOS
/// row code keeps gating the requests metric for unreliable Codex
/// JSONL synthesis. See the property's doc comment for the
/// underlying CostUsageScanner issue.
final class SessionRecordRequestCountTests: XCTestCase {
    private func make(id: String, requests: Int) -> SessionRecord {
        SessionRecord(
            id: id,
            name: "x",
            provider: "Codex",
            project: "x",
            device_name: "Mac",
            started_at: "2026-05-05T00:00:00Z",
            last_active_at: "2026-05-05T00:00:00Z",
            status: "running",
            total_usage: 26_300_000,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: requests,
            error_count: 0
        )
    }

    func test_hides_requests_for_jsonl_codex_with_floor_value() {
        // synthesizeSessions does `requests = max(1, c.messageCount)`
        // and Codex always falls through to messageCount=0, so the
        // value is always 1. Hide it.
        let s = make(id: "jsonl-codex-abc", requests: 1)
        XCTAssertFalse(s.hasMeaningfulRequestCount)
    }

    func test_keeps_requests_for_jsonl_codex_above_floor() {
        // If the scanner ever surfaces a real count > 1, show it.
        // (Defensive — current code can't produce >1 for Codex, but
        // the predicate shouldn't lie if a future fix lands.)
        let s = make(id: "jsonl-codex-abc", requests: 5)
        XCTAssertTrue(s.hasMeaningfulRequestCount)
    }

    func test_keeps_requests_for_jsonl_claude() {
        // Claude JSONL synthesis counts assistant messages correctly.
        let s = make(id: "jsonl-claude-abc", requests: 1)
        XCTAssertTrue(s.hasMeaningfulRequestCount)
    }

    func test_hides_requests_for_helper_process_row() {
        // Helper proc-{pid} rows compute requests via a duration
        // heuristic (`elapsed_seconds // 45`). Earlier this property
        // returned true for them; the post-PR-#14 behavior is to
        // return false because the proc-row's `requests` is meaningless
        // and produces nonsense like "86038 requests" on a long-running
        // session. The full hide is gated by `hasProcessHeuristicMetrics`
        // on the row, which `hasMeaningfulRequestCount` defers to.
        let s = make(id: "proc-12345", requests: 1)
        XCTAssertFalse(s.hasMeaningfulRequestCount)
    }

    func test_keeps_requests_for_cloud_row_without_jsonl_prefix() {
        // Cloud-uploaded row from another device — trust the uploader.
        let s = make(id: "uuid-from-other-device", requests: 1)
        XCTAssertTrue(s.hasMeaningfulRequestCount)
    }

    // MARK: - hasProcessHeuristicMetrics

    func test_proc_row_flagged_as_heuristic_metrics() {
        let s = make(id: "proc-12345", requests: 86038)
        XCTAssertTrue(s.hasProcessHeuristicMetrics)
        // Heuristic metrics also mean we should hide the request
        // count regardless of value.
        XCTAssertFalse(s.hasMeaningfulRequestCount)
    }

    func test_jsonl_row_not_flagged_as_heuristic_metrics() {
        let s = make(id: "jsonl-claude-abc", requests: 100)
        XCTAssertFalse(s.hasProcessHeuristicMetrics)
        XCTAssertTrue(s.hasMeaningfulRequestCount)
    }

    func test_cloud_row_not_flagged_as_heuristic_metrics() {
        let s = make(id: "uuid-other-device", requests: 50)
        XCTAssertFalse(s.hasProcessHeuristicMetrics)
    }

    // MARK: - displayName

    func test_proc_row_with_project_uses_provider_dot_project() {
        let s = SessionRecord(
            id: "proc-6168",
            name: "/Users/jason/Library/Application Support/Claude/...",
            provider: "Claude",
            project: "Library",
            device_name: "Mac",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: "2026-05-05T03:54:00Z",
            status: "Running",
            total_usage: 5_800_000,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 86038,
            error_count: 0
        )
        XCTAssertEqual(s.displayName, "Claude · Library")
    }

    func test_proc_row_with_blank_project_uses_provider_process() {
        let s = SessionRecord(
            id: "proc-1",
            name: "/some/long/path/to/binary --flags",
            provider: "Codex",
            project: "",
            device_name: "Mac",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: "2026-05-05T03:54:00Z",
            status: "Running",
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 1,
            error_count: 0
        )
        XCTAssertEqual(s.displayName, "Codex process")
    }

    func test_jsonl_row_keeps_existing_friendly_name() {
        let s = SessionRecord(
            id: "jsonl-claude-abc",
            name: "Claude session",
            provider: "Claude",
            project: "Documents-cli-pulse",
            device_name: "Mac",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: "2026-05-05T03:54:00Z",
            status: "Running",
            total_usage: 1000,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 5,
            error_count: 0
        )
        XCTAssertEqual(s.displayName, "Claude session",
                       "JSONL synthesized rows already have a friendly name; don't overwrite")
    }

    func test_cloud_row_keeps_existing_name() {
        let s = SessionRecord(
            id: "some-uuid-from-other-device",
            name: "Codex on Linux",
            provider: "Codex",
            project: "/proj",
            device_name: "ubuntu-vm",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: "2026-05-05T03:54:00Z",
            status: "Running",
            total_usage: 1000,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 5,
            error_count: 0
        )
        XCTAssertEqual(s.displayName, "Codex on Linux")
    }
}
