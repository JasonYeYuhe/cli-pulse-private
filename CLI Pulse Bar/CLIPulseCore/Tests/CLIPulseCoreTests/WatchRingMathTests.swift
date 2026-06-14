import XCTest
@testable import CLIPulseCore

/// Unit coverage for the watchOS redesign's pure quota-window math.
/// The watch app target is CI-only (no local build/run), so this is the
/// regression net that catches ring/legend math drift before CI.
final class WatchRingMathTests: XCTestCase {

    // MARK: - windowUsed

    func test_windowUsed_withQuota_isQuotaMinusRemaining() {
        XCTAssertEqual(WatchRingMath.windowUsed(quota: 100, remaining: 38, todayUsage: 0), 62)
    }

    func test_windowUsed_withQuota_ignoresTodayUsage() {
        // The whole point of window math: today_usage is 0 first thing in
        // the morning, but the rolling window can still be 62% consumed.
        XCTAssertEqual(WatchRingMath.windowUsed(quota: 100, remaining: 38, todayUsage: 0), 62)
    }

    func test_windowUsed_remainingExceedsQuota_clampsToZero() {
        // Defensive: a stale/over-credited remaining must never go negative.
        XCTAssertEqual(WatchRingMath.windowUsed(quota: 100, remaining: 140, todayUsage: 5), 0)
    }

    func test_windowUsed_noQuota_fallsBackToTodayUsage() {
        XCTAssertEqual(WatchRingMath.windowUsed(quota: nil, remaining: nil, todayUsage: 1234), 1234)
    }

    func test_windowUsed_quotaButNoRemaining_fallsBackToTodayUsage() {
        XCTAssertEqual(WatchRingMath.windowUsed(quota: 100, remaining: nil, todayUsage: 7), 7)
    }

    // MARK: - remainingFraction / remainingPercentInt

    func test_remainingFraction_isComplementOfUsage() {
        XCTAssertEqual(WatchRingMath.remainingFraction(usagePercent: 0.62), 0.38, accuracy: 1e-9)
    }

    func test_remainingFraction_clampsAboveOne() {
        // usagePercent < 0 would over-fill the remaining arc.
        XCTAssertEqual(WatchRingMath.remainingFraction(usagePercent: -0.2), 1.0, accuracy: 1e-9)
    }

    func test_remainingFraction_clampsBelowZero() {
        XCTAssertEqual(WatchRingMath.remainingFraction(usagePercent: 1.3), 0.0, accuracy: 1e-9)
    }

    func test_remainingPercentInt_truncatesLikeComplication() {
        // Int(0.385 * 100) == 38 (truncation, matching the complication's
        // Int(remaining * 100)). Both surfaces must show "38".
        XCTAssertEqual(WatchRingMath.remainingPercentInt(usagePercent: 0.615), 38)
        XCTAssertEqual(WatchRingMath.remainingPercentInt(usagePercent: 0.0), 100)
        XCTAssertEqual(WatchRingMath.remainingPercentInt(usagePercent: 1.0), 0)
    }

    // MARK: - tier (must match the shipped > 0.9 / > 0.7 boundaries)

    func test_tier_normalBelow70() {
        XCTAssertEqual(WatchRingMath.tier(usagePercent: 0.5), .normal)
    }

    func test_tier_boundaryAt70IsStillNormal() {
        // Strictly-greater boundary: exactly 0.70 is NOT yet warning,
        // matching the existing gauge code (`usagePercent > 0.7`).
        XCTAssertEqual(WatchRingMath.tier(usagePercent: 0.7), .normal)
    }

    func test_tier_warningAbove70() {
        XCTAssertEqual(WatchRingMath.tier(usagePercent: 0.71), .warning)
    }

    func test_tier_boundaryAt90IsStillWarning() {
        XCTAssertEqual(WatchRingMath.tier(usagePercent: 0.9), .warning)
    }

    func test_tier_criticalAbove90() {
        XCTAssertEqual(WatchRingMath.tier(usagePercent: 0.91), .critical)
    }

    // MARK: - ringProviders

    func test_ringProviders_filtersOutUnmetered() {
        let metered = makeProvider("Claude", quota: 100, remaining: 50)   // 50%
        let unmetered = makeProvider("Ollama", quota: nil, remaining: nil)
        let result = WatchRingMath.ringProviders([metered, unmetered])
        XCTAssertEqual(result.map(\.provider), ["Claude"])
    }

    func test_ringProviders_sortsMostConstrainedFirst() {
        let claude = makeProvider("Claude", quota: 100, remaining: 38)  // 62%
        let codex = makeProvider("Codex", quota: 100, remaining: 58)    // 42%
        let gemini = makeProvider("Gemini", quota: 100, remaining: 5)   // 95%
        let result = WatchRingMath.ringProviders([claude, codex, gemini])
        XCTAssertEqual(result.map(\.provider), ["Gemini", "Claude", "Codex"])
    }

    func test_ringProviders_capsAtLimit() {
        let providers = (0..<6).map { makeProvider("P\($0)", quota: 100, remaining: $0 * 10) }
        let result = WatchRingMath.ringProviders(providers, limit: 3)
        XCTAssertEqual(result.count, 3)
    }

    func test_ringProviders_tieBreaksOnNameForStability() {
        let b = makeProvider("Bravo", quota: 100, remaining: 50)   // 50%
        let a = makeProvider("Alpha", quota: 100, remaining: 50)   // 50%
        let result = WatchRingMath.ringProviders([b, a])
        XCTAssertEqual(result.map(\.provider), ["Alpha", "Bravo"])
    }

    func test_ringProviders_emptyInput() {
        XCTAssertTrue(WatchRingMath.ringProviders([]).isEmpty)
    }

    // MARK: - indexOfMostConstrained

    func test_indexOfMostConstrained_picksMax() {
        XCTAssertEqual(WatchRingMath.indexOfMostConstrained([0.2, 0.9, 0.5]), 1)
    }

    func test_indexOfMostConstrained_tieResolvesToLowestIndex() {
        XCTAssertEqual(WatchRingMath.indexOfMostConstrained([0.9, 0.9, 0.1]), 0)
    }

    func test_indexOfMostConstrained_emptyIsNil() {
        XCTAssertNil(WatchRingMath.indexOfMostConstrained([]))
    }

    // MARK: - Helpers

    private func makeProvider(_ name: String, quota: Int?, remaining: Int?) -> ProviderUsage {
        ProviderUsage(
            provider: name,
            today_usage: 0,
            week_usage: 0,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            cost_status_today: "Estimated",
            cost_status_week: "Estimated",
            quota: quota,
            remaining: remaining,
            status_text: "",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
    }
}
