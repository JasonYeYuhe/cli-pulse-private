import XCTest
@testable import CLIPulseCore

final class CostUsageScanResultTests: XCTestCase {

    // MARK: - Helpers

    private func entry(
        _ date: String, provider: String, model: String = "test-model",
        input: Int = 0, cached: Int = 0, output: Int = 0,
        cost: Double? = nil, messages: Int = 0
    ) -> CostUsageScanResult.DailyEntry {
        .init(date: date, provider: provider, model: model,
              inputTokens: input, cachedTokens: cached, outputTokens: output,
              costUSD: cost, messageCount: messages)
    }

    // MARK: - Empty result

    func testEmptyResultHasZeroTotalCost() {
        let result = CostUsageScanResult(entries: [])
        XCTAssertEqual(result.totalCost, 0)
    }

    func testEmptyResultHasZeroTotalTokens() {
        let result = CostUsageScanResult(entries: [])
        XCTAssertEqual(result.totalTokens, 0)
    }

    // MARK: - totalCost (overall)

    func testTotalCostSumsAllEntries() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
            entry("2026-04-20", provider: "Claude", cost: 0.25),
            entry("2026-04-21", provider: "Gemini", cost: 0.05),
        ])
        XCTAssertEqual(result.totalCost, 0.40, accuracy: 0.001)
    }

    func testTotalCostIgnoresNilCostEntries() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
            entry("2026-04-20", provider: "Ollama", cost: nil),
        ])
        XCTAssertEqual(result.totalCost, 0.10, accuracy: 0.001)
    }

    func testTotalCostAllNilReturnsZero() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Ollama", cost: nil),
            entry("2026-04-21", provider: "Ollama", cost: nil),
        ])
        XCTAssertEqual(result.totalCost, 0)
    }

    // MARK: - totalCost(for date:)

    func testTotalCostForDateFiltersCorrectly() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
            entry("2026-04-20", provider: "Claude", cost: 0.25),
            entry("2026-04-21", provider: "Gemini", cost: 0.05),
        ])
        XCTAssertEqual(result.totalCost(for: "2026-04-20"), 0.35, accuracy: 0.001)
        XCTAssertEqual(result.totalCost(for: "2026-04-21"), 0.05, accuracy: 0.001)
    }

    func testTotalCostForDateReturnsZeroForMissingDate() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
        ])
        XCTAssertEqual(result.totalCost(for: "2026-04-22"), 0)
    }

    // MARK: - todayCost(todayKey:)

    func testTodayCostMatchesTotalCostForDate() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
            entry("2026-04-20", provider: "Claude", cost: 0.20),
            entry("2026-04-21", provider: "Gemini", cost: 0.05),
        ])
        XCTAssertEqual(
            result.todayCost(todayKey: "2026-04-20"),
            result.totalCost(for: "2026-04-20"),
            accuracy: 0.001
        )
    }

    // MARK: - totalCost(provider:)

    func testTotalCostForProviderFiltersAcrossDates() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
            entry("2026-04-21", provider: "Codex", cost: 0.15),
            entry("2026-04-20", provider: "Claude", cost: 0.25),
        ])
        XCTAssertEqual(result.totalCost(provider: "Codex"), 0.25, accuracy: 0.001)
        XCTAssertEqual(result.totalCost(provider: "Claude"), 0.25, accuracy: 0.001)
    }

    func testTotalCostForUnknownProviderReturnsZero() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
        ])
        XCTAssertEqual(result.totalCost(provider: "Gemini"), 0)
    }

    // MARK: - totalCostForProvider(_:)

    func testTotalCostForProviderMatchesTotalCostByProvider() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", cost: 0.10),
            entry("2026-04-21", provider: "Codex", cost: 0.15),
        ])
        XCTAssertEqual(
            result.totalCostForProvider("Codex"),
            result.totalCost(provider: "Codex"),
            accuracy: 0.001
        )
    }

    // MARK: - totalTokens(for date:)

    func testTotalTokensForDateSumsInputAndOutputOnly() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", input: 100, cached: 50, output: 200),
            entry("2026-04-20", provider: "Claude", input: 300, cached: 10, output: 400),
            entry("2026-04-21", provider: "Gemini", input: 500, output: 600),
        ])
        XCTAssertEqual(result.totalTokens(for: "2026-04-20"), 1000) // 100+200+300+400
        XCTAssertEqual(result.totalTokens(for: "2026-04-21"), 1100) // 500+600
    }

    func testTotalTokensForDateExcludesCachedTokens() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Claude", input: 100, cached: 9999, output: 200),
        ])
        XCTAssertEqual(result.totalTokens(for: "2026-04-20"), 300)
    }

    func testTotalTokensForMissingDateReturnsZero() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", input: 100, output: 200),
        ])
        XCTAssertEqual(result.totalTokens(for: "2026-04-22"), 0)
    }

    // MARK: - totalTokens (overall)

    func testTotalTokensSumsInputAndOutputAcrossAllDates() {
        let result = CostUsageScanResult(entries: [
            entry("2026-04-20", provider: "Codex", input: 100, cached: 50, output: 200),
            entry("2026-04-21", provider: "Claude", input: 300, cached: 20, output: 400),
        ])
        XCTAssertEqual(result.totalTokens, 1000) // (100+200) + (300+400)
    }

    // MARK: - DailyEntry

    func testDailyEntryDefaultMessageCountIsZero() {
        let e = CostUsageScanResult.DailyEntry(
            date: "2026-04-20", provider: "Codex", model: "gpt-4",
            inputTokens: 100, cachedTokens: 0, outputTokens: 50, costUSD: 0.01
        )
        XCTAssertEqual(e.messageCount, 0)
    }

    func testDailyEntryStoresAllProperties() {
        let e = entry("2026-04-20", provider: "Claude", model: "claude-opus",
                       input: 1000, cached: 500, output: 2000, cost: 1.23, messages: 42)
        XCTAssertEqual(e.date, "2026-04-20")
        XCTAssertEqual(e.provider, "Claude")
        XCTAssertEqual(e.model, "claude-opus")
        XCTAssertEqual(e.inputTokens, 1000)
        XCTAssertEqual(e.cachedTokens, 500)
        XCTAssertEqual(e.outputTokens, 2000)
        XCTAssertEqual(e.costUSD, 1.23)
        XCTAssertEqual(e.messageCount, 42)
    }
}
