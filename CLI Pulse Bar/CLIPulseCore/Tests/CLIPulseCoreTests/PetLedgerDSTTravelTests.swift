// PetLedgerDSTTravelTests — v1.42 Pulse Cat M0.
//
// The pet's hatch window is a trailing 7-day slice, so day-key handling must be
// immune to DST (23h/25h days) and timezone travel (Flash F7). Two guarantees:
//  1. FROZEN KEYS: the ledger buckets purely by the producer's `dayKey` string
//     and never re-derives a day from a timestamp on read — so travel can't
//     retroactively move past usage between days at the ledger layer. (The
//     upstream scanner-rescan-under-travel caveat is documented on
//     PetObservation.dayKey and is out of M0 scope.)
//  2. UTC-FIXED ARITHMETIC: window keys come from `DailyUsageStats.shift`, whose
//     parse+format share a fixed UTC calendar, so shifting across a DST boundary
//     yields contiguous keys with no duplicate or skipped day.

import XCTest
@testable import CLIPulseCore

final class PetLedgerDSTTravelTests: XCTestCase {

    /// Trailing `count`-day window ending at `end`, oldest→newest — the same
    /// UTC-fixed shift the engine (M1) will use.
    private func window(endingAt end: String, count: Int) -> [String] {
        var keys: [String] = []
        var k: String? = end
        for _ in 0..<count { if let key = k { keys.append(key); k = DailyUsageStats.previousDay(key) } }
        return keys.reversed()
    }

    // MARK: - Frozen keys

    func test_ledger_buckets_by_frozen_key_not_by_recomputed_day() {
        // Same absolute instant near a UTC midnight resolves to DIFFERENT local
        // days depending on timezone. The scanner freezes the day it observed;
        // the ledger must honor that frozen key, not re-bucket on read.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = utc.date(from: DateComponents(year: 2026, month: 3, day: 21, hour: 1))!

        let shanghai = calendar("Asia/Shanghai")   // UTC+8 → still the 21st
        let honolulu = calendar("Pacific/Honolulu") // UTC-10 → the 20th
        let keyCN = DailyUsageStats.localDayKey(instant, calendar: shanghai)
        let keyHI = DailyUsageStats.localDayKey(instant, calendar: honolulu)
        XCTAssertEqual(keyCN, "2026-03-21")
        XCTAssertEqual(keyHI, "2026-03-20")
        XCTAssertNotEqual(keyCN, keyHI, "precondition: the instant straddles a day boundary")

        // Two observations for the SAME instant but the frozen keys each locale
        // produced stay in SEPARATE buckets — no retroactive merge on travel.
        let ts = Int64(instant.timeIntervalSince1970 * 1000)
        var l = PetDailyLedger()
        l.ingest([
            PetObservation(providerRaw: "Claude", tokens: 10_000, messages: 0, costUSD: 0,
                           sourceTimestampUnixMs: ts, dayKey: keyHI, confidence: .high, semantics: .cumulativeToday),
            PetObservation(providerRaw: "Claude", tokens: 20_000, messages: 0, costUSD: 0,
                           sourceTimestampUnixMs: ts, dayKey: keyCN, confidence: .high, semantics: .cumulativeToday),
        ])
        XCTAssertEqual(l.dayTotals("2026-03-20").tokens, 10_000)
        XCTAssertEqual(l.dayTotals("2026-03-21").tokens, 20_000)
    }

    // MARK: - DST-safe window arithmetic

    func test_window_across_spring_forward_is_contiguous() {
        // US spring-forward 2026 = Sun Mar 8 (a 23-hour local day). A trailing-7
        // window ending Mar 9 must be 7 unique, contiguous, ascending keys.
        let keys = window(endingAt: "2026-03-09", count: 7)
        XCTAssertEqual(keys, ["2026-03-03", "2026-03-04", "2026-03-05", "2026-03-06",
                              "2026-03-07", "2026-03-08", "2026-03-09"])
        XCTAssertEqual(Set(keys).count, 7, "no duplicate day across the DST boundary")
    }

    func test_window_across_fall_back_and_month_boundary_is_contiguous() {
        // US fall-back 2026 = Sun Nov 1 (25h); window ending Nov 2 crosses both
        // the DST boundary and the Oct→Nov month boundary.
        let keys = window(endingAt: "2026-11-02", count: 7)
        XCTAssertEqual(keys, ["2026-10-27", "2026-10-28", "2026-10-29", "2026-10-30",
                              "2026-10-31", "2026-11-01", "2026-11-02"])
    }

    func test_window_aggregation_over_dst_boundary() {
        var l = PetDailyLedger()
        l.ingest([
            obs("2026-03-07", 10_000),
            obs("2026-03-08", 25_000),   // the DST day
            obs("2026-03-09", 30_000),
        ])
        let fam = l.familyRollup(forDays: window(endingAt: "2026-03-09", count: 7))
        XCTAssertEqual(fam[.anthropic]?.tokens, 65_000)  // all three days summed once
    }

    // MARK: - Lexical == chronological ordering (prune correctness)

    func test_lexical_key_order_is_chronological_across_year_boundary() {
        var l = PetDailyLedger()
        // Feed 95 consecutive days straddling a year boundary; retain 90 ⇒ the 5
        // truly-oldest (chronologically) must be the ones evicted.
        var day = "2025-12-01"
        var batch: [PetObservation] = []
        for _ in 0..<95 { batch.append(obs(day, 1_000)); day = DailyUsageStats.nextDay(day)! }
        l.ingest(batch)
        XCTAssertEqual(l.days.count, 90)
        for evicted in ["2025-12-01", "2025-12-02", "2025-12-03", "2025-12-04", "2025-12-05"] {
            XCTAssertNil(l.days[evicted], "\(evicted) should be evicted as oldest")
        }
        XCTAssertNotNil(l.days["2025-12-06"])  // oldest surviving
        XCTAssertNotNil(l.days["2026-03-05"])  // newest (day 95)
    }

    // MARK: - Helpers

    private func calendar(_ tz: String) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c
    }

    private func obs(_ day: String, _ tokens: Int) -> PetObservation {
        PetObservation(providerRaw: "Claude", tokens: tokens, messages: 0, costUSD: 0,
                       sourceTimestampUnixMs: 0, dayKey: day, confidence: .high, semantics: .cumulativeToday)
    }
}
