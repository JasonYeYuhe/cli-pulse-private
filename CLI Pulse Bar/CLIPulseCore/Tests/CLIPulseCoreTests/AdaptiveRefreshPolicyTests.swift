// Unit tests for the v1.40 PR-8 AdaptiveRefreshPolicy (CodexBar port). Locks the
// cadence table (2/5/15/30 min by menu-open age; LPM/thermal pins 30) and the
// "only re-arm if sooner" rule.

import XCTest
@testable import CLIPulseCore

final class AdaptiveRefreshPolicyTests: XCTestCase {
    private let policy = AdaptiveRefreshPolicy()
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func decide(ageMinutes: Double? = nil, lpm: Bool = false,
                        thermal: ProcessInfo.ThermalState = .nominal) -> AdaptiveRefreshPolicy.Decision {
        let last = ageMinutes.map { now.addingTimeInterval(-$0 * 60) }
        return policy.nextDelay(for: .init(now: now, lastMenuOpenAt: last,
                                           lowPowerModeEnabled: lpm, thermalState: thermal))
    }

    func test_recentInteraction_2min() {
        let d = decide(ageMinutes: 3)
        XCTAssertEqual(d.seconds, 120)
        XCTAssertEqual(d.reason, .recentInteraction)
    }

    func test_boundary_5min_is_recent() {
        XCTAssertEqual(decide(ageMinutes: 5).seconds, 120)     // ≤5 min → recent
    }

    func test_warm_5min() {
        let d = decide(ageMinutes: 30)
        XCTAssertEqual(d.seconds, 300)
        XCTAssertEqual(d.reason, .warm)
    }

    func test_boundary_60min_is_warm() {
        XCTAssertEqual(decide(ageMinutes: 60).seconds, 300)    // ≤60 min → warm
    }

    func test_idle_15min() {
        let d = decide(ageMinutes: 120)
        XCTAssertEqual(d.seconds, 900)
        XCTAssertEqual(d.reason, .idle)
    }

    func test_longIdle_30min_beyond_4h() {
        let d = decide(ageMinutes: 5 * 60)
        XCTAssertEqual(d.seconds, 1800)
        XCTAssertEqual(d.reason, .longIdle)
    }

    func test_boundary_4h_is_longIdle() {
        XCTAssertEqual(decide(ageMinutes: 4 * 60).seconds, 1800)   // age < 4h is idle, == 4h → longIdle
    }

    func test_never_opened_is_longIdle() {
        let d = decide(ageMinutes: nil)
        XCTAssertEqual(d.seconds, 1800)
        XCTAssertEqual(d.reason, .longIdle)
    }

    func test_lowPowerMode_pins_30min_even_when_recent() {
        let d = decide(ageMinutes: 1, lpm: true)
        XCTAssertEqual(d.seconds, 1800)
        XCTAssertEqual(d.reason, .constrained)
    }

    func test_thermal_serious_and_critical_pin_30min() {
        XCTAssertEqual(decide(ageMinutes: 1, thermal: .serious).reason, .constrained)
        XCTAssertEqual(decide(ageMinutes: 1, thermal: .critical).reason, .constrained)
        XCTAssertEqual(decide(ageMinutes: 1, thermal: .fair).reason, .recentInteraction)  // fair is NOT constrained
    }

    func test_future_timestamp_reads_as_recent() {
        let future = now.addingTimeInterval(60)
        let d = policy.nextDelay(for: .init(now: now, lastMenuOpenAt: future,
                                            lowPowerModeEnabled: false, thermalState: .nominal))
        XCTAssertEqual(d.reason, .recentInteraction)   // negative age → recent
    }

    // MARK: - shouldReArm ("only if sooner")

    func test_shouldReArm_no_pending_is_true() {
        XCTAssertTrue(AdaptiveRefreshPolicy.shouldReArm(candidateFire: now, pendingFire: nil))
    }

    func test_shouldReArm_sooner_true_later_false() {
        let pending = now.addingTimeInterval(60)
        XCTAssertTrue(AdaptiveRefreshPolicy.shouldReArm(candidateFire: now.addingTimeInterval(30), pendingFire: pending))
        XCTAssertFalse(AdaptiveRefreshPolicy.shouldReArm(candidateFire: now.addingTimeInterval(120), pendingFire: pending))
        XCTAssertFalse(AdaptiveRefreshPolicy.shouldReArm(candidateFire: pending, pendingFire: pending))  // equal → no
    }
}
