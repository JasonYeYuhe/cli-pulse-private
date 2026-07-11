// PetRulesetTests — v1.42 Pulse Cat M1.
// The 6-form table, window construction, and active-day gate.

import XCTest
@testable import CLIPulseCore

final class PetRulesetTests: XCTestCase {

    func test_form_table_is_exhaustive_and_correct() {
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .anthropic, tempo: .steady), .loaf)
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .anthropic, tempo: .burst), .polite)
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .openai, tempo: .steady), .smash)
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .openai, tempo: .burst), .pop)
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .google, tempo: .steady), .long)
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .google, tempo: .burst), .long)   // catch-all
        XCTAssertEqual(PetRuleset.resolveForm(dominant: .other, tempo: .steady), .huh)
        XCTAssertEqual(PetRuleset.resolveForm(dominant: nil, tempo: .steady), .huh)        // no dominant
        XCTAssertEqual(PetRuleset.resolveForm(dominant: nil, tempo: .burst), .huh)
    }

    func test_form_family_mapping_round_trips() {
        // Each form's declared family matches the branch that produces it.
        XCTAssertEqual(PetForm.loaf.family, .anthropic)
        XCTAssertEqual(PetForm.pop.family, .openai)
        XCTAssertEqual(PetForm.long.family, .google)
        XCTAssertEqual(PetForm.huh.family, .other)
    }

    func test_window_keys_are_seven_contiguous_ascending() {
        let keys = PetRuleset.windowKeys(endingAt: "2026-07-11")
        XCTAssertEqual(keys, ["2026-07-05", "2026-07-06", "2026-07-07", "2026-07-08",
                              "2026-07-09", "2026-07-10", "2026-07-11"])
    }

    func test_window_keys_span_dst_boundary_without_gap() {
        let keys = PetRuleset.windowKeys(endingAt: "2026-03-09")   // US spring-forward 03-08
        XCTAssertEqual(keys.first, "2026-03-03")
        XCTAssertEqual(keys.last, "2026-03-09")
        XCTAssertEqual(Set(keys).count, 7)
    }

    func test_active_day_hybrid_gate() {
        XCTAssertTrue(PetRuleset.isActiveDay(tokens: 20_000, messages: 0))   // token gate
        XCTAssertTrue(PetRuleset.isActiveDay(tokens: 0, messages: 5))        // message gate
        XCTAssertTrue(PetRuleset.isActiveDay(tokens: 19_999, messages: 5))   // either suffices
        XCTAssertFalse(PetRuleset.isActiveDay(tokens: 19_999, messages: 4))  // neither
    }

    func test_future_drop_forms_never_rule_hatch() {
        // The v1 ruleset's range is EXACTLY the 6-form hatch pool: every
        // (dominant, tempo) combination resolves inside it, so future-drop
        // forms (sulk/wail/chonk/boss/smug) can never hatch until a ruleset
        // revision maps them — they are "coming soon" collection teasers.
        XCTAssertEqual(PetForm.v1HatchPool, [.loaf, .polite, .smash, .pop, .long, .huh])
        for dominant in [PetFamily.anthropic, .openai, .google, .other] {
            for tempo in PetTempo.allCases {
                XCTAssertTrue(PetRuleset.resolveForm(dominant: dominant, tempo: tempo).isInHatchPool)
            }
        }
        for tempo in PetTempo.allCases {
            XCTAssertTrue(PetRuleset.resolveForm(dominant: nil, tempo: tempo).isInHatchPool)
        }
        for f in PetForm.allCases where !f.isInHatchPool {
            XCTAssertEqual(f.family, .other, "future drops stay provider-neutral until mapped")
        }
    }
}
