// PetCoordinatorTests — v1.42 Pulse Cat M1.
//
// The actor's persistence + hatch application: event-log append, replay-based
// state, corrupt-line recovery, owned-form no-op, switching, multi-week
// collection, and the one-hatch-per-week timing gate on the real path.

import XCTest
@testable import CLIPulseCore

final class PetCoordinatorTests: XCTestCase {

    private func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("pet-coord-\(UUID().uuidString)", isDirectory: true)
    }

    /// Anthropic-steady window ending `today` (7 days × 20k Claude) → hatches loaf.
    private func loafLedger(ending today: String) -> PetDailyLedger {
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        var k: String? = today
        for _ in 0..<7 { if let key = k { days[key] = ["Claude": .init(tokens: 20_000, messages: 10)]; k = DailyUsageStats.previousDay(key) } }
        return PetFixtureSimulator.makeLedger(days)
    }

    private func smashLedger(ending today: String) -> PetDailyLedger {
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        var k: String? = today
        for _ in 0..<7 { if let key = k { days[key] = ["Codex": .init(tokens: 20_000)]; k = DailyUsageStats.previousDay(key) } }
        return PetFixtureSimulator.makeLedger(days)
    }

    func test_hatch_appends_event_persists_and_replays() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coord = PetCoordinator(root: root)

        let outcome = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-11"),
                                                   todayKey: "2026-07-11", nowUnixMs: 1_000)
        XCTAssertEqual(outcome.hatchEvent?.form, "loaf")
        XCTAssertEqual(outcome.decision.hatchedForm, .loaf)
        XCTAssertNotNil(outcome.hatchEvent?.whySnapshot)   // frozen "why hatched"
        XCTAssertEqual(outcome.state.ownedForms, ["loaf"])
        XCTAssertEqual(outcome.state.activeForm, "loaf")   // first pet auto-active
        XCTAssertEqual(outcome.state.lastHatchDayKey, "2026-07-11")

        // A fresh coordinator on the same root replays the log to the same state.
        let reloaded = PetCoordinator(root: root)
        let state = await reloaded.state()
        XCTAssertEqual(state.ownedForms, ["loaf"])
        XCTAssertEqual(state.activeForm, "loaf")
    }

    func test_owned_form_week_does_not_hatch() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coord = PetCoordinator(root: root)
        // Hatch loaf, then re-evaluate the SAME kind of week 7+ days later.
        _ = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-11"), todayKey: "2026-07-11", nowUnixMs: 1)
        let again = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-20"), todayKey: "2026-07-20", nowUnixMs: 2)
        XCTAssertNil(again.hatchEvent)                     // egg waits, no new event
        XCTAssertTrue(again.decision.alreadyOwnedThisWeek)
        XCTAssertEqual(again.state.ownedForms, ["loaf"])   // unchanged
    }

    func test_one_hatch_per_week_timing_gate() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coord = PetCoordinator(root: root)
        _ = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-11"), todayKey: "2026-07-11", nowUnixMs: 1)
        // A DIFFERENT qualifying form the very next day must NOT hatch (timing).
        let next = await coord.evaluateAndHatch(ledger: smashLedger(ending: "2026-07-12"), todayKey: "2026-07-12", nowUnixMs: 2)
        XCTAssertNil(next.hatchEvent)
        XCTAssertFalse(next.decision.timingAllows)
        XCTAssertEqual(next.state.ownedForms, ["loaf"])
    }

    func test_multi_week_collection() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coord = PetCoordinator(root: root)
        _ = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-11"), todayKey: "2026-07-11", nowUnixMs: 1)
        let wk2 = await coord.evaluateAndHatch(ledger: smashLedger(ending: "2026-07-18"), todayKey: "2026-07-18", nowUnixMs: 2)
        XCTAssertEqual(wk2.hatchEvent?.form, "smash")
        XCTAssertEqual(wk2.state.ownedForms, ["loaf", "smash"])
        XCTAssertEqual(wk2.state.activeForm, "loaf")       // first pet stays active
    }

    func test_set_active_form_only_if_owned() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coord = PetCoordinator(root: root)
        _ = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-11"), todayKey: "2026-07-11", nowUnixMs: 1)
        _ = await coord.evaluateAndHatch(ledger: smashLedger(ending: "2026-07-18"), todayKey: "2026-07-18", nowUnixMs: 2)

        // Switch to an un-owned form → no-op.
        var s = await coord.setActiveForm(.pop, todayKey: "2026-07-18", nowUnixMs: 3)
        XCTAssertEqual(s.activeForm, "loaf")
        // Switch to an owned form → updates + persists.
        s = await coord.setActiveForm(.smash, todayKey: "2026-07-18", nowUnixMs: 4)
        XCTAssertEqual(s.activeForm, "smash")
        let reloaded = PetCoordinator(root: root)
        let rs = await reloaded.state()
        XCTAssertEqual(rs.activeForm, "smash")
    }

    func test_corrupt_log_line_is_skipped_on_replay() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A valid hatch, a garbage line, then another valid hatch.
        let valid1 = try JSONEncoder().encode(PetEvent(kind: .hatch, dayKey: "2026-07-11", timestampUnixMs: 1, form: "loaf"))
        let valid2 = try JSONEncoder().encode(PetEvent(kind: .hatch, dayKey: "2026-07-18", timestampUnixMs: 2, form: "smash"))
        var blob = Data(); blob.append(valid1); blob.append(0x0A)
        blob.append(Data("{ not json\n".utf8))
        blob.append(valid2); blob.append(0x0A)
        try blob.write(to: PetCoordinator.eventsURL(root: root))

        let events = PetCoordinator.readEventLog(root: root)
        XCTAssertEqual(events.count, 2)                    // garbage line dropped
        let state = PetCoordinator.rebuild(from: events)
        XCTAssertEqual(state.ownedForms, ["loaf", "smash"])
    }

    func test_non_utf8_corrupt_line_does_not_wipe_history() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // valid loaf hatch \n <raw 0xFF byte> \n valid smash hatch \n
        let v1 = try JSONEncoder().encode(PetEvent(kind: .hatch, dayKey: "2026-07-11", timestampUnixMs: 1, form: "loaf"))
        let v2 = try JSONEncoder().encode(PetEvent(kind: .hatch, dayKey: "2026-07-18", timestampUnixMs: 2, form: "smash"))
        var blob = Data(); blob.append(v1); blob.append(0x0A)
        blob.append(0xFF); blob.append(0x0A)          // non-UTF-8 garbage line
        blob.append(v2); blob.append(0x0A)
        try blob.write(to: PetCoordinator.eventsURL(root: root))

        let events = PetCoordinator.readEventLog(root: root)
        XCTAssertEqual(events.count, 2)               // garbage byte line dropped, not the whole log
        XCTAssertEqual(PetCoordinator.rebuild(from: events).ownedForms, ["loaf", "smash"])
    }

    func test_unknown_future_schema_line_is_preserved_across_append() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A v1 hatch + a future v2 line (unknown schema) an older app can't decode.
        let v1 = try JSONEncoder().encode(PetEvent(kind: .hatch, dayKey: "2026-07-11", timestampUnixMs: 1, form: "loaf"))
        let futureLine = Data(#"{"schemaVersion":99,"kind":"teleport","dayKey":"2026-07-15","timestampUnixMs":5}"#.utf8)
        var blob = Data(); blob.append(v1); blob.append(0x0A); blob.append(futureLine); blob.append(0x0A)
        try blob.write(to: PetCoordinator.eventsURL(root: root))

        // A v1 coordinator hatches a new form (physical append, no rewrite).
        let coord = PetCoordinator(root: root)
        _ = await coord.evaluateAndHatch(ledger: smashLedger(ending: "2026-07-25"), todayKey: "2026-07-25", nowUnixMs: 9)

        // The unknown v2 line must still be present byte-for-byte.
        let raw = try String(contentsOf: PetCoordinator.eventsURL(root: root), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"schemaVersion\":99"), "future-schema line must survive append")
        XCTAssertTrue(raw.contains("teleport"))
        // And the decoded state ignores the unknown line but keeps loaf + smash.
        let events = PetCoordinator.readEventLog(root: root)
        XCTAssertEqual(PetCoordinator.rebuild(from: events).ownedForms, ["loaf", "smash"])
    }

    func test_append_inserts_separator_when_file_lacks_trailing_newline() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A prior valid hatch written WITHOUT a trailing newline (partial write).
        let noNL = try JSONEncoder().encode(PetEvent(kind: .hatch, dayKey: "2026-07-11", timestampUnixMs: 1, form: "loaf"))
        try noNL.write(to: PetCoordinator.eventsURL(root: root))   // no 0x0A at end

        // Appending a new hatch must NOT merge onto the previous line.
        let coord = PetCoordinator(root: root)
        _ = await coord.evaluateAndHatch(ledger: smashLedger(ending: "2026-07-25"), todayKey: "2026-07-25", nowUnixMs: 9)
        let events = PetCoordinator.readEventLog(root: root)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(PetCoordinator.rebuild(from: events).ownedForms, ["loaf", "smash"])
    }

    func test_persist_failure_does_not_falsely_commit_hatch() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // root's parent is a regular FILE → createDirectory(at: root) fails.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let badRoot = blocker.appendingPathComponent("sub")   // under a file → unwritable

        let coord = PetCoordinator(root: badRoot)
        let out = await coord.evaluateAndHatch(ledger: loafLedger(ending: "2026-07-11"), todayKey: "2026-07-11", nowUnixMs: 1)
        XCTAssertNil(out.hatchEvent)                  // write failed → no false hatch
        XCTAssertTrue(out.state.ownedForms.isEmpty)
        // A fresh coordinator replays nothing (nothing was durably written).
        let fresh = PetCoordinator(root: badRoot)
        let s = await fresh.state()
        XCTAssertTrue(s.ownedForms.isEmpty)
    }

    func test_no_hatch_writes_no_event() async {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let coord = PetCoordinator(root: root)
        // Unqualified week → nothing persisted.
        var days: [String: [String: PetFixtureSimulator.Usage]] = [
            "2026-07-10": ["Claude": .init(tokens: 30_000)],
            "2026-07-11": ["Claude": .init(tokens: 30_000)],
        ]
        _ = days
        let led = PetFixtureSimulator.makeLedger(days)
        let out = await coord.evaluateAndHatch(ledger: led, todayKey: "2026-07-11", nowUnixMs: 1)
        XCTAssertNil(out.hatchEvent)
        XCTAssertTrue(out.state.ownedForms.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: PetCoordinator.eventsURL(root: root).path))
    }
}
