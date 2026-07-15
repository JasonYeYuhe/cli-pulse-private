import XCTest
@testable import HelperKit
import Foundation

/// M4.4a PR-A: the `SessionTransport` protocol seam. Proves PtyTransport's
/// additive conformance downcasts correctly + guards foreign handles, and that
/// a stand-in transport (the shape a TmuxTransport will take) satisfies the
/// protocol. The full manager-routing-through-an-override test lands with the
/// attach API (PR D).
final class SessionTransportSeamTests: XCTestCase {

    /// A minimal foreign handle from a DIFFERENT transport.
    final class ForeignHandle: SessionHandle, @unchecked Sendable {
        let sessionId = "foreign"
        let pid: pid_t = 0
        let isClosed = false
    }

    /// A stand-in transport that records the handles it's asked to operate on —
    /// the shape TmuxTransport will conform to.
    final class RecordingTransport: SessionTransport, @unchecked Sendable {
        var writes: [(String, Data)] = []
        var terminated: [String] = []
        var closed: [String] = []
        func writeStdin(_ handle: SessionHandle, _ data: Data) throws -> Int {
            writes.append((handle.sessionId, data)); return data.count
        }
        func readStdout(_ handle: SessionHandle, maxBytes: Int) throws -> Data { Data() }
        func setWinsize(_ handle: SessionHandle, cols: UInt16, rows: UInt16) throws {}
        func interrupt(_ handle: SessionHandle) {}
        func terminate(_ handle: SessionHandle) { terminated.append(handle.sessionId) }
        func isAlive(_ handle: SessionHandle) -> Bool { true }
        func waitChild(_ handle: SessionHandle, timeoutSec: TimeInterval?) -> Int32? { nil }
        func close(_ handle: SessionHandle) { closed.append(handle.sessionId) }
    }

    func testPtyTransportThrowingWitnessesRejectForeignHandle() {
        let pty: any SessionTransport = PtyTransport()
        let foreign = ForeignHandle()
        // The THROWING witnesses reject a foreign handle rather than corrupting
        // an unrelated fd (the `_p(handle)` guard). The NON-throwing witnesses
        // (isAlive/waitChild/interrupt/terminate/close) `assertionFailure` on a
        // foreign handle instead — a foreign handle there is ALWAYS a wiring bug
        // (review: agy), so they're deliberately NOT exercised here (asserting
        // in a debug test build would crash the process; in release they degrade
        // to a safe default).
        XCTAssertThrowsError(try pty.writeStdin(foreign, Data([0x41]))) { err in
            XCTAssertEqual(err as? SessionTransportError, .foreignHandle)
        }
        XCTAssertThrowsError(try pty.readStdout(foreign, maxBytes: 16))
        XCTAssertThrowsError(try pty.setWinsize(foreign, cols: 80, rows: 24))
    }

    func testStandInTransportSatisfiesProtocolAndRoutes() throws {
        let t = RecordingTransport()
        let h = ForeignHandle()
        let n = try t.writeStdin(h, Data("hi".utf8))
        XCTAssertEqual(n, 2)
        t.terminate(h)
        t.close(h)
        XCTAssertEqual(t.writes.map { $0.0 }, ["foreign"])
        XCTAssertEqual(t.terminated, ["foreign"])
        XCTAssertEqual(t.closed, ["foreign"])
    }

    /// Pin the overload/delegation claim (review: codex P3): a REAL
    /// PtyTransport.Handle, typed as the protocols, must round-trip I/O through
    /// the `any SessionTransport` witnesses down to the concrete methods.
    func testRealPtyHandleDelegatesThroughProtocolWitnesses() throws {
        let concrete = PtyTransport()
        let concreteHandle = try concrete.start(sessionId: "seam-pty", argv: ["/bin/cat"])
        let transport: any SessionTransport = concrete
        let handle: any SessionHandle = concreteHandle
        defer { transport.close(handle) }

        XCTAssertEqual(handle.sessionId, "seam-pty")
        XCTAssertGreaterThan(handle.pid, 0)         // real child pid via the protocol
        XCTAssertTrue(transport.isAlive(handle))

        // write → protocol witness → concrete writeStdin → PTY; cat echoes it.
        let n = try transport.writeStdin(handle, Data("hello\n".utf8))
        XCTAssertGreaterThan(n, 0)
        var got = Data()
        for _ in 0..<50 {
            got.append(try transport.readStdout(handle, maxBytes: 4096))
            if String(data: got, encoding: .utf8)?.contains("hello") == true { break }
            Thread.sleep(forTimeInterval: 0.02)
        }
        XCTAssertTrue(String(data: got, encoding: .utf8)?.contains("hello") == true,
                      "I/O must delegate through the protocol witnesses to the concrete PTY")
        transport.terminate(handle)
    }
}
