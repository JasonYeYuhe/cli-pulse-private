import XCTest
@testable import HelperKit
import Foundation

/// The Swift twin of `helper/test_container_watchdog.py`.
///
/// The bundled Swift helper used to call `AuthToken.rotateToken()` straight on
/// the main thread with only a `try/catch`. The catch encoded the right policy
/// ("continuing with empty token") but a HANG never throws, so it never ran —
/// and a stalled TCC container consult hung the daemon forever, holding a macOS
/// permission prompt open and re-asking the user every time it was dismissed.
/// That is worse than the Python helper's respawn loop, because launchd cannot
/// recover a hung process.
///
/// Covered: a fast rotation returns its token; a slow-but-completing one still
/// returns (the case a too-tight ceiling would kill); a stall returns nil rather
/// than hanging or exiting; a throw propagates (a throw is not a stall); and an
/// abandoned worker still lands its token for the next start.
final class ContainerAccessTests: XCTestCase {

    func testFastRotationReturnsTheToken() throws {
        let token = try ContainerAccess.rotateTokenBestEffort(
            timeout: 5.0, rotate: { "TOKEN-OK" })
        XCTAssertEqual(token, "TOKEN-OK")
    }

    func testSlowButCompletingRotationStillReturnsItsToken() throws {
        // The TCC consult is routinely slow under launchd (1–10s) and then
        // COMPLETES. A ceiling tuned to an imagined "warm" cost kills exactly
        // these starts — that was the Python helper's 12s mistake.
        let token = try ContainerAccess.rotateTokenBestEffort(timeout: 5.0, rotate: {
            Thread.sleep(forTimeInterval: 0.4)
            return "TOKEN-SLOW"
        })
        XCTAssertEqual(token, "TOKEN-SLOW", "a slow-but-completing consult must not be abandoned")
    }

    func testStallReturnsNilInsteadOfHangingForever() throws {
        // The regression that matters. Pre-fix this ran on the main thread with
        // no deadline, so this case never returned at all.
        let start = Date()
        let token = try ContainerAccess.rotateTokenBestEffort(timeout: 0.2, rotate: {
            Thread.sleep(forTimeInterval: 3.0)   // still stuck at the deadline
            return "NEVER"
        })
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertNil(token, "a stall must report 'no token' so the caller skips the socket")
        XCTAssertLessThan(elapsed, 1.0,
                          "must give up at the deadline, not wait out the stall: \(elapsed)s")
    }

    func testStallDoesNotBlockTheCallingThread() throws {
        // The whole point: the caller stays responsive and reaches its own
        // decision (skip the socket, keep the cloud loop) instead of being
        // parked inside open(2) forever.
        let ran = expectation(description: "caller continued after the stall")
        DispatchQueue.global().async {
            _ = try? ContainerAccess.rotateTokenBestEffort(timeout: 0.15, rotate: {
                Thread.sleep(forTimeInterval: 5.0)
                return "NEVER"
            })
            ran.fulfill()
        }
        wait(for: [ran], timeout: 2.0)
    }

    func testThrowPropagates() {
        // A throw is NOT a stall — the container answered. The caller's existing
        // best-effort handling is correct and binding stays safe.
        struct Boom: Error {}
        XCTAssertThrowsError(
            try ContainerAccess.rotateTokenBestEffort(timeout: 1.0, rotate: { throw Boom() })
        ) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testAbandonedWorkerStillLandsItsTokenForTheNextStart() throws {
        // Abandoning the worker must not lose the token permanently: if the
        // stalled open ever completes it writes the token, which the NEXT start
        // reads. (Explicitly NOT a claim that this start heals itself — it skips
        // the socket, so nothing is re-reading the token.)
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse-ca-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let landed = dir.appendingPathComponent("token")
        let gate = DispatchSemaphore(value: 0)

        let token = try ContainerAccess.rotateTokenBestEffort(timeout: 0.15, rotate: {
            _ = gate.wait(timeout: .now() + 5)          // the stalled consult
            try? "LATE-TOKEN".write(to: landed, atomically: true, encoding: .utf8)
            return "LATE-TOKEN"
        })
        XCTAssertNil(token, "degraded start: no token yet")

        gate.signal()                                    // the consult finally returns
        var waited = 0.0
        while !FileManager.default.fileExists(atPath: landed.path), waited < 3.0 {
            Thread.sleep(forTimeInterval: 0.05); waited += 0.05
        }
        XCTAssertEqual(try? String(contentsOf: landed, encoding: .utf8), "LATE-TOKEN",
                       "the abandoned worker must still land its token for the next start")
    }

    func testEmptyTokenNeverAuthenticates() {
        // What makes a token-less start safe: main.swift starts the server with
        // token "" when rotation THROWS (the container answered, so binding is
        // safe). On a socket any local process can connect(2) to, an empty
        // expected token must never match.
        XCTAssertFalse(AuthToken.compare(expected: "", supplied: ""))
        XCTAssertFalse(AuthToken.compare(expected: "", supplied: "anything"))
        XCTAssertFalse(AuthToken.compare(expected: "real-token", supplied: ""))
        XCTAssertTrue(AuthToken.compare(expected: "real-token", supplied: "real-token"))
    }
}
