#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ClaudePTYProbeThrottleTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func snap() -> ClaudeSnapshot { ClaudeSnapshot(sessionUsed: 13, sourceLabel: "cli-pty") }

    func test_initial_decision_is_proceed() async {
        let t = ClaudePTYProbeThrottle(ttl: 300, baseBackoff: 120, maxBackoff: 900)
        guard case .proceed = await t.decide(now: t0) else { return XCTFail("expected proceed") }
    }

    func test_caches_within_ttl_then_proceeds_after_expiry() async {
        let t = ClaudePTYProbeThrottle(ttl: 300, baseBackoff: 120, maxBackoff: 900)
        await t.recordSuccess(snap(), at: t0)
        guard case .useCached(let s) = await t.decide(now: t0.addingTimeInterval(299)) else {
            return XCTFail("expected useCached within TTL")
        }
        XCTAssertEqual(s.sessionUsed, 13)
        guard case .proceed = await t.decide(now: t0.addingTimeInterval(301)) else {
            return XCTFail("expected proceed after TTL expiry")
        }
    }

    func test_backoff_grows_exponentially() async {
        let t = ClaudePTYProbeThrottle(ttl: 300, baseBackoff: 120, maxBackoff: 900)
        await t.recordFailure(at: t0)  // failure #1 → 120s window
        guard case .backoff(let r) = await t.decide(now: t0.addingTimeInterval(60)) else {
            return XCTFail("expected backoff after 1 failure")
        }
        XCTAssertEqual(r, 60, accuracy: 1)
        guard case .proceed = await t.decide(now: t0.addingTimeInterval(121)) else {
            return XCTFail("expected proceed after 120s window")
        }

        await t.recordFailure(at: t0.addingTimeInterval(121))  // failure #2 → 240s window
        guard case .backoff = await t.decide(now: t0.addingTimeInterval(121 + 200)) else {
            return XCTFail("expected 240s backoff after 2 failures")
        }
        guard case .proceed = await t.decide(now: t0.addingTimeInterval(121 + 241)) else {
            return XCTFail("expected proceed after 240s window")
        }
    }

    func test_backoff_caps_at_max() async {
        let t = ClaudePTYProbeThrottle(ttl: 300, baseBackoff: 120, maxBackoff: 900)
        for i in 0..<10 { await t.recordFailure(at: t0.addingTimeInterval(Double(i))) }
        // last failure at t0+9; uncapped window would be enormous, must cap at 900.
        guard case .backoff(let r) = await t.decide(now: t0.addingTimeInterval(9 + 800)) else {
            return XCTFail("expected capped backoff")
        }
        XCTAssertLessThanOrEqual(r, 900)
        guard case .proceed = await t.decide(now: t0.addingTimeInterval(9 + 901)) else {
            return XCTFail("expected proceed after the 900s cap")
        }
    }

    func test_success_resets_backoff_and_takes_priority() async {
        let t = ClaudePTYProbeThrottle(ttl: 300, baseBackoff: 120, maxBackoff: 900)
        await t.recordFailure(at: t0)
        await t.recordSuccess(snap(), at: t0.addingTimeInterval(10))
        guard case .useCached = await t.decide(now: t0.addingTimeInterval(20)) else {
            return XCTFail("a success must cache and clear the failure backoff")
        }
        // After the cache expires, failures are cleared → proceed, not backoff.
        guard case .proceed = await t.decide(now: t0.addingTimeInterval(311)) else {
            return XCTFail("expected proceed (failures cleared) once cache expired")
        }
    }
}
#endif
