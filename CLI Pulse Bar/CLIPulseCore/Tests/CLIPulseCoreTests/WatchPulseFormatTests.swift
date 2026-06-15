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

    // MARK: - weekToDateCost

    func test_weekToDateCost_sumsProviders() {
        let a = makeProvider(costWeek: 12.5)
        let b = makeProvider(costWeek: 0.63)
        let c = makeProvider(costWeek: 100.0)
        XCTAssertEqual(WatchPulseFormat.weekToDateCost([a, b, c]), 113.13, accuracy: 1e-9)
    }

    func test_weekToDateCost_emptyIsZero() {
        XCTAssertEqual(WatchPulseFormat.weekToDateCost([]), 0)
    }

    private func makeProvider(costWeek: Double) -> ProviderUsage {
        ProviderUsage(
            provider: "P", today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: costWeek,
            cost_status_today: "Estimated", cost_status_week: "Estimated",
            quota: nil, remaining: nil, status_text: "",
            trend: [], recent_sessions: [], recent_errors: []
        )
    }
}
