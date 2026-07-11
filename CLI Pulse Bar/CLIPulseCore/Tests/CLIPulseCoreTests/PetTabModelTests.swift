// PetTabModelTests — v1.42 Pulse Cat M2.
// The pure snapshot the Pet tab renders: hatch status, sample, and that
// signed-out / no-data never yields a blank tab.

import XCTest
@testable import CLIPulseCore

final class PetTabModelTests: XCTestCase {

    func test_sample_snapshot_has_companion_and_diet() {
        let m = PetTabModel.sample()
        XCTAssertTrue(m.isSample)
        XCTAssertEqual(m.activeForm, .loaf)
        if case .hasCompanion(let f) = m.hatchStatus { XCTAssertEqual(f, .loaf) } else { XCTFail("expected companion") }
        XCTAssertFalse(m.diet.isEmpty)
        XCTAssertEqual(m.cattery.count, PetForm.allCases.count)
    }

    func test_fresh_qualifying_week_reads_ready_to_hatch() {
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        for k in PetRuleset.windowKeys(endingAt: "2026-07-11") { days[k] = ["Claude": .init(tokens: 20_000, messages: 10)] }
        let m = PetTabModel.build(ledger: PetFixtureSimulator.makeLedger(days),
                                  state: PetState(), todayKey: "2026-07-11", nowUnixMs: 1, isSample: false)
        if case .readyToHatch(let f) = m.hatchStatus { XCTAssertEqual(f, .loaf) } else { XCTFail("expected readyToHatch") }
        XCTAssertTrue(m.decision.shouldHatch)
    }

    func test_quiet_week_reads_egg_with_stage() {
        let m = PetTabModel.build(ledger: PetDailyLedger(), state: PetState(),
                                  todayKey: "2026-07-11", nowUnixMs: 1, isSample: false)
        if case .egg(let stage) = m.hatchStatus { XCTAssertEqual(stage, .idle) } else { XCTFail("expected egg") }
        XCTAssertFalse(m.decision.shouldHatch)
    }

    func test_owned_form_week_reads_owned_this_week() {
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        for k in PetRuleset.windowKeys(endingAt: "2026-07-11") { days[k] = ["Claude": .init(tokens: 20_000, messages: 10)] }
        let m = PetTabModel.build(ledger: PetFixtureSimulator.makeLedger(days),
                                  state: PetState(ownedForms: ["loaf"]),
                                  todayKey: "2026-07-11", nowUnixMs: 1, isSample: false)
        if case .ownedThisWeek = m.hatchStatus {} else { XCTFail("expected ownedThisWeek") }
    }
}
