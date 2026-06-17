import XCTest
@testable import CLIPulseCore

/// v1.30 F3 — the chart data shaper. UTC calendar in tests for determinism.
final class ProviderUsageHistoryTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func row(_ date: String, _ provider: String, _ model: String,
                     i: Int, o: Int, c: Int, cost: Double) -> DailyUsage {
        // NOTE: DailyUsage init order is (inputTokens, cachedTokens, outputTokens).
        DailyUsage(date: date, provider: provider, model: model,
                   inputTokens: i, cachedTokens: c, outputTokens: o, cost: cost)
    }

    func test_aggregatesAcrossModels_sameDay() {
        let rows = [
            row("2026-06-17", "Codex", "gpt-5",      i: 100, o: 50, c: 10, cost: 1.0),
            row("2026-06-17", "Codex", "gpt-5-mini", i: 20,  o: 5,  c: 2,  cost: 0.2),
        ]
        let s = ProviderUsageHistory.series(from: rows, provider: "Codex", days: 1, todayKey: "2026-06-17", calendar: utc)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].inputTokens, 120)
        XCTAssertEqual(s[0].outputTokens, 55)
        XCTAssertEqual(s[0].cachedTokens, 12)
        XCTAssertEqual(s[0].cost, 1.2, accuracy: 1e-9)
        XCTAssertEqual(s[0].ioTokens, 175)        // input + output, excludes cache
        XCTAssertEqual(s[0].totalTokens, 187)
    }

    func test_fillsGapsWithZero_contiguousAndOrdered() {
        let rows = [row("2026-06-15", "Codex", "gpt-5", i: 10, o: 10, c: 0, cost: 0.5)]
        let s = ProviderUsageHistory.series(from: rows, provider: "Codex", days: 3, todayKey: "2026-06-17", calendar: utc)
        XCTAssertEqual(s.map(\.dateKey), ["2026-06-15", "2026-06-16", "2026-06-17"])  // oldest → newest
        XCTAssertEqual(s[0].ioTokens, 20)
        XCTAssertEqual(s[1].ioTokens, 0)          // gap filled with zero
        XCTAssertEqual(s[2].ioTokens, 0)
        XCTAssertEqual(s.last?.dateKey, "2026-06-17")  // todayKey is the last point
    }

    func test_filtersByProvider() {
        let rows = [
            row("2026-06-17", "Codex",  "gpt-5",  i: 100, o: 0, c: 0, cost: 1),
            row("2026-06-17", "Claude", "sonnet", i: 999, o: 0, c: 0, cost: 9),
        ]
        let s = ProviderUsageHistory.series(from: rows, provider: "Codex", days: 1, todayKey: "2026-06-17", calendar: utc)
        XCTAssertEqual(s[0].inputTokens, 100)     // Claude row excluded
    }

    func test_emptyInput_allZeroWindow() {
        let s = ProviderUsageHistory.series(from: [], provider: "Codex", days: 7, todayKey: "2026-06-17", calendar: utc)
        XCTAssertEqual(s.count, 7)
        XCTAssertTrue(s.allSatisfy { $0.totalTokens == 0 && $0.cost == 0 })
    }

    func test_zeroDays_empty() {
        XCTAssertTrue(ProviderUsageHistory.series(from: [], provider: "Codex", days: 0, todayKey: "2026-06-17", calendar: utc).isEmpty)
    }
}
