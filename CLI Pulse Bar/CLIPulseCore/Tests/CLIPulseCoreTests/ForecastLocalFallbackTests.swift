import XCTest
@testable import CLIPulseCore

/// Codex review on PR #17 manual verification: Forecast was
/// showing ~$8.6 spent so far / ~$37.4 month-end while Today's
/// actual cost was hundreds of dollars (the accurate one shipped
/// with PR #16's pricing fix). Cause: `daily_usage_metrics`
/// server-side rows were stale because `[syncDailyUsage] failed:
/// HTTP 403` had been firing continuously, leaving the server's
/// view of recent days empty.
///
/// The fix feeds `costUsageScanResult` (local JSONL scan, accurate
/// per-day) into `CostForecastEngine.forecast(from:localOverrides:
/// referenceDate:)` as a `[dayKey: cost]` override map. For each
/// day, the engine takes `max(server_cost, local_cost)` so:
///   * Old days where only server has data: server wins (no change).
///   * Recent days where local has more accurate data: local wins.
///   * Today (typically server=0 due to staleness, local=actual):
///     local wins.
///
/// These tests pin the contract.
final class ForecastLocalFallbackTests: XCTestCase {

    private static let referenceDate: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 5
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)!
    }()

    private static func dayKey(year: Int, month: Int, day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static let mayKey1 = dayKey(year: 2026, month: 5, day: 1)
    private static let mayKey2 = dayKey(year: 2026, month: 5, day: 2)
    private static let mayKey3 = dayKey(year: 2026, month: 5, day: 3)
    private static let mayKey4 = dayKey(year: 2026, month: 5, day: 4)
    private static let mayKey5 = dayKey(year: 2026, month: 5, day: 5)

    // MARK: - Server-only path (regression: must still work)

    func testServerOnlyForecast_unchangedByEmptyLocalOverrides() {
        let serverUsage: [DailyUsage] = [
            DailyUsage(date: Self.mayKey1, provider: "Claude", model: "claude-opus-4-7",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 50),
            DailyUsage(date: Self.mayKey2, provider: "Claude", model: "claude-opus-4-7",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 60),
            DailyUsage(date: Self.mayKey3, provider: "Claude", model: "claude-opus-4-7",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 70),
        ]
        let withoutOverride = CostForecastEngine.forecast(
            from: serverUsage, referenceDate: Self.referenceDate
        )
        let withEmptyOverride = CostForecastEngine.forecast(
            from: serverUsage, localOverrides: [:], referenceDate: Self.referenceDate
        )
        XCTAssertEqual(withoutOverride?.actualToDate, withEmptyOverride?.actualToDate)
        XCTAssertEqual(withoutOverride?.predictedMonthTotal, withEmptyOverride?.predictedMonthTotal)
    }

    // MARK: - Local fills in stale-server gap

    func testLocalOverride_fillsTodayWhenServerMissing() {
        // Server has days 1-3 but is missing today (4-5) due to
        // syncDailyUsage 403. Local scan has all 5 days.
        let serverUsage: [DailyUsage] = [
            DailyUsage(date: Self.mayKey1, provider: "Claude", model: "x",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 50),
            DailyUsage(date: Self.mayKey2, provider: "Claude", model: "x",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 50),
            DailyUsage(date: Self.mayKey3, provider: "Claude", model: "x",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 50),
        ]
        let localOverrides: [String: Double] = [
            Self.mayKey1: 50,    // matches server
            Self.mayKey2: 50,
            Self.mayKey3: 50,
            Self.mayKey4: 220,   // server missing
            Self.mayKey5: 220,   // server missing → today
        ]
        let serverOnly = CostForecastEngine.forecast(
            from: serverUsage, referenceDate: Self.referenceDate
        )
        let withLocal = CostForecastEngine.forecast(
            from: serverUsage, localOverrides: localOverrides,
            referenceDate: Self.referenceDate
        )
        // Server-only: actualToDate = 50*3 = 150 (days 4 + 5 missing).
        XCTAssertEqual(serverOnly?.actualToDate ?? 0, 150, accuracy: 0.01)
        // With local: actualToDate = 50*3 + 220*2 = 590.
        XCTAssertEqual(withLocal?.actualToDate ?? 0, 590, accuracy: 0.01)
        // Month-end projection should also reflect the higher rate.
        XCTAssertGreaterThan(
            withLocal?.predictedMonthTotal ?? 0,
            serverOnly?.predictedMonthTotal ?? 0
        )
    }

    func testLocalOverride_takesMaxWhenBothPresent() {
        // Server says day 1 cost was $50, local says $80.
        // Local wins because max(50, 80) = 80.
        let serverUsage = [
            DailyUsage(date: Self.mayKey1, provider: "Claude", model: "x",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 50),
        ]
        let localOverrides = [Self.mayKey1: 80.0]
        let result = CostForecastEngine.forecast(
            from: serverUsage, localOverrides: localOverrides,
            referenceDate: Self.referenceDate
        )
        // Reference date is May 5, so days 1-5 contribute. Only
        // day 1 has data (server=50, local=80). Other days are 0.
        // actualToDate should be 80 (local won), not 50.
        XCTAssertEqual(result?.actualToDate ?? 0, 80, accuracy: 0.01)
    }

    func testLocalOverride_doesNotReduceServerValue() {
        // Defense-in-depth: if local says less than server (e.g.
        // local scan was partial), the engine must NOT downgrade
        // server's value. max() guarantees this.
        let serverUsage = [
            DailyUsage(date: Self.mayKey1, provider: "Claude", model: "x",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 100),
        ]
        let localOverrides = [Self.mayKey1: 30.0]
        let result = CostForecastEngine.forecast(
            from: serverUsage, localOverrides: localOverrides,
            referenceDate: Self.referenceDate
        )
        XCTAssertEqual(result?.actualToDate ?? 0, 100, accuracy: 0.01)
    }

    func testLocalOverride_appliesToHistoricalDayServerNeverHad() {
        // Local backfills a day server never recorded.
        let serverUsage = [
            DailyUsage(date: Self.mayKey1, provider: "Claude", model: "x",
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 50),
        ]
        let localOverrides = [Self.mayKey3: 200.0]  // server has no day 3
        let result = CostForecastEngine.forecast(
            from: serverUsage, localOverrides: localOverrides,
            referenceDate: Self.referenceDate
        )
        // Days 1-5 sum: 50 (day1, server) + 0 + 200 (day3, local) + 0 + 0 = 250
        XCTAssertEqual(result?.actualToDate ?? 0, 250, accuracy: 0.01)
    }
}
