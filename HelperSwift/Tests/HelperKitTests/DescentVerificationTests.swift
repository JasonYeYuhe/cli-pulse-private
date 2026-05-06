import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// Tests for the descent (process-ancestry) verification logic.
/// We don't spawn real processes here — `descentChainContains` is
/// pluggable on the parent-resolver so tests can simulate any
/// process tree shape and pin every edge case Codex called out
/// in the Python implementation's review.
final class DescentVerificationTests: XCTestCase {

    /// Build a parent-resolver from a `[child: parent]` map.
    private func resolver(_ map: [Int32: Int32]) -> (Int32) -> Int32? {
        return { pid in map[pid] }
    }

    func testDescentDirectChildIsDescendant() {
        // Tree: 1 -> 100 (claude) -> 200 (peer)
        let map: [Int32: Int32] = [200: 100, 100: 1]
        let ok = DescentVerification.descentChainContains(
            claudePid: 100, peerPid: 200, parentResolver: resolver(map)
        )
        XCTAssertTrue(ok)
    }

    func testDescentDeepDescendantIsDescendant() {
        // Tree: 100 -> 200 -> 300 -> 400 (peer)
        let map: [Int32: Int32] = [400: 300, 300: 200, 200: 100, 100: 1]
        let ok = DescentVerification.descentChainContains(
            claudePid: 100, peerPid: 400, parentResolver: resolver(map)
        )
        XCTAssertTrue(ok)
    }

    func testDescentSelfIsDescendant() {
        // peerPid == claudePid: the request came from the Claude
        // process itself (not realistic for hook-subprocess paths
        // but important defence-in-depth — the registry should
        // accept).
        let map: [Int32: Int32] = [100: 1]
        XCTAssertTrue(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 100, parentResolver: resolver(map)
            )
        )
    }

    func testDescentSiblingIsRejected() {
        // Tree: 1 -> 100 (claude), 1 -> 999 (other process)
        // peer pid 999 is NOT descended from 100.
        let map: [Int32: Int32] = [999: 1, 100: 1]
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 999, parentResolver: resolver(map)
            )
        )
    }

    func testDescentReachingLaunchdRejects() {
        // peer pid 999 has root pid 1 (launchd) in its chain but
        // claudePid=100 is NOT in that chain → reject.
        let map: [Int32: Int32] = [999: 1]
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 999, parentResolver: resolver(map)
            )
        )
    }

    func testDescentMissingAncestorRejects() {
        // Tree breaks: 200 -> 150 -> nil
        let map: [Int32: Int32] = [200: 150]
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 200, parentResolver: resolver(map)
            )
        )
    }

    func testDescentZeroPeerRejects() {
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 0,
                parentResolver: { _ in nil }
            )
        )
    }

    func testDescentZeroClaudeRejects() {
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 0, peerPid: 200,
                parentResolver: resolver([200: 100])
            )
        )
    }

    /// Walk-limit cap: a pathological process tree that loops
    /// pid → pid → pid forever must terminate without infinite
    /// loop and return false.
    func testDescentRespectsWalkLimit() {
        // Chain: 200 -> 200 -> 200 ... (immediate self-loop).
        // descentChainContains has a defensive parent==current
        // shortcut, so we use an effectively-infinite chain
        // with distinct pids: 200 -> 201 -> 202 -> ... -> 219.
        var map: [Int32: Int32] = [:]
        for i in 200..<300 { map[Int32(i)] = Int32(i + 1) }
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 200, parentResolver: resolver(map)
            ),
            "walk MUST terminate at the limit even when the chain never reaches the target"
        )
    }

    func testDescentSelfReferenceShortcuts() {
        // Pathological resolver returning self → must terminate
        // (defensive guard) without infinite loop.
        XCTAssertFalse(
            DescentVerification.descentChainContains(
                claudePid: 100, peerPid: 200,
                parentResolver: { _ in 200 }
            )
        )
    }
}
