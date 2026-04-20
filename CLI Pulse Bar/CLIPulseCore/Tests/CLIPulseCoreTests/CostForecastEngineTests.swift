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
