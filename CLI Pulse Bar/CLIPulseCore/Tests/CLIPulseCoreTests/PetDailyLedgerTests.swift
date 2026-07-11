// PetDailyLedgerTests — v1.42 Pulse Cat M0.
//
// Locks the ledger data contract:
//  • confidence-priority replace-by-(day, provider): high (local) beats medium
//    (cloud) for the same provider; different providers of a family sum; the
//    merge is idempotent;
//  • derived per-family weighted rollups apply the weight table correctly;
//  • prune bounds the file; delta observations are never folded;
//  • IO round-trips and recovers (empty) from corrupt/version-mismatch files.

import XCTest
@testable import CLIPulseCore

final class PetDailyLedgerTests: XCTestCase {

    // Row builder — defaults make each test read as data.
    private func obs(_ provider: String, day: String, tokens: Int,
                     messages: Int = 0, cost: Double = 0,
                     confidence: PetDataConfidence = .high,
                     semantics: PetObservationSemantics = .cumulativeToday,
                     ts: Int64 = 1_000) -> PetObservation {
        PetObservation(providerRaw: provider, tokens: tokens, messages: messages,
                       costUSD: cost, sourceTimestampUnixMs: ts, dayKey: day,
                       confidence: confidence, semantics: semantics)
    }

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Basic ingest + derived family rollup

