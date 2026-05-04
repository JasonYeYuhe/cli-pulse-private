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

    func test_keeps_requests_for_helper_process_row() {
        // Helper proc-{pid} rows compute requests via duration heuristic.
        let s = make(id: "proc-12345", requests: 1)
        XCTAssertTrue(s.hasMeaningfulRequestCount)
    }

    func test_keeps_requests_for_cloud_row_without_jsonl_prefix() {
        // Cloud-uploaded row from another device — trust the uploader.
        let s = make(id: "uuid-from-other-device", requests: 1)
        XCTAssertTrue(s.hasMeaningfulRequestCount)
    }
}
