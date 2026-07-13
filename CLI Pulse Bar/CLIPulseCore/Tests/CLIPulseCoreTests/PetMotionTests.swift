// PetMotionTests — v1.42 Pulse Cat: per-form signature idle motions.
// Every form has a distinct, subtle, render-server idle motion within bounds;
// the egg only breathes; content resolves to the right form's motion.

import XCTest
@testable import CLIPulseCore

final class PetMotionTests: XCTestCase {

    func test_every_form_has_a_bounded_render_server_idle_motion() {
        for form in PetForm.allCases {
            let channels = form.idleMotion
            XCTAssertFalse(channels.isEmpty, "\(form) has no idle motion")
            for ch in channels {
                // Must be a transform key path → render-server (no per-frame CPU wake).
                XCTAssertTrue(ch.axis.rawValue.hasPrefix("transform."), "\(form): \(ch.axis) not a transform")
                // Amplitude stays subtle (reads as alive, not hyperactive; no clipping).
                switch ch.axis {
                case .scale, .scaleX, .scaleY:
                    XCTAssertLessThanOrEqual(max(ch.from, ch.to), PetMotion.maxScale, "\(form) scale too big")
                    XCTAssertGreaterThanOrEqual(min(ch.from, ch.to), 1.0 / PetMotion.maxScale, "\(form) scale too small")
                case .rotation:
                    XCTAssertLessThanOrEqual(abs(ch.from), PetMotion.maxRotationRadians, "\(form) rotation too big")
                    XCTAssertLessThanOrEqual(abs(ch.to), PetMotion.maxRotationRadians, "\(form) rotation too big")
                case .translateX, .translateY:
                    XCTAssertLessThanOrEqual(abs(ch.from), PetMotion.maxTranslationPoints, "\(form) translation too big")
                    XCTAssertLessThanOrEqual(abs(ch.to), PetMotion.maxTranslationPoints, "\(form) translation too big")
                }
                XCTAssertGreaterThanOrEqual(ch.periodSec, PetMotion.minPeriodSec, "\(form) too fast")
                XCTAssertLessThanOrEqual(ch.periodSec, PetMotion.maxPeriodSec, "\(form) too slow")
                XCTAssertNotEqual(ch.from, ch.to, "\(form) motionless channel")
            }
        }
    }

    func test_egg_rests_with_a_calm_breath() {
        // Pre-hatch, the egg only breathes (a generic scale pulse) — never a cat's
        // personality it hasn't earned.
        let egg = PetMotion.channels(for: .egg(stage: .idle))
        XCTAssertEqual(egg, PetMotion.egg)
        XCTAssertEqual(egg.count, 1)
        XCTAssertEqual(egg.first?.axis, .scale)
    }

    func test_cat_content_uses_its_form_motion() {
        XCTAssertEqual(PetMotion.channels(for: .cat(.huh)), PetForm.huh.idleMotion)
        XCTAssertEqual(PetForm.huh.idleMotion.first?.axis, .rotation)     // head-tilt "huh?"
        XCTAssertEqual(PetForm.smash.idleMotion.first?.axis, .translateY) // energetic bounce
        XCTAssertEqual(PetForm.chonk.idleMotion.count, 2)                 // squash = 2 channels
    }

    func test_motions_span_multiple_axes() {
        // The pool spans several transform axes so the cats don't all look alike.
        let axes = Set(PetForm.allCases.flatMap { $0.idleMotion.map(\.axis) })
        XCTAssertGreaterThanOrEqual(axes.count, 4, "idle motions should span ≥4 transform axes")
    }
}
