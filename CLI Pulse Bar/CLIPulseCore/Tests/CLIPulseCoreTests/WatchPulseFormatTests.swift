import XCTest
@testable import CLIPulseCore

/// Coverage for the Pulse-home pure helpers (watch app target is CI-only).
final class WatchPulseFormatTests: XCTestCase {

    // MARK: - activityLevel

    func test_activityLevel_zeroSessionsIsCalm() {
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: 0), 0.0, accuracy: 1e-9)
    }

    func test_activityLevel_saturatesAtCap() {
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: 5), 1.0, accuracy: 1e-9)
    }

    func test_activityLevel_clampsAboveCap() {
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: 50), 1.0, accuracy: 1e-9)
    }

    func test_activityLevel_linearBelowCap() {
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: 2, saturateAt: 4), 0.5, accuracy: 1e-9)
    }

    func test_activityLevel_negativeClampsToZero() {
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: -3), 0.0, accuracy: 1e-9)
    }

    func test_activityLevel_zeroCapDegradesGracefully() {
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: 1, saturateAt: 0), 1.0, accuracy: 1e-9)
        XCTAssertEqual(WatchPulseFormat.activityLevel(activeSessions: 0, saturateAt: 0), 0.0, accuracy: 1e-9)
    }

    // MARK: - abbreviatedCost

    func test_abbreviatedCost_largeDropsCents() {
        XCTAssertEqual(WatchPulseFormat.abbreviatedCost(146.03), "$146")
    }

    func test_abbreviatedCost_roundsToNearestDollar() {
        XCTAssertEqual(WatchPulseFormat.abbreviatedCost(146.7), "$147")
    }

    func test_abbreviatedCost_smallKeepsCents() {
        // Below $10 the full 2-dp string is preserved (matches CostFormatter).
        XCTAssertEqual(WatchPulseFormat.abbreviatedCost(9.6), "$9.60")
    }

    func test_abbreviatedCost_tinyUsesFloorString() {
        XCTAssertEqual(WatchPulseFormat.abbreviatedCost(0.004), "<$0.01")
    }

    func test_abbreviatedCost_boundaryAtTen() {
        // Exactly $10 abbreviates to whole dollars.
        XCTAssertEqual(WatchPulseFormat.abbreviatedCost(10.0), "$10")
    }
}
