// Unit tests for the v1.40 PR-4 DailyUsageStats pure derivations: lifetime
// totals (days+months), activeDays, peak day/cost, favorite model, current +
// longest streaks (calendar-adjacent, with the "today unused" grace and
// month/year-boundary runs), and the COST-keyed heatmap intensity buckets.

import XCTest
@testable import CLIPulseCore

final class DailyUsageStatsTests: XCTestCase {

    private func day(tokens: Int, cost: Double = 0, msgs: Int = 0, models: [String: Int] = [:]) -> DayRollup {
        var m: [String: ModelDaySlice] = [:]
        for (k, v) in models { m[k] = ModelDaySlice(tokens: v, cost: 0) }
        return DayRollup(tokens: tokens, cost: cost, messages: msgs, perProvider: [:], perModel: m)
    }

    private func archive(_ days: [String: DayRollup], months: [String: MonthRollup] = [:]) -> DailyUsageArchive {
        DailyUsageArchive(days: days, months: months)
    }

    // MARK: - Totals + windowed

    func test_totals_include_months() {
        let a = archive(
            ["2026-07-01": day(tokens: 10, cost: 1, msgs: 2)],
            months: ["2026-06": MonthRollup(tokens: 90, cost: 9, messages: 8)])
        XCTAssertEqual(DailyUsageStats.totalTokens(a), 100)
        XCTAssertEqual(DailyUsageStats.totalCost(a), 10, accuracy: 0.0001)
        XCTAssertEqual(DailyUsageStats.totalMessages(a), 10)
    }

    func test_activeDays_excludes_zero_token_days() {
        let a = archive([
            "2026-07-01": day(tokens: 10),
            "2026-07-02": day(tokens: 0),
            "2026-07-03": day(tokens: 5),
        ])
        XCTAssertEqual(DailyUsageStats.activeDays(a), 2)
    }

    func test_peakDay_and_peakCost() {
        let a = archive([
            "2026-07-01": day(tokens: 10, cost: 1),
            "2026-07-02": day(tokens: 99, cost: 0.5),
            "2026-07-03": day(tokens: 5, cost: 9),
        ])
        XCTAssertEqual(DailyUsageStats.peakDay(a)?.day, "2026-07-02")
        XCTAssertEqual(DailyUsageStats.peakDay(a)?.tokens, 99)
        XCTAssertEqual(DailyUsageStats.peakDayCost(a), 9, accuracy: 0.0001)
    }

    func test_favoriteModel_argmax_over_days() {
        let a = archive([
            "2026-07-01": day(tokens: 30, models: ["gpt-5": 20, "claude-sonnet-4-5": 10]),
            "2026-07-02": day(tokens: 30, models: ["claude-sonnet-4-5": 30]),
        ])
        XCTAssertEqual(DailyUsageStats.favoriteModel(a), "claude-sonnet-4-5")   // 40 vs 20
    }

    // MARK: - Streaks

    func test_currentStreak_counts_back_from_today() {
        let a = archive([
            "2026-07-08": day(tokens: 1), "2026-07-09": day(tokens: 1), "2026-07-10": day(tokens: 1),
        ])
        XCTAssertEqual(DailyUsageStats.currentStreak(a, todayKey: "2026-07-10"), 3)
    }

    func test_currentStreak_grace_when_today_unused() {
        let a = archive([
            "2026-07-08": day(tokens: 1), "2026-07-09": day(tokens: 1),   // today (10th) not yet used
        ])
        XCTAssertEqual(DailyUsageStats.currentStreak(a, todayKey: "2026-07-10"), 2)
    }

    func test_currentStreak_zero_when_gap() {
        let a = archive([
            "2026-07-08": day(tokens: 1),    // 09 + 10 both inactive
        ])
        XCTAssertEqual(DailyUsageStats.currentStreak(a, todayKey: "2026-07-10"), 0)
    }

    func test_currentStreak_breaks_on_interior_gap() {
        let a = archive([
            "2026-07-10": day(tokens: 1), "2026-07-08": day(tokens: 1),   // 09 missing
        ])
        XCTAssertEqual(DailyUsageStats.currentStreak(a, todayKey: "2026-07-10"), 1)
    }

    func test_longestStreak_across_month_boundary() {
        let a = archive([
            "2026-01-30": day(tokens: 1), "2026-01-31": day(tokens: 1), "2026-02-01": day(tokens: 1),  // run 3
            "2026-02-05": day(tokens: 1), "2026-02-06": day(tokens: 1),                                 // run 2
        ])
        XCTAssertEqual(DailyUsageStats.longestStreak(a), 3)
    }

    func test_longestStreak_empty_is_zero() {
        XCTAssertEqual(DailyUsageStats.longestStreak(archive([:])), 0)
    }

    // MARK: - Heatmap intensity (cost-keyed)

    func test_intensity_buckets() {
        XCTAssertEqual(DailyUsageStats.intensity(cost: 0, peakCost: 10), 0)
        XCTAssertEqual(DailyUsageStats.intensity(cost: 1, peakCost: 10), 1)     // 0.1
        XCTAssertEqual(DailyUsageStats.intensity(cost: 2.5, peakCost: 10), 2)   // 0.25 boundary
        XCTAssertEqual(DailyUsageStats.intensity(cost: 5, peakCost: 10), 3)     // 0.5 boundary
        XCTAssertEqual(DailyUsageStats.intensity(cost: 7.5, peakCost: 10), 4)   // 0.75 boundary
        XCTAssertEqual(DailyUsageStats.intensity(cost: 10, peakCost: 10), 4)
        XCTAssertEqual(DailyUsageStats.intensity(cost: 5, peakCost: 0), 0)      // no peak ⇒ 0
    }

    // MARK: - Breakdowns

    func test_byModel_and_byProvider_sorted_desc() {
        let a = archive([
            "2026-07-01": DayRollup(
                tokens: 60, cost: 3, messages: 0,
                perProvider: ["Claude": ProviderDaySlice(tokens: 40, cost: 2),
                              "Codex": ProviderDaySlice(tokens: 20, cost: 1)],
                perModel: ["claude-sonnet-4-5": ModelDaySlice(tokens: 40, cost: 2),
                           "gpt-5": ModelDaySlice(tokens: 20, cost: 1)]),
        ])
        let models = DailyUsageStats.byModel(a)
        XCTAssertEqual(models.map(\.key), ["claude-sonnet-4-5", "gpt-5"])
        XCTAssertEqual(models.first?.tokens, 40)
        let provs = DailyUsageStats.byProvider(a)
        XCTAssertEqual(provs.map(\.key), ["Claude", "Codex"])
    }

    // MARK: - Day-key calendar helpers

    func test_previousDay_nextDay_boundaries() {
        XCTAssertEqual(DailyUsageStats.previousDay("2026-01-01"), "2025-12-31")   // year boundary
        XCTAssertEqual(DailyUsageStats.nextDay("2026-02-28"), "2026-03-01")       // 2026 not leap
        XCTAssertEqual(DailyUsageStats.nextDay("2024-02-28"), "2024-02-29")       // 2024 leap
        XCTAssertEqual(DailyUsageStats.previousDay("2026-03-01"), "2026-02-28")
        XCTAssertNil(DailyUsageStats.previousDay("garbage"))
    }
}
