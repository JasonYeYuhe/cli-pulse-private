#if os(iOS) || os(visionOS)
import XCTest
@testable import CLIPulseCore

/// Pins the jittered exponential backoff curve for the v1.25
/// Phase 4 slice 4 auto-reconnect path (Codex M1). The
/// `Coordinator.computeBackoff` static is the testable surface —
/// the Task-driven reconnect timer + WS subscription state machine
/// aren't unit-testable without a live broker.
final class RemoteTerminalReconnectTests: XCTestCase {

    typealias C = RemoteTerminalViewRepresentable.Coordinator

    // MARK: - happy path (deterministic jitter)

    /// First failure: ~0.5 s base, +0...+0.125 s jitter (25%).
    func test_computeBackoff_attempt0_no_jitter_is_base() {
        let d = C.computeBackoff(attempt: 0, random: { 0.0 })
        XCTAssertEqual(d, 0.5, accuracy: 0.0001)
    }

    func test_computeBackoff_attempt0_max_jitter_is_base_plus_25pct() {
        let d = C.computeBackoff(attempt: 0, random: { 1.0 })
        XCTAssertEqual(d, 0.625, accuracy: 0.0001)
    }

    func test_computeBackoff_doubles_each_attempt_unjittered() {
        // Attempt 1: 1.0 s. Attempt 2: 2.0 s. Attempt 3: 4.0 s. …
        XCTAssertEqual(C.computeBackoff(attempt: 1, random: { 0.0 }), 1.0, accuracy: 0.0001)
        XCTAssertEqual(C.computeBackoff(attempt: 2, random: { 0.0 }), 2.0, accuracy: 0.0001)
        XCTAssertEqual(C.computeBackoff(attempt: 3, random: { 0.0 }), 4.0, accuracy: 0.0001)
        XCTAssertEqual(C.computeBackoff(attempt: 4, random: { 0.0 }), 8.0, accuracy: 0.0001)
    }

    // MARK: - cap

    /// Once unjittered exceeds the cap, clamp at the cap. Jitter
    /// is taken AFTER clamping so the worst-case wait stays ≤ cap
    /// * (1 + jitterPercent).
    func test_computeBackoff_caps_at_10s_default() {
        // 2^5 * 0.5 = 16, clamps to 10.
        let d = C.computeBackoff(attempt: 5, random: { 0.0 })
        XCTAssertEqual(d, 10.0, accuracy: 0.0001)
    }

    func test_computeBackoff_cap_with_full_jitter_is_cap_times_125pct() {
        let d = C.computeBackoff(attempt: 5, random: { 1.0 })
        XCTAssertEqual(d, 12.5, accuracy: 0.0001)
    }

    /// Defends against attempt overflow. attempt=10_000 must not
    /// produce inf / NaN; it must clamp the same way.
    func test_computeBackoff_huge_attempt_stays_capped() {
        let d = C.computeBackoff(attempt: 10_000, random: { 0.0 })
        XCTAssertEqual(d, 10.0, accuracy: 0.0001)
        let dWithJitter = C.computeBackoff(attempt: 10_000, random: { 1.0 })
        XCTAssertEqual(dWithJitter, 12.5, accuracy: 0.0001)
    }

    // MARK: - clamping for negative attempts (defensive)

    func test_computeBackoff_negative_attempt_treated_as_zero() {
        // A caller bug that decrements past zero shouldn't produce
        // a NaN / negative wait. Clamp at attempt=0 → base.
        let d = C.computeBackoff(attempt: -1, random: { 0.0 })
        XCTAssertEqual(d, 0.5, accuracy: 0.0001)
    }

    // MARK: - jitter properties

    /// Jitter must NEVER produce a negative delay. A negative
    /// `Task.sleep` would either trap or sleep zero, both wrong.
    func test_computeBackoff_jitter_never_produces_negative_delay() {
        for attempt in 0...10 {
            let d = C.computeBackoff(attempt: attempt, random: { 0.0 })
            XCTAssertGreaterThan(d, 0.0,
                                 "attempt \(attempt) produced non-positive delay \(d)")
        }
    }

    /// With max-jitter randomness, delay never exceeds
    /// `cap * (1 + jitterPercent)`. Pins the upper bound the
    /// worst-case caller (server reset firehose) sees.
    func test_computeBackoff_worst_case_bounded_by_cap_times_1_plus_jitter() {
        let cap = 10.0
        let jitter = 0.25
        let worstCase = cap * (1.0 + jitter)
        for attempt in 0...30 {
            let d = C.computeBackoff(
                attempt: attempt,
                cap: cap, jitterPercent: jitter,
                random: { 1.0 }
            )
            XCTAssertLessThanOrEqual(d, worstCase + 0.0001,
                                     "attempt \(attempt) exceeded worst-case bound: \(d)")
        }
    }

    /// Custom params: base=1s, cap=30s, jitter=10%. attempt=3 →
    /// unjittered = 8.0, +0...+0.8 jitter.
    func test_computeBackoff_respects_custom_base_cap_jitter() {
        let d = C.computeBackoff(
            attempt: 3,
            base: 1.0, cap: 30.0, jitterPercent: 0.1,
            random: { 0.5 }
        )
        XCTAssertEqual(d, 8.0 + 8.0 * 0.05, accuracy: 0.0001)
    }
}
#endif
