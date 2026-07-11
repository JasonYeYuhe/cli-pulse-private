// PetEngineTests — v1.42 Pulse Cat M1.
// timingAllows boundaries (incl. clock rollback), applyHatch, egg stages.

import XCTest
@testable import CLIPulseCore

final class PetEngineTests: XCTestCase {

    func test_timing_allows_boundaries() {
        // Never hatched → always allowed.
        XCTAssertTrue(PetEngine.timingAllows(lastHatchDayKey: nil, todayKey: "2026-07-11"))
        // 6 days later → blocked; 7 → allowed; 8 → allowed.
        XCTAssertFalse(PetEngine.timingAllows(lastHatchDayKey: "2026-07-05", todayKey: "2026-07-11"))
        XCTAssertTrue(PetEngine.timingAllows(lastHatchDayKey: "2026-07-04", todayKey: "2026-07-11"))
        XCTAssertTrue(PetEngine.timingAllows(lastHatchDayKey: "2026-07-03", todayKey: "2026-07-11"))
    }

    func test_timing_disallows_clock_rollback() {
        // "now" is BEFORE the last hatch (backward travel / clock reset) → blocked.
        XCTAssertFalse(PetEngine.timingAllows(lastHatchDayKey: "2026-07-20", todayKey: "2026-07-11"))
    }

    func test_timing_across_dst_and_month_boundary() {
        // 7 days spanning spring-forward: 2026-03-02 + 7 = 2026-03-09.
        XCTAssertTrue(PetEngine.timingAllows(lastHatchDayKey: "2026-03-02", todayKey: "2026-03-09"))
        XCTAssertFalse(PetEngine.timingAllows(lastHatchDayKey: "2026-03-02", todayKey: "2026-03-08"))
    }

    func test_apply_hatch_adds_and_auto_activates_first() {
        var s = PetState()
        s = PetEngine.applyHatch(.loaf, on: s, dayKey: "2026-07-11")
        XCTAssertEqual(s.ownedForms, ["loaf"])
        XCTAssertEqual(s.activeForm, "loaf")           // first pet auto-active
        XCTAssertEqual(s.ownedDayKeys["loaf"], "2026-07-11")
        XCTAssertEqual(s.lastHatchDayKey, "2026-07-11")

        s = PetEngine.applyHatch(.smash, on: s, dayKey: "2026-07-18")
        XCTAssertEqual(s.ownedForms, ["loaf", "smash"])
        XCTAssertEqual(s.activeForm, "loaf")           // stays on the first
        XCTAssertEqual(s.lastHatchDayKey, "2026-07-18")
    }

    func test_apply_hatch_owned_form_is_noop() {
        var s = PetState(ownedForms: ["loaf"], ownedDayKeys: ["loaf": "2026-07-01"],
                         activeForm: "loaf", lastHatchDayKey: "2026-07-01")
        let before = s
        s = PetEngine.applyHatch(.loaf, on: s, dayKey: "2026-07-11")
        XCTAssertEqual(s, before)                      // unchanged
    }

    func test_egg_stage_from_active_days() {
        XCTAssertEqual(PetEggStage.forActiveDays(0), .idle)
        XCTAssertEqual(PetEggStage.forActiveDays(1), .crack1)
        XCTAssertEqual(PetEggStage.forActiveDays(2), .crack2)
        XCTAssertEqual(PetEggStage.forActiveDays(3), .crack3)
        XCTAssertEqual(PetEggStage.forActiveDays(7), .crack3)   // caps at crack3
        XCTAssertEqual(PetEggStage.forActiveDays(-1), .idle)    // clamps
    }

    func test_state_lenient_decode_tolerates_missing_fields() throws {
        // A state JSON with only ownedForms (future/older shape) still decodes.
        let json = #"{"ownedForms":["loaf","smash"]}"#
        let s = try JSONDecoder().decode(PetState.self, from: Data(json.utf8))
        XCTAssertEqual(s.ownedForms, ["loaf", "smash"])
        XCTAssertEqual(s.version, PetState.currentVersion)
        XCTAssertNil(s.activeForm)
    }
}
