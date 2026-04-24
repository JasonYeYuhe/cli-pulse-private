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

    // MARK: - rankedProviderBreakdown

    private func row(_ name: String, usage: Int = 0, cost: Double = 0) -> ProviderBreakdown {
        ProviderBreakdown(
            provider: name, usage: usage, estimated_cost: cost,
            cost_status: "Estimated", remaining: nil
        )
    }

    func testRankedDropsDisabledProviders() {
        let input = [row("Claude", usage: 10, cost: 5), row("Codex", usage: 10, cost: 5)]
        let out = OverviewFormatters.rankedProviderBreakdown(input, enabledNames: ["Claude"])
        XCTAssertEqual(out.map(\.provider), ["Claude"])
    }

    func testRankedDropsZeroActivityRows() {
        let input = [
            row("Claude", usage: 100, cost: 2),
            row("Gemini", usage: 0,   cost: 0),   // drop — inactive
            row("Codex",  usage: 50,  cost: 0),   // keep — nonzero usage
            row("Ollama", usage: 0,   cost: 0.5), // keep — nonzero cost (paid)
        ]
        let out = OverviewFormatters.rankedProviderBreakdown(
            input, enabledNames: ["Claude", "Gemini", "Codex", "Ollama"])
        XCTAssertEqual(Set(out.map(\.provider)), ["Claude", "Codex", "Ollama"])
    }

    func testRankedSortsByCostDescThenUsageThenName() {
        let input = [
            row("Gemini", usage: 5,   cost: 10),
            row("Claude", usage: 100, cost: 10),   // same cost as Gemini → higher usage wins
            row("Codex",  usage: 100, cost: 100),  // highest cost → first
            row("Amp",    usage: 100, cost: 10),   // same cost+usage as Claude → name asc
        ]
        let out = OverviewFormatters.rankedProviderBreakdown(
            input, enabledNames: ["Claude", "Codex", "Gemini", "Amp"])
        XCTAssertEqual(out.map(\.provider), ["Codex", "Amp", "Claude", "Gemini"])
    }

    // MARK: - providerUsageBarFraction

    func testBarFractionScalesByCost() {
        let ranked = [
            row("Claude", usage: 500, cost: 10),
            row("Codex",  usage: 100, cost: 2.5),
        ]
        XCTAssertEqual(
            OverviewFormatters.providerUsageBarFraction(ranked[0], in: ranked),
            1.0, accuracy: 0.001,
            "highest-cost provider anchors the scale at 1.0")
        XCTAssertEqual(
            OverviewFormatters.providerUsageBarFraction(ranked[1], in: ranked),
            0.25, accuracy: 0.001,
            "Codex $2.5 / Claude $10 = 0.25 — NOT usage-based (100/500 would be 0.2)")
    }

    func testBarFractionGivesMinimumToNonzeroUsageZeroCost() {
        let ranked = [
            row("Claude", usage: 100, cost: 5),
            row("FreeTier", usage: 42, cost: 0),
        ]
        let fraction = OverviewFormatters.providerUsageBarFraction(ranked[1], in: ranked)
        XCTAssertEqual(fraction, OverviewFormatters.minVisibleCostBarFraction, accuracy: 0.001,
                       "provider with usage but no cost must stay visible, not collapse to 0")
        XCTAssertGreaterThan(fraction, 0, "minimum must be strictly > 0 so the bar renders")
    }

    func testBarFractionZeroWhenTrulyInactive() {
        // rankedProviderBreakdown would normally drop this row, but the
        // helper must still do the right thing if a caller passes one in.
        let ranked = [row("Claude", usage: 100, cost: 5), row("Ghost", usage: 0, cost: 0)]
        XCTAssertEqual(
            OverviewFormatters.providerUsageBarFraction(ranked[1], in: ranked), 0,
            accuracy: 0.001)
    }

    func testBarFractionAllZeroCostList() {
        let ranked = [
            row("A", usage: 100, cost: 0),
            row("B", usage: 50,  cost: 0),
        ]
        // No cost anywhere → every nonzero-usage row gets the minimum.
        for r in ranked {
            XCTAssertEqual(
                OverviewFormatters.providerUsageBarFraction(r, in: ranked),
                OverviewFormatters.minVisibleCostBarFraction,
                accuracy: 0.001)
        }
    }
}
