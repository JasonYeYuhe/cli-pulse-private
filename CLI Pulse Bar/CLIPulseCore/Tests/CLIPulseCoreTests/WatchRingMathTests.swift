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

    // MARK: - per-tier quota/remaining math

    func test_tierRemainingFraction_isRemainingOverQuota() {
        XCTAssertEqual(WatchRingMath.remainingFraction(quota: 100, remaining: 38), 0.38, accuracy: 1e-9)
    }

    func test_tierUsagePercent_isUsedOverQuota() {
        XCTAssertEqual(WatchRingMath.usagePercent(quota: 100, remaining: 38), 0.62, accuracy: 1e-9)
    }

    func test_tierRemaining_complementsUsage() {
        let r = WatchRingMath.remainingFraction(quota: 200, remaining: 50)
        let u = WatchRingMath.usagePercent(quota: 200, remaining: 50)
        XCTAssertEqual(r + u, 1.0, accuracy: 1e-9)
    }

    func test_tierMath_zeroQuotaIsSafe() {
        XCTAssertEqual(WatchRingMath.remainingFraction(quota: 0, remaining: 0), 0)
        XCTAssertEqual(WatchRingMath.usagePercent(quota: 0, remaining: 5), 0)
    }

    func test_tierMath_overAndUnderClamp() {
        XCTAssertEqual(WatchRingMath.remainingFraction(quota: 100, remaining: 140), 1.0, accuracy: 1e-9)
        XCTAssertEqual(WatchRingMath.usagePercent(quota: 100, remaining: -10), 1.0, accuracy: 1e-9)
    }

    func test_tierRemainingPercentInt_truncates() {
        XCTAssertEqual(WatchRingMath.remainingPercentInt(quota: 100, remaining: 38), 38)
        XCTAssertEqual(WatchRingMath.remainingPercentInt(quota: 3, remaining: 1), 33)
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

    func test_ringProviders_ordersByCostThenUsage() {
        // Headline-first: the provider you spend the most on leads.
        let claude = makeProvider("Claude", quota: 100, remaining: 9, cost: 283.96)
        let codex = makeProvider("Codex", quota: 100, remaining: 20, cost: 0.63)
        let gemini = makeProvider("Gemini", quota: 100, remaining: 14, cost: 12.0)
        let result = WatchRingMath.ringProviders([claude, codex, gemini])
        XCTAssertEqual(result.map(\.provider), ["Claude", "Gemini", "Codex"])
    }

    func test_ringProviders_costTieBreaksOnUsage() {
        let a = makeProvider("Alpha", quota: 100, remaining: 50, cost: 5, usage: 100)
        let b = makeProvider("Bravo", quota: 100, remaining: 50, cost: 5, usage: 900)
        XCTAssertEqual(WatchRingMath.ringProviders([a, b]).map(\.provider), ["Bravo", "Alpha"])
    }

    func test_ringProviders_capsAtLimit() {
        let providers = (0..<6).map { makeProvider("P\($0)", quota: 100, remaining: $0 * 10) }
        let result = WatchRingMath.ringProviders(providers, limit: 3)
        XCTAssertEqual(result.count, 3)
    }

    func test_ringProviders_tieBreaksOnNameForStability() {
        // Equal cost + usage → stable alphabetical order.
        let b = makeProvider("Bravo", quota: 100, remaining: 50, cost: 5, usage: 10)
        let a = makeProvider("Alpha", quota: 100, remaining: 50, cost: 5, usage: 10)
        let result = WatchRingMath.ringProviders([b, a])
        XCTAssertEqual(result.map(\.provider), ["Alpha", "Bravo"])
    }

    func test_ringProviders_emptyInput() {
        XCTAssertTrue(WatchRingMath.ringProviders([]).isEmpty)
    }

    // MARK: - mostActive (most tokens used today, metered)

    func test_mostActive_picksHighestTodayUsage() {
        let claude = makeProvider("Claude", quota: 100, remaining: 91, usage: 5000)
        let codex = makeProvider("Codex", quota: 100, remaining: 20, usage: 1200)
        let gemini = makeProvider("Gemini", quota: 100, remaining: 86, usage: 9000)
        XCTAssertEqual(WatchRingMath.mostActive([claude, codex, gemini])?.provider, "Gemini")
    }

    func test_mostActive_ignoresUnmetered() {
        let metered = makeProvider("Claude", quota: 100, remaining: 50, usage: 10)
        let unmetered = makeProvider("Ollama", quota: nil, remaining: nil, usage: 999999)
        XCTAssertEqual(WatchRingMath.mostActive([unmetered, metered])?.provider, "Claude")
    }

    func test_mostActive_emptyIsNil() {
        XCTAssertNil(WatchRingMath.mostActive([]))
        XCTAssertNil(WatchRingMath.mostActive([makeProvider("Ollama", quota: nil, remaining: nil)]))
    }

    // MARK: - weeklyUsagePercent

    func test_weeklyUsagePercent_usesWeeklyTierByRole() {
        // Primary (5h) is 9% used; Weekly is 60% used → ring should track 60%.
        let p = makeProvider("Claude", quota: 100, remaining: 91, tiers: [
            TierDTO(name: "5h Window", quota: 100, remaining: 91, role: .primary),
            TierDTO(name: "Weekly", quota: 100, remaining: 40, role: .secondary),
        ])
        XCTAssertEqual(WatchRingMath.weeklyUsagePercent(p), 0.60, accuracy: 1e-9)
        XCTAssertEqual(WatchRingMath.weeklyRemainingPercentInt(p), 40)
    }

    func test_weeklyUsagePercent_fallsBackToNameWhenNoRole() {
        let p = makeProvider("Codex", quota: 100, remaining: 80, tiers: [
            TierDTO(name: "Weekly", quota: 100, remaining: 25, role: nil),
        ])
        XCTAssertEqual(WatchRingMath.weeklyUsagePercent(p), 0.75, accuracy: 1e-9)
    }

    func test_weeklyUsagePercent_fallsBackToPrimaryWhenNoWeekly() {
        // No weekly tier → primary usagePercent (62% used).
        let p = makeProvider("X", quota: 100, remaining: 38)
        XCTAssertEqual(WatchRingMath.weeklyUsagePercent(p), 0.62, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeProvider(_ name: String, quota: Int?, remaining: Int?,
                             cost: Double = 0, usage: Int = 0,
                             tiers: [TierDTO] = []) -> ProviderUsage {
        ProviderUsage(
            provider: name,
            today_usage: usage,
            week_usage: 0,
            estimated_cost_today: cost,
            estimated_cost_week: 0,
            cost_status_today: "Estimated",
            cost_status_week: "Estimated",
            quota: quota,
            remaining: remaining,
            tiers: tiers,
            status_text: "",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
    }
}
