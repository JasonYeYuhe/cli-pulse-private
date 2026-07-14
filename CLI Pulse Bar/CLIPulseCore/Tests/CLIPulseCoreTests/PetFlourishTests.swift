// PetFlourishTests — v1.42 Pulse Cat: one-shot celebratory reactions.
// Every flourish is a bounded, clip-safe, render-server one-shot that SETTLES
// back to rest (so the pet doesn't end mid-pose).

import XCTest
@testable import CLIPulseCore

final class PetFlourishTests: XCTestCase {

    private func rest(_ axis: PetMotionChannel.Axis) -> Double {
        switch axis {
        case .scale, .scaleX, .scaleY: return 1.0
        case .rotation, .translateX, .translateY: return 0.0
        }
    }

    func test_flourishes_are_bounded_one_shots_that_settle() {
        XCTAssertGreaterThanOrEqual(PetFlourish.allCases.count, 3)
        for f in PetFlourish.allCases {
            XCTAssertGreaterThan(f.durationSec, 0, "\(f) duration")
            XCTAssertLessThanOrEqual(f.durationSec, PetFlourish.maxDurationSec, "\(f) too long")
            XCTAssertFalse(f.channels.isEmpty, "\(f) has no channels")
            XCTAssertLessThanOrEqual(f.channels.count, 2, "\(f) too many channels")
            for ch in f.channels {
                XCTAssertTrue(ch.axis.rawValue.hasPrefix("transform."), "\(f): \(ch.axis) not a transform")
                XCTAssertGreaterThanOrEqual(ch.keyframes.count, 2, "\(f)/\(ch.axis) too few keyframes")
                // keyTimes (if present) must align with the values: same count,
                // ascending, spanning 0…1.
                if let kt = ch.keyTimes {
                    XCTAssertEqual(kt.count, ch.keyframes.count, "\(f)/\(ch.axis) keyTimes count")
                    XCTAssertEqual(kt.first!, 0, accuracy: 1e-9, "\(f)/\(ch.axis) keyTimes start")
                    XCTAssertEqual(kt.last!, 1, accuracy: 1e-9, "\(f)/\(ch.axis) keyTimes end")
                    XCTAssertEqual(kt, kt.sorted(), "\(f)/\(ch.axis) keyTimes ascending")
                }
                let r = rest(ch.axis)
                XCTAssertEqual(ch.keyframes.first!, r, accuracy: 1e-9, "\(f)/\(ch.axis) must START at rest")
                // Ends at rest — a rotation may end at a full 2π turn (≡ rest angle).
                let last = ch.keyframes.last!
                if ch.axis == .rotation {
                    let m = abs(last.truncatingRemainder(dividingBy: 2 * Double.pi))
                    XCTAssertEqual(min(m, abs(m - 2 * Double.pi)), 0, accuracy: 1e-9, "\(f) rotation must SETTLE")
                } else {
                    XCTAssertEqual(last, r, accuracy: 1e-9, "\(f)/\(ch.axis) must END at rest")
                }
                // Clip-safe amplitude bounds.
                for v in ch.keyframes {
                    switch ch.axis {
                    case .scale, .scaleX, .scaleY:
                        XCTAssertLessThanOrEqual(v, PetFlourish.maxScale, "\(f) scale too big")
                        XCTAssertGreaterThanOrEqual(v, PetFlourish.minScale, "\(f) scale too small")
                    case .rotation:
                        XCTAssertLessThanOrEqual(abs(v), 2 * Double.pi + 1e-9, "\(f) rotation too big")
                    case .translateX, .translateY:
                        XCTAssertLessThanOrEqual(abs(v), PetFlourish.maxTranslationPoints, "\(f) translation too big")
                    }
                }
            }
        }
    }

    func test_flourishes_are_distinct() {
        // The named flourishes are not all the same animation.
        let sigs = Set(PetFlourish.allCases.map { f in
            f.channels.map { "\($0.axis.rawValue):\($0.keyframes)" }.joined(separator: "|")
        })
        XCTAssertEqual(sigs.count, PetFlourish.allCases.count, "each flourish should be distinct")
    }
}