    func test_single_provider_day_rollup() {
        var l = PetDailyLedger()
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 100_000, messages: 42, cost: 0.30)])

        let fam = l.familyRollup(forDay: "2026-07-11")
        let anth = fam[.anthropic]
        XCTAssertEqual(anth?.tokens, 100_000)
        XCTAssertEqual(anth?.messages, 42)
        XCTAssertEqual(anth?.costUSD ?? 0, 0.30, accuracy: 1e-9)
        XCTAssertEqual(anth?.costNanoUSD, 300_000_000)        // 0.30 USD → nano
        XCTAssertEqual(anth?.weightedScore, 300_000_000_000)  // 100k × $3/Mtok micro
        XCTAssertEqual(anth?.confidence, .high)
        XCTAssertNil(fam[.openai])
    }

    // MARK: - Confidence-priority replace

    func test_high_local_not_downgraded_by_medium_cloud() {
        var l = PetDailyLedger()
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 100_000, confidence: .high)])
        // Cloud reports a lower/stale figure for the SAME provider — must not win.
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 5_000, confidence: .medium)])
        XCTAssertEqual(l.familyRollup(forDay: "2026-07-11")[.anthropic]?.tokens, 100_000)
    }

    func test_high_replaces_existing_medium() {
        var l = PetDailyLedger()
        l.ingest([obs("Gemini", day: "2026-07-11", tokens: 50_000, confidence: .medium)])
        l.ingest([obs("Gemini", day: "2026-07-11", tokens: 60_000, confidence: .high)])
        let g = l.familyRollup(forDay: "2026-07-11")[.google]
        XCTAssertEqual(g?.tokens, 60_000)
        XCTAssertEqual(g?.confidence, .high)
    }

    func test_same_confidence_strictly_newer_wins() {
        var l = PetDailyLedger()
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 10_000, confidence: .high, ts: 1_000)])
        // A strictly-newer scan (today grew) wins.
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 90_000, confidence: .high, ts: 1_001)])
        XCTAssertEqual(l.familyRollup(forDay: "2026-07-11")[.anthropic]?.tokens, 90_000)
        // An equal-timestamp re-ingest of a DIFFERENT value does NOT flip it
        // (strict >, so arrival order can't decide) — deterministic.
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 12_345, confidence: .high, ts: 1_001)])
        XCTAssertEqual(l.familyRollup(forDay: "2026-07-11")[.anthropic]?.tokens, 90_000)
    }

    func test_different_providers_same_family_sum() {
        var l = PetDailyLedger()
        // openai family = Codex (local, high) + OpenAI Admin (cloud, medium).
        l.ingest([obs("Codex", day: "2026-07-11", tokens: 80_000, messages: 0, confidence: .high)])
        l.ingest([obs("OpenAI Admin", day: "2026-07-11", tokens: 20_000, confidence: .medium)])
        let oa = l.familyRollup(forDay: "2026-07-11")[.openai]
        XCTAssertEqual(oa?.tokens, 100_000)
        XCTAssertEqual(oa?.confidence, .high)  // best contributor
        // Weight is PER-PROVIDER: Codex is $2/Mtok, but OpenAI Admin isn't in the
        // explicit rate table so it falls to the $1/Mtok default.
        // weighted = 80k×2_000_000 + 20k×1_000_000 = 160e9 + 20e9.
        XCTAssertEqual(oa?.weightedScore, 180_000_000_000)
    }

    // MARK: - Idempotency

    func test_ingest_is_idempotent() {
        let batch = [
            obs("Claude", day: "2026-07-10", tokens: 30_000, messages: 10, cost: 0.09),
            obs("Codex", day: "2026-07-11", tokens: 40_000, cost: 0.08),
        ]
        var a = PetDailyLedger(); a.ingest(batch)
        var b = PetDailyLedger(); b.ingest(batch); b.ingest(batch)
        // Ignore lastUpdated (not set by ingest itself); compare days.
        XCTAssertEqual(a.days, b.days)
    }

    // MARK: - Non-durable inputs rejected

    func test_delta_observations_are_not_folded() {
        var l = PetDailyLedger()
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 12_345, semantics: .delta)])
        XCTAssertTrue(l.days.isEmpty)
        XCTAssertTrue(l.familyRollup(forDay: "2026-07-11").isEmpty)
    }

    func test_low_confidence_observations_are_not_folded() {
        // .low is quota-snapshot-derived — must never become token history (F2).
        var l = PetDailyLedger()
        l.ingest([obs("Codex", day: "2026-07-11", tokens: 100_000, confidence: .low)])
        XCTAssertTrue(l.days.isEmpty)
    }

    func test_unknown_schema_version_is_not_folded() {
        var l = PetDailyLedger()
        l.ingest([PetObservation(schemaVersion: 999, providerRaw: "Claude", tokens: 50_000,
                                 messages: 0, costUSD: 0, sourceTimestampUnixMs: 1,
                                 dayKey: "2026-07-11", confidence: .high, semantics: .cumulativeToday)])
        XCTAssertTrue(l.days.isEmpty)
    }

    // MARK: - Out-of-order replay (timestamp tie-break, F3)

    func test_equal_confidence_out_of_order_replay_keeps_newest() {
        var l = PetDailyLedger()
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 100_000, confidence: .medium, ts: 200)])
        // A REPLAYED older medium value (older timestamp) must NOT regress it.
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 5_000, confidence: .medium, ts: 100)])
        XCTAssertEqual(l.dayTotals("2026-07-11").tokens, 100_000)
        // A genuinely newer medium value DOES win.
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 7_000, confidence: .medium, ts: 300)])
        XCTAssertEqual(l.dayTotals("2026-07-11").tokens, 7_000)
    }

    // MARK: - Saturation (no trap on absurd input, F5)

    func test_weighted_score_saturates_without_trapping() {
        var l = PetDailyLedger()
        // ~3.07e12 tokens × $3/Mtok micro would exceed Int64.max — must clamp,
        // not crash.
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 3_074_457_345_619)])
        let anth = l.familyRollup(forDay: "2026-07-11")[.anthropic]
        XCTAssertEqual(anth?.weightedScore, Int64.max)
        XCTAssertEqual(anth?.tokens, 3_074_457_345_619)
    }

    func test_nano_cost_conversion_saturates_without_trapping() {
        // A Double cost so large its nano-scaled value exceeds Int64 must clamp,
        // not trap the Double→Int64 conversion (Codex F5).
        XCTAssertEqual(PetObservation.nanoUSD(1e12), Int64.max)
        XCTAssertEqual(PetObservation.nanoUSD(-5), 0)
        XCTAssertEqual(PetObservation.nanoUSD(0.30), 300_000_000)
    }

    // MARK: - Lenient decode (schema resilience, F7)

    func test_slice_missing_new_fields_decodes_and_keeps_tokens() throws {
        // A slice JSON from an older shape (had `cost`, lacked `costNanoUSD` /
        // `observedAtUnixMs`) must still decode — token history survives rather
        // than the whole ledger resetting.
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = #"""
        {"version":1,"lastUpdatedUnixMs":5,"days":{"2026-07-11":{"providers":{"Claude":{"tokens":42000,"messages":7,"cost":0.3,"confidence":"high"}}}}}
        """#
        try Data(json.utf8).write(to: PetDailyLedgerIO.fileURL(root: root))
        let loaded = PetDailyLedgerIO.load(root: root)
        let slice = loaded.days["2026-07-11"]?.providers["Claude"]
        XCTAssertEqual(slice?.tokens, 42_000)       // history preserved
        XCTAssertEqual(slice?.messages, 7)
        XCTAssertEqual(slice?.costNanoUSD, 0)       // absent → 0 (not a crash/reset)
        XCTAssertEqual(slice?.observedAtUnixMs, 0)
        XCTAssertEqual(slice?.confidence, .high)
    }

    // MARK: - Window aggregation

    func test_family_rollup_over_window() {
        var l = PetDailyLedger()
        l.ingest([
            obs("Claude", day: "2026-07-09", tokens: 10_000),
            obs("Claude", day: "2026-07-10", tokens: 20_000),
            obs("Gemini", day: "2026-07-10", tokens: 5_000, confidence: .medium),
            obs("Claude", day: "2026-07-11", tokens: 30_000),
        ])
        let window = ["2026-07-09", "2026-07-10", "2026-07-11"]
        let fam = l.familyRollup(forDays: window)
        XCTAssertEqual(fam[.anthropic]?.tokens, 60_000)
        XCTAssertEqual(fam[.google]?.tokens, 5_000)
        XCTAssertEqual(fam[.anthropic]?.weightedScore, 180_000_000_000)  // 60k × $3
    }

    func test_day_totals() {
        var l = PetDailyLedger()
        l.ingest([
            obs("Claude", day: "2026-07-11", tokens: 30_000, messages: 12),
            obs("Gemini", day: "2026-07-11", tokens: 5_000, messages: 0, confidence: .medium),
        ])
        let t = l.dayTotals("2026-07-11")
        XCTAssertEqual(t.tokens, 35_000)
        XCTAssertEqual(t.messages, 12)
        XCTAssertEqual(l.dayTotals("2026-01-01").tokens, 0)   // absent day
    }

    // MARK: - Prune

    func test_prune_bounds_retained_days() {
        var l = PetDailyLedger()
        // 100 consecutive days; retain 90 ⇒ oldest 10 dropped.
        var day = "2026-01-01"
        var batch: [PetObservation] = []
        for _ in 0..<100 {
            batch.append(obs("Claude", day: day, tokens: 1_000))
            day = DailyUsageStats.nextDay(day)!
        }
        l.ingest(batch)
        XCTAssertEqual(l.days.count, 90)
        // Oldest surviving key is day 11 (2026-01-11); day 1 evicted.
        XCTAssertNil(l.days["2026-01-01"])
        XCTAssertNotNil(l.days["2026-01-11"])
        XCTAssertNotNil(l.days["2026-04-10"])   // day 100
    }

    // MARK: - IO round-trip + recovery

    func test_io_round_trip() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var l = PetDailyLedger()
        l.ingest([obs("Claude", day: "2026-07-11", tokens: 100_000, messages: 5, cost: 0.3)])
        l.lastUpdatedUnixMs = 123
        XCTAssertTrue(PetDailyLedgerIO.save(l, root: root))

        let loaded = PetDailyLedgerIO.load(root: root)
        XCTAssertEqual(loaded.days, l.days)
        XCTAssertEqual(loaded.lastUpdatedUnixMs, 123)
    }

    func test_missing_file_loads_empty() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = PetDailyLedgerIO.load(root: root)
        XCTAssertTrue(loaded.days.isEmpty)
        XCTAssertEqual(loaded.version, PetDailyLedger.currentVersion)
    }

    func test_corrupt_file_loads_empty() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: PetDailyLedgerIO.fileURL(root: root))
        XCTAssertTrue(PetDailyLedgerIO.load(root: root).days.isEmpty)
    }

    func test_version_mismatch_loads_empty() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":999,"days":{},"lastUpdatedUnixMs":0}"#.utf8)
            .write(to: PetDailyLedgerIO.fileURL(root: root))
        XCTAssertTrue(PetDailyLedgerIO.load(root: root).days.isEmpty)
    }
}
