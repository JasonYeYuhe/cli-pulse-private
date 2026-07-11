// PetPresentationTests — v1.42 Pulse Cat M2.
// Vitals honesty (confidence, hunger cap, awake), Usage Diet mix, Cattery,
// and the deterministic Sample Pet.

import XCTest
@testable import CLIPulseCore

final class PetPresentationTests: XCTestCase {

    private func ledger(_ days: [String: [String: PetFixtureSimulator.Usage]], updated: Int64) -> PetDailyLedger {
        var l = PetFixtureSimulator.makeLedger(days); l.lastUpdatedUnixMs = updated; return l
    }

    // MARK: Vitals

    func test_vitals_unavailable_when_no_data() {
        let v = PetVitalsEngine.compute(ledger: PetDailyLedger(), todayKey: "2026-07-11", nowUnixMs: 1_000_000)
        XCTAssertEqual(v.confidence, .unavailable)
        XCTAssertFalse(v.awake)
        XCTAssertEqual(v.energy, .sleeping)
    }

    func test_vitals_stale_reports_age_not_fake_sleep() {
        let now: Int64 = 10_000_000
        let l = ledger(["2026-07-11": ["Claude": .init(tokens: 30_000)]], updated: now - 20 * 60 * 1000) // 20m old
        let v = PetVitalsEngine.compute(ledger: l, todayKey: "2026-07-11", nowUnixMs: now)
        if case let .stale(age) = v.confidence { XCTAssertEqual(age, 1200) } else { XCTFail("expected stale") }
        XCTAssertFalse(v.awake)   // stale ⇒ not presented as awake
    }

    func test_vitals_live_and_energy_buckets() {
        let now: Int64 = 10_000_000
        func energy(_ tokens: Int) -> PetAnimationBucket {
            PetVitalsEngine.compute(ledger: ledger(["2026-07-11": ["Claude": .init(tokens: tokens)]], updated: now),
                                    todayKey: "2026-07-11", nowUnixMs: now).energy
        }
        XCTAssertEqual(energy(5_000), .idle)
        XCTAssertEqual(energy(50_000), .working)
        XCTAssertEqual(energy(300_000), .sprint)
    }

    func test_hunger_caps_at_one_no_dark_pattern() {
        let now: Int64 = 10_000_000
        // A huge day can't push hunger past 1.0 (burning more does nothing).
        let l = ledger(["2026-07-11": ["Claude": .init(tokens: 5_000_000)]], updated: now)
        let v = PetVitalsEngine.compute(ledger: l, todayKey: "2026-07-11", nowUnixMs: now)
        XCTAssertEqual(v.hunger, 1.0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(v.hungerBaseline, PetVitalsEngine.hungerBaselineCap)
    }

    // MARK: Usage Diet

    func test_usage_diet_exact_family_mix() {
        // Claude 60k×$3 = 180 units, Codex 60k×$2 = 120, over the window.
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        for k in PetRuleset.windowKeys(endingAt: "2026-07-11") {
            days[k] = ["Claude": .init(tokens: 60_000), "Codex": .init(tokens: 60_000)]
        }
        let diet = PetUsageDiet.compute(ledger: PetFixtureSimulator.makeLedger(days), todayKey: "2026-07-11")
        XCTAssertEqual(diet.first?.family, .anthropic)        // higher weighted share sorts first
        XCTAssertEqual(diet.map(\.family), [.anthropic, .openai])
        XCTAssertEqual(diet[0].percent, 60, accuracy: 0.01)   // 180/(180+120)
        XCTAssertEqual(diet[1].percent, 40, accuracy: 0.01)
    }

    func test_usage_diet_empty_when_no_usage() {
        XCTAssertTrue(PetUsageDiet.compute(ledger: PetDailyLedger(), todayKey: "2026-07-11").isEmpty)
    }

    // MARK: Cattery

    func test_cattery_reflects_ownership() {
        let state = PetState(ownedForms: ["loaf"], ownedDayKeys: ["loaf": "2026-07-01"], activeForm: "loaf")
        let entries = PetCattery.entries(state: state)
        XCTAssertEqual(entries.count, PetForm.allCases.count)
        let loaf = entries.first { $0.form == .loaf }
        XCTAssertEqual(loaf?.owned, true)
        XCTAssertEqual(loaf?.isActive, true)
        XCTAssertEqual(loaf?.ownedDayKey, "2026-07-01")
        XCTAssertEqual(entries.first { $0.form == .pop }?.owned, false)
        XCTAssertEqual(PetCattery.ownedCount(state: state), 1)
    }

    // MARK: Sample Pet (deterministic)

    func test_sample_pet_is_deterministic() {
        XCTAssertEqual(PetSampleData.ledger().days, PetSampleData.ledger().days)   // stable
        XCTAssertEqual(PetSampleData.state().ownedForms, ["loaf", "smash"])
        let v = PetSampleData.vitals()
        XCTAssertEqual(v.confidence, .live)                  // sample is "fresh" by construction
        XCTAssertFalse(PetSampleData.diet().isEmpty)
        XCTAssertEqual(PetSampleData.cattery().count, PetForm.allCases.count)
        XCTAssertEqual(PetSampleData.diet().first?.family, .anthropic)   // Anthropic-leaning
    }
}
