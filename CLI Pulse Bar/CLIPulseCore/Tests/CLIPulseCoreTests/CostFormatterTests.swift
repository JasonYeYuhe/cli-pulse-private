import XCTest
@testable import CLIPulseCore

/// Regression guard for the cost-display bug where any value >= $1 rendered
/// with a SINGLE decimal place ("$9.6", "$220.0", "$229.6") because the
/// `cost >= 1.0` branch of `CostFormatter.format` used `"$%.1f"`. That produced
/// the malformed subscription / cost-summary figures on the dashboard
/// (macOS + iOS both route currency through `CostFormatter.format`).
///
/// Currency is ALWAYS two decimal places. These assertions pin that so the
/// 1-decimal form can't silently come back.
final class CostFormatterTests: XCTestCase {

    func testValuesAtOrAboveOneDollarUseTwoDecimals() {
        XCTAssertEqual(CostFormatter.format(9.6), "$9.60")
        XCTAssertEqual(CostFormatter.format(20), "$20.00")
        XCTAssertEqual(CostFormatter.format(200), "$200.00")
        XCTAssertEqual(CostFormatter.format(220), "$220.00")
        XCTAssertEqual(CostFormatter.format(229.6), "$229.60")
        XCTAssertEqual(CostFormatter.format(1.0), "$1.00")
    }

    func testRoundsToTwoDecimals() {
        XCTAssertEqual(CostFormatter.format(9.567), "$9.57")
        XCTAssertEqual(CostFormatter.format(12.341), "$12.34")
    }

    func testSubDollarValuesUseTwoDecimals() {
        XCTAssertEqual(CostFormatter.format(0.5), "$0.50")
        XCTAssertEqual(CostFormatter.format(0.99), "$0.99")
        XCTAssertEqual(CostFormatter.format(0.01), "$0.01")
    }

    func testSubCentRendersAsLessThanOneCent() {
        XCTAssertEqual(CostFormatter.format(0.005), "<$0.01")
        XCTAssertEqual(CostFormatter.format(0.009), "<$0.01")
    }
}
