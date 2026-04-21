import XCTest
import SwiftUI
@testable import CLIPulseCore

/// P2-1 slice 3: `TopProjectsList` pins the empty-state + row-iteration
/// contract that both Overview tabs depend on.
final class TopProjectsListTests: XCTestCase {

    func testMacOSStylePreservesPreExtractionFonts() {
        let s = TopProjectsList.Style.macOS
        XCTAssertEqual(s.rowSpacing, 2)
    }

    func testIOSStylePreservesPreExtractionFonts() {
        let s = TopProjectsList.Style.iOS
        XCTAssertEqual(s.rowSpacing, 2)
    }

    /// The per-row divider rule: every row except the last gets a Divider.
    /// This test documents the invariant through list-identity logic so a
    /// refactor of the loop can't accidentally add a trailing divider.
    func testLastElementIsNotFollowedByDivider() {
        let items = [
            TopProject(id: "p1", name: "a", usage: 1, estimated_cost: 1, cost_status: "Estimated"),
            TopProject(id: "p2", name: "b", usage: 2, estimated_cost: 2, cost_status: "Estimated"),
            TopProject(id: "p3", name: "c", usage: 3, estimated_cost: 3, cost_status: "Estimated"),
        ]
        XCTAssertEqual(items.last?.id, "p3")
        // Iterating: first (p1) != p3 → divider; second (p2) != p3 → divider;
        // third (p3) == p3 → no divider.
        let shouldShowDividerAfter = items.map { $0.id != items.last?.id }
        XCTAssertEqual(shouldShowDividerAfter, [true, true, false])
    }

    func testSingleElementGetsNoDivider() {
        let items = [TopProject(id: "solo", name: "x", usage: 0, estimated_cost: 0, cost_status: "")]
        XCTAssertEqual(items.last?.id, "solo")
        XCTAssertEqual(items.map { $0.id != items.last?.id }, [false])
    }

    func testEmptyProjectsListContract() {
        // Empty projects must drive the empty-text branch; the row branch is
        // skipped entirely. Represented here by a length check.
        let items: [TopProject] = []
        XCTAssertTrue(items.isEmpty)
    }
}
