// PetObservationProducersTests — v1.42 Pulse Cat M0.
//
// Locks the scan/cloud → PetObservation mapping:
//  • tokens = input + output (cache EXCLUDED); messages summed across rows so
//    the `__claude_msg__` bucket count survives without double-counting; cost
//    summed; one observation per (day, provider) in canonical sorted order;
//  • local scan → high confidence, cloud rows → medium, cloud msg-bucket dropped.

import XCTest
@testable import CLIPulseCore

final class PetObservationProducersTests: XCTestCase {

    private func entry(_ day: String, _ provider: String, _ model: String,
                       input: Int, cached: Int, output: Int,
                       cost: Double?, messages: Int = 0) -> CostUsageScanResult.DailyEntry {
        .init(date: day, provider: provider, model: model, inputTokens: input,
              cachedTokens: cached, outputTokens: output, costUSD: cost, messageCount: messages)
    }

    // MARK: - Local scan

    func test_local_scan_aggregates_per_day_provider() {
        let scan = CostUsageScanResult(entries: [
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 100, cached: 5_000, output: 50, cost: 0.02),
            entry("2026-07-11", "Claude", "claude-sonnet-4-5", input: 200, cached: 0, output: 80, cost: 0.01),
            // Synthetic message bucket: carries the day's real message count, 0 tokens.
            entry("2026-07-11", "Claude", "__claude_msg__", input: 0, cached: 0, output: 0, cost: nil, messages: 30),
        ])
        let obs = PetObservation.fromLocalScan(scan, nowUnixMs: 999)
        XCTAssertEqual(obs.count, 1)
        let o = obs[0]
        XCTAssertEqual(o.providerRaw, "Claude")
        XCTAssertEqual(o.familyKey, PetFamily.anthropic.rawValue)
        XCTAssertEqual(o.tokens, 430)          // (100+50)+(200+80) — cache EXCLUDED
        XCTAssertEqual(o.messages, 30)          // bucket count, not double-counted
        XCTAssertEqual(o.costUSD, 0.03, accuracy: 1e-9)
        XCTAssertEqual(o.confidence, .high)
        XCTAssertEqual(o.semantics, .cumulativeToday)
        XCTAssertEqual(o.dayKey, "2026-07-11")
        XCTAssertEqual(o.sourceTimestampUnixMs, 999)
    }

    func test_local_scan_multiple_days_providers_sorted() {
        let scan = CostUsageScanResult(entries: [
            entry("2026-07-11", "Codex", "gpt-5.5", input: 100, cached: 0, output: 100, cost: 0.02),
            entry("2026-07-10", "Claude", "claude-opus-4-8", input: 50, cached: 0, output: 50, cost: 0.01),
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 10, cached: 0, output: 10, cost: 0.001),
        ])
        let obs = PetObservation.fromLocalScan(scan, nowUnixMs: 1)
        // Canonical order: sorted by (dayKey, provider).
        XCTAssertEqual(obs.map { "\($0.dayKey)/\($0.providerRaw)" },
                       ["2026-07-10/Claude", "2026-07-11/Claude", "2026-07-11/Codex"])
        XCTAssertEqual(obs[2].tokens, 200)      // Codex 100+100
        XCTAssertEqual(obs[2].familyKey, PetFamily.openai.rawValue)
    }

    func test_local_scan_nil_cost_treated_as_zero() {
        let scan = CostUsageScanResult(entries: [
            entry("2026-07-11", "Codex", "gpt-5.5", input: 100, cached: 0, output: 0, cost: nil),
        ])
        let obs = PetObservation.fromLocalScan(scan, nowUnixMs: 1)
        XCTAssertEqual(obs[0].costUSD, 0, accuracy: 1e-12)
        XCTAssertEqual(obs[0].tokens, 100)
    }

    func test_empty_scan_yields_no_observations() {
        XCTAssertTrue(PetObservation.fromLocalScan(CostUsageScanResult(entries: []), nowUnixMs: 1).isEmpty)
    }

    // MARK: - Cloud rows

    func test_cloud_rows_are_medium_and_drop_message_bucket() {
        let rows = [
            DailyUsage(date: "2026-07-11", provider: "Gemini", model: "gemini-3-pro",
                       inputTokens: 1_000, cachedTokens: 500, outputTokens: 400, cost: 0.005),
            DailyUsage(date: "2026-07-11", provider: "Gemini", model: "gemini-3-flash",
                       inputTokens: 200, cachedTokens: 0, outputTokens: 100, cost: 0.001),
            // A cloud row for the synthetic bucket must be filtered out.
            DailyUsage(date: "2026-07-11", provider: "Claude", model: ScanEntry.messageBucketModel,
                       inputTokens: 0, cachedTokens: 0, outputTokens: 0, cost: 0),
        ]
        let obs = PetObservation.fromCloudRows(rows, nowUnixMs: 7)
        XCTAssertEqual(obs.count, 1)                 // only Gemini survives
        let g = obs[0]
        XCTAssertEqual(g.providerRaw, "Gemini")
        XCTAssertEqual(g.familyKey, PetFamily.google.rawValue)
        XCTAssertEqual(g.tokens, 1_700)             // (1000+400)+(200+100) — cache excluded
        XCTAssertEqual(g.messages, 0)               // cloud has no messages
        XCTAssertEqual(g.costUSD, 0.006, accuracy: 1e-9)
        XCTAssertEqual(g.confidence, .medium)
    }

    // MARK: - End-to-end into the ledger

    func test_scan_then_cloud_into_ledger() {
        var l = PetDailyLedger()
        let scan = CostUsageScanResult(entries: [
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 40_000, cached: 0, output: 20_000, cost: 0.5, messages: 12),
        ])
        l.ingest(PetObservation.fromLocalScan(scan, nowUnixMs: 1))
        l.ingest(PetObservation.fromCloudRows([
            DailyUsage(date: "2026-07-11", provider: "Gemini", model: "gemini-3-pro",
                       inputTokens: 5_000, cachedTokens: 0, outputTokens: 5_000, cost: 0.02),
        ], nowUnixMs: 2))

        let fam = l.familyRollup(forDay: "2026-07-11")
        XCTAssertEqual(fam[.anthropic]?.tokens, 60_000)
        XCTAssertEqual(fam[.anthropic]?.confidence, .high)
        XCTAssertEqual(fam[.google]?.tokens, 10_000)
        XCTAssertEqual(fam[.google]?.confidence, .medium)
    }
}
