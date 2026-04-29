import XCTest
@testable import CLIPulseCore

final class CostForecastEngineTests: XCTestCase {

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return Calendar.current.date(from: comps)!
    }

    private func makeDailyUsage(date: String, cost: Double) -> DailyUsage {
        DailyUsage(date: date, provider: "Claude", model: "claude-sonnet-4-6",
                   inputTokens: 1000, cachedTokens: 0, outputTokens: 200, cost: cost)
    }

    // MARK: - empty data

    func testEmptyDataProducesZeroActualAndUnreliable() {
        let ref = makeDate(year: 2026, month: 4, day: 15)
        let result = CostForecastEngine.forecast(from: [], referenceDate: ref)
        // Returns a zero forecast, not nil — data points for each day exist with cost=0
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.actualToDate ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(result?.isReliable, false)
    }

    // MARK: - single day

    func testForecastReturnedWithSingleDay() throws {
        let ref = makeDate(year: 2026, month: 4, day: 1)
        let usage = [makeDailyUsage(date: "2026-04-01", cost: 2.0)]
        let result = try XCTUnwrap(CostForecastEngine.forecast(from: usage, referenceDate: ref))
        XCTAssertEqual(result.actualToDate, 2.0, accuracy: 0.001)
        XCTAssertEqual(result.dataPointCount, 1)
    }

    // MARK: - isReliable flag

    func testIsReliableFalseWithTwoDays() {
        let ref = makeDate(year: 2026, month: 4, day: 2)
        let usage = [
            makeDailyUsage(date: "2026-04-01", cost: 1.0),
            makeDailyUsage(date: "2026-04-02", cost: 2.0),
        ]
        let result = CostForecastEngine.forecast(from: usage, referenceDate: ref)
        XCTAssertEqual(result?.isReliable, false)
    }

    func testIsReliableTrueWithThreeDays() {
        let ref = makeDate(year: 2026, month: 4, day: 3)
        let usage = [
            makeDailyUsage(date: "2026-04-01", cost: 1.0),
            makeDailyUsage(date: "2026-04-02", cost: 1.5),
            makeDailyUsage(date: "2026-04-03", cost: 2.0),
        ]
        let result = CostForecastEngine.forecast(from: usage, referenceDate: ref)
        XCTAssertEqual(result?.isReliable, true)
    }

    // MARK: - actualToDate aggregation

    func testActualToDateSumsCurrentMonthOnly() throws {
        let ref = makeDate(year: 2026, month: 4, day: 3)
        let usage = [
            makeDailyUsage(date: "2026-04-01", cost: 1.0),
            makeDailyUsage(date: "2026-04-02", cost: 2.0),
            makeDailyUsage(date: "2026-03-31", cost: 99.0), // previous month — excluded
        ]
        let result = try XCTUnwrap(CostForecastEngine.forecast(from: usage, referenceDate: ref))
        XCTAssertEqual(result.actualToDate, 3.0, accuracy: 0.001)
    }

    // MARK: - bounds

    func testLowerBoundNotBelowActual() {
        let ref = makeDate(year: 2026, month: 4, day: 5)
        let usage = (1...5).map { makeDailyUsage(date: String(format: "2026-04-%02d", $0), cost: 1.0) }
        let result = try! XCTUnwrap(CostForecastEngine.forecast(from: usage, referenceDate: ref))
        XCTAssertGreaterThanOrEqual(result.lowerBound, result.actualToDate)
    }

    func testPredictedMonthTotalAtLeastActual() {
        let ref = makeDate(year: 2026, month: 4, day: 5)
        let usage = (1...5).map { makeDailyUsage(date: String(format: "2026-04-%02d", $0), cost: 2.0) }
        let result = try! XCTUnwrap(CostForecastEngine.forecast(from: usage, referenceDate: ref))
        XCTAssertGreaterThanOrEqual(result.predictedMonthTotal, result.actualToDate)
    }

    // MARK: - month metadata

    func testCurrentDayAndDaysInMonth() {
        let ref = makeDate(year: 2026, month: 4, day: 10)
        let usage = [makeDailyUsage(date: "2026-04-10", cost: 1.0)]
        let result = try! XCTUnwrap(CostForecastEngine.forecast(from: usage, referenceDate: ref))
        XCTAssertEqual(result.currentDayOfMonth, 10)
        XCTAssertEqual(result.daysInMonth, 30) // April has 30 days
    }

    // MARK: - iter21 hotfix: last-day-of-month closed-range crash

    /// Pre-iter21, this case crashed with EXC_BREAKPOINT (Swift fatal
    /// trap) at CostForecastEngine.swift:77. The projection loop was
    /// `for day in (dayOfMonth + 1)...daysInMonth` — when called on
    /// the last day of the month (Apr 30 → dayOfMonth=30, daysInMonth=
    /// 30), the closed range `31...30` is invalid and Swift traps.
    /// Fired on every refresh cycle while a user was running v1.11.0
    /// build 44 on real device (Sentry issue 7450581409).
    ///
    /// Fix: gate the projection loop on `remainingDays > 0`. Pinned
    /// for ALL 7 distinct last-day cases so a future refactor can't
    /// silently re-introduce the bug for one calendar variant.
    func testForecastOnLastDayOfMonthDoesNotCrash() {
        let lastDays: [(year: Int, month: Int, day: Int, label: String)] = [
            (2026, 1, 31, "January (31)"),
            (2026, 2, 28, "February (28, non-leap)"),
            (2024, 2, 29, "February (29, leap)"),
            (2026, 3, 31, "March (31)"),
            (2026, 4, 30, "April (30) — Apr 30 2026 = the original repro"),
            (2026, 6, 30, "June (30)"),
            (2026, 12, 31, "December (31)"),
        ]
        for d in lastDays {
            let ref = makeDate(year: d.year, month: d.month, day: d.day)
            let dateStr = String(format: "%04d-%02d-%02d", d.year, d.month, d.day)
            let usage = [
                makeDailyUsage(date: dateStr, cost: 1.5),
                makeDailyUsage(
                    date: String(format: "%04d-%02d-%02d", d.year, d.month, d.day - 1),
                    cost: 1.4
                ),
            ]
            let result = CostForecastEngine.forecast(from: usage, referenceDate: ref)
            XCTAssertNotNil(result, "must produce a forecast on \(d.label) — pre-iter21 crashed here")
            // On the last day there are no remaining days to project,
            // so predictedMonthTotal collapses to actualToDate (modulo
            // the regression-blend smoothing, which preserves the
            // `max(blended, actualToDate)` floor).
            XCTAssertGreaterThanOrEqual(
                result?.predictedMonthTotal ?? -1,
                result?.actualToDate ?? 0,
                "predicted total must never go below actual on last day (\(d.label))"
            )
        }
    }

    /// Symmetric: the day-BEFORE the last day should still project
    /// exactly one remaining day. Pins the boundary on the other
    /// side so a future "fix" doesn't accidentally widen the guard
    /// to also skip the second-to-last day.
    func testForecastOnSecondToLastDayProjectsOneRemainingDay() {
        let ref = makeDate(year: 2026, month: 4, day: 29)  // Apr 29 2026
        let usage = [
            makeDailyUsage(date: "2026-04-28", cost: 1.0),
            makeDailyUsage(date: "2026-04-29", cost: 1.2),
        ]
        let result = try! XCTUnwrap(
            CostForecastEngine.forecast(from: usage, referenceDate: ref)
        )
        XCTAssertEqual(result.currentDayOfMonth, 29)
        XCTAssertEqual(result.daysInMonth, 30)
        // The projection loop ran for exactly 1 day (Apr 30), so the
        // forecasted total should exceed actualToDate.
        XCTAssertGreaterThan(
            result.predictedMonthTotal, result.actualToDate,
            "second-to-last day must still project the remaining day"
        )
    }
}

// MARK: - TokenPricing.formatCost

final class TokenPricingFormatCostTests: XCTestCase {

    func testFormatCostZero() {
        XCTAssertEqual(TokenPricing.formatCost(0), "$0.00")
    }

    func testFormatCostBelowOneCent() {
        let result = TokenPricing.formatCost(0.001)
        XCTAssertTrue(result.hasPrefix("$0.00"), "Expected 4 decimal places for sub-cent cost, got \(result)")
    }

    func testFormatCostCentsRange() {
        XCTAssertEqual(TokenPricing.formatCost(0.05), "$0.05")
    }

    func testFormatCostDollarsRange() {
        XCTAssertEqual(TokenPricing.formatCost(1.50), "$1.50")
    }

    func testFormatCostLargeValue() {
        XCTAssertEqual(TokenPricing.formatCost(42.99), "$42.99")
    }
}
