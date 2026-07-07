// Unit tests for the v1.40 PR-6 providerColor backfill + near-black luminance
// lift. Locks the key guarantee: NO provider produces a near-invisible color on
// the dark frosted-glass panels (the reason gray/near-black was a bug).

import XCTest
import SwiftUI
@testable import CLIPulseCore

final class ProviderColorTests: XCTestCase {

    private func lum255(_ c: (r: Double, g: Double, b: Double)) -> Double {
        (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) * 255
    }

    func test_lift_raises_pure_black_and_leaves_bright_unchanged() {
        let black = PulseTheme.liftedRGB((0, 0, 0))
        XCTAssertEqual(black.r, 205.0 * 0.62 / 255.0, accuracy: 0.01)   // ~0.498
        XCTAssertEqual(black.g, black.r, accuracy: 0.0001)

        let bright = PulseTheme.liftedRGB((0.8, 0.5, 0.4))
        XCTAssertEqual(bright.r, 0.8, accuracy: 0.0001)
        XCTAssertEqual(bright.g, 0.5, accuracy: 0.0001)
        XCTAssertEqual(bright.b, 0.4, accuracy: 0.0001)
    }

    func test_grok_is_near_black_raw_but_visible_after_lift() {
        let raw = PulseTheme.rawProviderRGBForTesting("Grok")
        XCTAssertLessThan(lum255(raw), 42, "Grok's raw brand is near-black")
        let lifted = PulseTheme.liftedRGB(raw)
        XCTAssertGreaterThan(lum255(lifted), 100, "must be lifted to visible")
    }

    func test_unknown_provider_defaults_to_blue_not_gray() {
        let raw = PulseTheme.rawProviderRGBForTesting("TotallyUnknownProviderXYZ")
        // token-monitor default #6AB4F0
        XCTAssertEqual(raw.r, Double(0x6A) / 255, accuracy: 0.01)
        XCTAssertEqual(raw.g, Double(0xB4) / 255, accuracy: 0.01)
        XCTAssertEqual(raw.b, Double(0xF0) / 255, accuracy: 0.01)
        XCTAssertGreaterThan(raw.b, raw.r, "default is bluish, not gray")
    }

    func test_claude_matches_token_monitor_terracotta() {
        let raw = PulseTheme.rawProviderRGBForTesting("Claude")
        XCTAssertEqual(raw.r, Double(0xCC) / 255, accuracy: 0.01)
        XCTAssertEqual(raw.g, Double(0x7C) / 255, accuracy: 0.01)
        XCTAssertEqual(raw.b, Double(0x5E) / 255, accuracy: 0.01)
    }

    /// The whole point of the backfill: every provider is legible on dark glass.
    func test_every_provider_is_visible_on_dark_glass() {
        for kind in ProviderKind.allCases {
            let lifted = PulseTheme.liftedRGB(PulseTheme.rawProviderRGBForTesting(kind.rawValue))
            XCTAssertGreaterThanOrEqual(lum255(lifted), 42,
                                        "\(kind.rawValue) is too dark to see on dark glass")
        }
    }
}
