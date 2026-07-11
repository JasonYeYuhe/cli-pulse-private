// PetLedgerManagerTests — v1.42 Pulse Cat M0 (macOS actor glue).
//
// Exercises the actor's producers + persistence with an injected temp root, so
// the real Application Support container is never touched (DailyUsageArchive-
// ManagerTests idiom).

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class PetLedgerManagerTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-mgr-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ day: String, _ provider: String, _ model: String,
                       input: Int, output: Int, cost: Double?, messages: Int = 0)
        -> CostUsageScanResult.DailyEntry {
        .init(date: day, provider: provider, model: model, inputTokens: input,
              cachedTokens: 0, outputTokens: output, costUSD: cost, messageCount: messages)
    }

    func test_record_scan_persists_and_snapshots() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = PetLedgerManager(root: root)

        await mgr.record(CostUsageScanResult(entries: [
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 40_000, output: 20_000, cost: 0.5, messages: 12),
        ]))
        let snap = await mgr.snapshot()
        let fam = snap.familyRollup(forDay: "2026-07-11")
        XCTAssertEqual(fam[.anthropic]?.tokens, 60_000)
        XCTAssertEqual(fam[.anthropic]?.messages, 12)
        XCTAssertEqual(fam[.anthropic]?.confidence, .high)
    }

    func test_merge_cloud_adds_google_family() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = PetLedgerManager(root: root)

        await mgr.mergeCloud([
            DailyUsage(date: "2026-07-11", provider: "Gemini", model: "gemini-3-pro",
                       inputTokens: 5_000, cachedTokens: 0, outputTokens: 5_000, cost: 0.02),
        ])
        let fam = await mgr.snapshot().familyRollup(forDay: "2026-07-11")
        XCTAssertEqual(fam[.google]?.tokens, 10_000)
        XCTAssertEqual(fam[.google]?.confidence, .medium)
    }

    func test_local_scan_wins_over_cloud_for_same_provider() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = PetLedgerManager(root: root)

        await mgr.record(CostUsageScanResult(entries: [
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 60_000, output: 40_000, cost: 1.0),
        ]))
        // Cloud reports a lower/stale Claude figure — must not overwrite high.
        await mgr.mergeCloud([
            DailyUsage(date: "2026-07-11", provider: "Claude", model: "claude-opus-4-8",
                       inputTokens: 1_000, cachedTokens: 0, outputTokens: 1_000, cost: 0.01),
        ])
        let fam = await mgr.snapshot().familyRollup(forDay: "2026-07-11")
        XCTAssertEqual(fam[.anthropic]?.tokens, 100_000)
    }

    func test_persists_across_manager_instances() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let a = PetLedgerManager(root: root)
        await a.record(CostUsageScanResult(entries: [
            entry("2026-07-11", "Codex", "gpt-5.5", input: 10_000, output: 10_000, cost: 0.04),
        ]))
        // A fresh manager on the same root loads what the first saved.
        let b = PetLedgerManager(root: root)
        let fam = await b.snapshot().familyRollup(forDay: "2026-07-11")
        XCTAssertEqual(fam[.openai]?.tokens, 20_000)
    }

    func test_stale_scan_does_not_overwrite_fresher_by_source_time() async {
        // A fresher scan (newer source time, higher today total) is recorded
        // first; then a STALE scan (older source time, lower total) whose task
        // lands late must NOT overwrite it, because the tie-break uses the
        // source timestamp, not actor-receipt order (Codex F3 real-path).
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = PetLedgerManager(root: root)

        await mgr.record(CostUsageScanResult(entries: [
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 40_000, output: 20_000, cost: 0.5),
        ]), observedAtUnixMs: 2_000)
        await mgr.record(CostUsageScanResult(entries: [
            entry("2026-07-11", "Claude", "claude-opus-4-8", input: 6_000, output: 4_000, cost: 0.05),
        ]), observedAtUnixMs: 1_000)   // stale: older source time
        let fam = await mgr.snapshot().familyRollup(forDay: "2026-07-11")
        XCTAssertEqual(fam[.anthropic]?.tokens, 60_000)
    }

    func test_ingest_direct_observations() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mgr = PetLedgerManager(root: root)
        await mgr.ingest([
            PetObservation(providerRaw: "Claude", tokens: 5_000, messages: 3, costUSD: 0.02,
                           sourceTimestampUnixMs: 1, dayKey: "2026-07-11",
                           confidence: .high, semantics: .cumulativeToday),
        ])
        let total = await mgr.snapshot().dayTotals("2026-07-11").tokens
        XCTAssertEqual(total, 5_000)
    }
}
#endif
