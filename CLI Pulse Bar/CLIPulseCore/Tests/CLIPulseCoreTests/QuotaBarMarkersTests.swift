import XCTest
@testable import CLIPulseCore

/// v1.30 F2 — markers must be tier-aware and orientation-correct (the two
/// CRITICALs from the Codex/Gemini review). Pure math, so fully covered here.
final class QuotaBarMarkersTests: XCTestCase {
    private let iso = ISO8601DateFormatter()

    private func tier(_ name: String, quota: Int, remaining: Int,
                      windowMinutes: Int?, resetInMinutes: Double, from now: Date) -> TierDTO {
        TierDTO(name: name, quota: quota, remaining: remaining,
                reset_time: iso.string(from: now.addingTimeInterval(resetInMinutes * 60)),
                windowMinutes: windowMinutes, role: nil)
    }

    // MARK: place — orientation (the countdown-bar trap)

    func test_place_remainingBar_invertsUsedFraction() {
        XCTAssertEqual(QuotaBarMarkers.place(0.9, onRemainingBar: true), 0.1, accuracy: 1e-9)
        XCTAssertEqual(QuotaBarMarkers.place(0.0, onRemainingBar: true), 1.0, accuracy: 1e-9)
    }

    func test_place_usedBar_keepsUsedFraction() {
        XCTAssertEqual(QuotaBarMarkers.place(0.9, onRemainingBar: false), 0.9, accuracy: 1e-9)
    }

    func test_place_clamps() {
        XCTAssertEqual(QuotaBarMarkers.place(1.3, onRemainingBar: false), 1.0, accuracy: 1e-9)
        XCTAssertEqual(QuotaBarMarkers.place(-0.2, onRemainingBar: true), 1.0, accuracy: 1e-9)
    }

    // MARK: warningFractions

    func test_warningFractions_convertsSortsDedupsFilters() {
        XCTAssertEqual(
            QuotaBarMarkers.warningFractions(thresholdsPercent: [95, 80, 80, 0, 100, -5]),
            [0.8, 0.95])
    }

    func test_warningFractions_empty() {
        XCTAssertTrue(QuotaBarMarkers.warningFractions(thresholdsPercent: []).isEmpty)
    }

    // MARK: expectedPaceFraction — nil cases

    func test_expectedPace_nilWhenNoQuota() {
        let now = Date()
        XCTAssertNil(QuotaBarMarkers.expectedPaceFraction(
            tier: tier("5h", quota: 0, remaining: 0, windowMinutes: 300, resetInMinutes: 150, from: now), now: now))
    }

    func test_expectedPace_nilWhenNoResetTime() {
        let now = Date()
        let t = TierDTO(name: "5h", quota: 100, remaining: 50, reset_time: nil, windowMinutes: 300, role: nil)
        XCTAssertNil(QuotaBarMarkers.expectedPaceFraction(tier: t, now: now))
    }

    func test_expectedPace_nilWhenResetInPast() {
        let now = Date()
        XCTAssertNil(QuotaBarMarkers.expectedPaceFraction(
            tier: tier("5h", quota: 100, remaining: 50, windowMinutes: 300, resetInMinutes: -10, from: now), now: now))
    }

    // MARK: expectedPaceFraction — mid-window value

    func test_expectedPace_midSessionWindow_isHalf() {
        let now = Date()
        // 5h (300min) window resetting in 150min ⇒ 50% elapsed ⇒ expected ≈ 0.5
        let f = QuotaBarMarkers.expectedPaceFraction(
            tier: tier("5h", quota: 100, remaining: 100, windowMinutes: 300, resetInMinutes: 150, from: now), now: now)
        XCTAssertNotNil(f)
        XCTAssertEqual(f!, 0.5, accuracy: 0.01)
    }

    // MARK: tier-awareness (the C3 fix) — same reset, different window ⇒ different marker

    func test_expectedPace_isTierAware_sessionVsWeekly() {
        let now = Date()
        let session = tier("5h", quota: 100, remaining: 100, windowMinutes: 300, resetInMinutes: 150, from: now)
        let weekly  = tier("Weekly", quota: 100, remaining: 100, windowMinutes: 10080, resetInMinutes: 150, from: now)
        let fs = QuotaBarMarkers.expectedPaceFraction(tier: session, now: now)
        let fw = QuotaBarMarkers.expectedPaceFraction(tier: weekly, now: now)
        XCTAssertNotNil(fs); XCTAssertNotNil(fw)
        XCTAssertEqual(fs!, 0.5, accuracy: 0.01)        // 150/300 elapsed
        XCTAssertEqual(fw!, 0.985, accuracy: 0.01)      // (10080-150)/10080 elapsed
        XCTAssertGreaterThan(fw!, fs! + 0.3)            // genuinely distinct positions
    }
}
