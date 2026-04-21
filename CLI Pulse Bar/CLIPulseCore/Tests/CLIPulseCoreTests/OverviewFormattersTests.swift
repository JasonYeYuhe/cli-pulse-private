import XCTest
import SwiftUI
@testable import CLIPulseCore

/// P2-1 pilot: pin behavior of the formatter helpers shared by macOS
/// `OverviewTab` and iOS `iOSOverviewTab` so de-duplication can't change
/// a platform's observable rendering.
///
/// Note on timezone: the hour-label formatter intentionally uses the
/// device's local timezone (pre-existing behavior from both platforms).
/// These tests therefore assert the SHAPE of the output, not a specific
/// hour, and cross-check parsed vs. fallback paths rather than hardcoding
/// "3pm" which would only hold in UTC.
final class OverviewFormattersTests: XCTestCase {

    // MARK: - utilizationColor

    func testUtilizationColorThresholds() {
        XCTAssertEqual(OverviewFormatters.utilizationColor(0),   .gray)
        XCTAssertEqual(OverviewFormatters.utilizationColor(49),  .gray)
        XCTAssertEqual(OverviewFormatters.utilizationColor(50),  .green)
        XCTAssertEqual(OverviewFormatters.utilizationColor(99),  .green)
        XCTAssertEqual(OverviewFormatters.utilizationColor(100), .blue)
        XCTAssertEqual(OverviewFormatters.utilizationColor(199), .blue)
        XCTAssertEqual(OverviewFormatters.utilizationColor(200), .purple)
        XCTAssertEqual(OverviewFormatters.utilizationColor(500), .purple)
    }

    func testUtilizationColorNegativeTreatedAsGray() {
        XCTAssertEqual(OverviewFormatters.utilizationColor(-5), .gray)
    }

    // MARK: - hourLabel — shape + parse-path vs fallback-path

    /// ISO-parsed labels match the "Ha" DateFormatter convention: either
    /// "<N>am" / "<N>pm" (1–12 for 12h cycle).
    func testHourLabelIsoFractionalReturnsLowercaseAmPm() {
        let label = OverviewFormatters.hourLabel("2026-04-21T15:30:45.123Z")
        XCTAssertTrue(label.hasSuffix("am") || label.hasSuffix("pm"),
                      "expected am/pm suffix, got \(label)")
        XCTAssertEqual(label, label.lowercased())
        XCTAssertFalse(label.contains("h"), "parsed path must not produce the fallback 'h' suffix")
    }

    func testHourLabelIsoNonFractionalReturnsLowercaseAmPm() {
        let label = OverviewFormatters.hourLabel("2026-04-21T09:00:00Z")
        XCTAssertTrue(label.hasSuffix("am") || label.hasSuffix("pm"))
        XCTAssertEqual(label, label.lowercased())
    }

    /// Same input in both formats must produce the same label (both paths
    /// normalize to the same moment-in-time).
    func testHourLabelFractionalAndNonFractionalAgree() {
        let a = OverviewFormatters.hourLabel("2026-04-21T12:00:00.000Z")
        let b = OverviewFormatters.hourLabel("2026-04-21T12:00:00Z")
        XCTAssertEqual(a, b)
    }

    func testHourLabelFallsBackToSubstringWithHSuffix() {
        // Unparseable timestamp ≥ 13 chars → chars at [11, 12] + "h".
        XCTAssertEqual(
            OverviewFormatters.hourLabel("2026-04-21T14junk"),
            "14h"
        )
    }

    func testHourLabelReturnsRawWhenTooShort() {
        XCTAssertEqual(OverviewFormatters.hourLabel("nope"), "nope")
        XCTAssertEqual(OverviewFormatters.hourLabel(""),     "")
    }

    /// Cached formatters must yield identical output across many calls.
    /// This is the main correctness guarantee the static caches provide
    /// over the old "alloc-per-call" iOS implementation.
    func testHourLabelIdempotentAcrossManyCalls() {
        let input = "2026-04-21T03:00:00Z"
        let expected = OverviewFormatters.hourLabel(input)
        for _ in 0..<100 {
            XCTAssertEqual(OverviewFormatters.hourLabel(input), expected)
        }
    }
}
