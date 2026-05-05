import XCTest
@testable import CLIPulseCore

/// Pin `sharedISO8601Parse` and `SessionRecord.lastActiveDate` so the
/// silent dropout of helper-uploaded `proc-*` rows can never come back.
///
/// The bug: helper/system_collector.py emits
/// `datetime.now(timezone.utc).isoformat()` which always carries
/// microsecond fractionals (`+00:00` form), e.g.
///   `2026-05-05T03:52:58.095452+00:00`
/// Swift's default `ISO8601DateFormatter()` (no
/// `withFractionalSeconds` option) returns `nil` on those inputs,
/// which made `SessionRecord.lastActiveDate` nil for every helper-
/// uploaded row, which `SessionFreshnessFilter.filterCurrent`
/// dropped via `guard let lastActive = … else { return false }`.
final class SharedISO8601ParseTests: XCTestCase {
    func test_parses_no_fractional_with_z() {
        XCTAssertNotNil(sharedISO8601Parse("2026-05-05T12:34:56Z"))
    }

    func test_parses_no_fractional_with_offset() {
        XCTAssertNotNil(sharedISO8601Parse("2026-05-05T12:34:56+00:00"))
    }

    /// The exact shape Python's `datetime.now(timezone.utc).isoformat()`
    /// produces — six fractional digits + `+00:00` offset. THIS is the
    /// case that pre-fix returned nil and dropped every helper row.
    func test_parses_python_isoformat_microseconds_with_offset() {
        XCTAssertNotNil(sharedISO8601Parse("2026-05-05T03:52:58.095452+00:00"))
    }

    func test_parses_milliseconds_with_z() {
        XCTAssertNotNil(sharedISO8601Parse("2026-05-05T12:34:56.789Z"))
    }

    func test_returns_nil_for_garbage() {
        XCTAssertNil(sharedISO8601Parse("not-a-timestamp"))
        XCTAssertNil(sharedISO8601Parse(""))
        XCTAssertNil(sharedISO8601Parse("2026-05-05"))
    }

    /// Ordering: a parsed fractional-second timestamp should be later
    /// than its no-fractional truncation by the fractional amount.
    /// This indirectly proves we're not just sometimes returning
    /// "nearly now" but actually decoding the fractional part.
    func test_fractional_is_strictly_later_than_truncated() {
        let withFrac = sharedISO8601Parse("2026-05-05T03:52:58.500000+00:00")
        let noFrac = sharedISO8601Parse("2026-05-05T03:52:58Z")
        XCTAssertNotNil(withFrac)
        XCTAssertNotNil(noFrac)
        XCTAssertGreaterThan(withFrac!, noFrac!)
        XCTAssertEqual(withFrac!.timeIntervalSince(noFrac!), 0.5, accuracy: 0.002)
    }

    // MARK: - SessionRecord property uses the robust parser

    private func makeSession(lastActive: String) -> SessionRecord {
        SessionRecord(
            id: "proc-12345",
            name: "/Users/jason/Library/Application Support/Claude/claude-code/2.1.121/claude.app/Contents/MacOS/claude --output-format stream-json",
            provider: "Claude",
            project: "cli pulse",
            device_name: "kanouuwas-macbook-pro.local",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: lastActive,
            status: "Running",
            total_usage: 0,
            estimated_cost: 0,
            cost_status: "Estimated",
            requests: 0,
            error_count: 0,
            collection_confidence: "high"
        )
    }

    func test_lastActiveDate_parses_helper_python_isoformat() {
        // Exact shape captured from `select last_active_at from sessions`
        // for proc-* rows the helper just uploaded.
        let s = makeSession(lastActive: "2026-05-05T03:54:28.134273+00:00")
        XCTAssertNotNil(s.lastActiveDate, "helper python isoformat must parse — pre-fix this returned nil and dropped every cloud row")
    }

    func test_lastActiveDate_parses_no_fractional() {
        let s = makeSession(lastActive: "2026-05-05T03:54:28Z")
        XCTAssertNotNil(s.lastActiveDate)
    }

    // MARK: - filterCurrent + classifier round-trip
    //
    // Use a `now` value that's within 5 minutes of the test's
    // `lastActive` strings, so we don't hand-calculate epochs.

    func test_filterCurrent_keeps_helper_uploaded_proc_row_with_fractional_timestamp() {
        let referenceNow = sharedISO8601Parse("2026-05-05T03:54:28Z")!  // ~90s after the timestamp below
        let session = makeSession(lastActive: "2026-05-05T03:52:58.095452+00:00")
        let kept = SessionFreshnessFilter.filterCurrent([session], now: referenceNow)
        XCTAssertEqual(kept.count, 1, "fractional-second helper row must survive filterCurrent")
    }

    func test_classifier_keeps_helper_uploaded_proc_row_with_fractional_timestamp() {
        let referenceNow = sharedISO8601Parse("2026-05-05T03:54:28Z")!
        let session = makeSession(lastActive: "2026-05-05T03:52:58.095452+00:00")
        let tier = SessionFreshnessTierClassifier.classify(session, now: referenceNow)
        XCTAssertEqual(tier, .activeProcess,
                       "Fresh proc-* row with helper-style fractional timestamp must classify as activeProcess")
    }

    func test_partition_includes_helper_uploaded_proc_row_in_active_section() {
        let referenceNow = sharedISO8601Parse("2026-05-05T03:54:28Z")!
        let session = makeSession(lastActive: "2026-05-05T03:52:58.095452+00:00")
        let buckets = SessionFreshnessTierClassifier.partition([session], now: referenceNow)
        XCTAssertEqual(buckets.active.count, 1)
        XCTAssertEqual(buckets.active.first?.id, "proc-12345")
        XCTAssertTrue(buckets.recent.isEmpty)
    }

    // MARK: - sort ordering survives mixed timestamp formats

    func test_merge_sort_orders_correctly_across_fractional_and_plain() {
        // Two rows: one helper-uploaded (fractional), one synthesized
        // (no fractional). The fractional one is more recent. The
        // sort must keep it first even though their formats differ.
        // Pre-fix the default formatter returned nil for fractional,
        // collapsing both to .distantPast and producing arbitrary
        // (insertion) order.
        let helperRow = SessionRecord(
            id: "proc-1", name: "x", provider: "Claude", project: "p",
            device_name: "Mac",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: "2026-05-05T03:54:28.500000+00:00",  // newer
            status: "Running", total_usage: 0, estimated_cost: 0,
            cost_status: "Estimated", requests: 0, error_count: 0
        )
        let jsonlRow = SessionRecord(
            id: "jsonl-claude-x", name: "y", provider: "Claude", project: "q",
            device_name: "Mac",
            started_at: "2026-05-05T03:50:00Z",
            last_active_at: "2026-05-05T03:54:00Z",                // older
            status: "Running", total_usage: 0, estimated_cost: 0,
            cost_status: "Estimated", requests: 0, error_count: 0
        )
        let merged = SessionFreshnessFilter.mergeCloudAndLocalSessions(
            cloudFresh: [helperRow], localFresh: [jsonlRow]
        )
        XCTAssertEqual(merged.first?.id, "proc-1",
                       "Newer fractional-second timestamp should sort before older plain")
    }
}
