import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// Swift port of `helper/test_local_session_server.py`'s framing
/// section. Same coverage:
///
///   - 4-byte length-prefixed wire framing round-trips
///   - 1 MiB payload cap rejection (write side)
///   - declared oversize on the wire is rejected (read side) WITHOUT
///     draining the body
///   - clean EOF (no header bytes received) returns nil
///   - half-frame (header complete, body short) raises frameTruncated
final class FramingTests: XCTestCase {

    /// Build a connected pair of AF_UNIX sockets in-process.
    /// Mirrors `socket.socketpair` from CPython.
    private func socketPair() -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = fds.withUnsafeMutableBufferPointer { ptr -> Int32 in
            return Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, ptr.baseAddress)
        }
        XCTAssertEqual(result, 0, "socketpair failed")
        return (fds[0], fds[1])
    }

    func testWriteThenReadRoundTripsShortBody() throws {
        let (a, b) = socketPair()
        defer { Darwin.close(a); Darwin.close(b) }
        let body = Data(#"{"hello":"world"}"#.utf8)
        try Framing.writeFrame(to: a, body: body)
        let out = try Framing.readFrame(from: b)
        XCTAssertEqual(out, body)
    }

    func testWriteRejectsOversizeBody() {
        let (a, b) = socketPair()
        defer { Darwin.close(a); Darwin.close(b) }
        let tooBig = Data(repeating: 0x78, count: Framing.maxPayload + 1)
        XCTAssertThrowsError(try Framing.writeFrame(to: a, body: tooBig)) { err in
            guard case Framing.FrameError.frameTooLarge(let claimed) = err else {
                XCTFail("expected .frameTooLarge, got \(err)")
                return
            }
            XCTAssertEqual(claimed, Framing.maxPayload + 1)
        }
    }

    /// Forge a header that promises > maxPayload; the reader must
    /// refuse before draining the (non-existent) body.
    func testReadRejectsDeclaredOversizeBody() throws {
        let (a, b) = socketPair()
        defer { Darwin.close(a); Darwin.close(b) }
        var header: UInt32 = UInt32(Framing.maxPayload + 1).bigEndian
        let n = withUnsafeBytes(of: &header) { ptr in
            Darwin.write(a, ptr.baseAddress!, 4)
        }
        XCTAssertEqual(n, 4)
        XCTAssertThrowsError(try Framing.readFrame(from: b)) { err in
            guard case Framing.FrameError.frameTooLarge = err else {
                XCTFail("expected .frameTooLarge, got \(err)")
                return
            }
        }
    }

    func testReadReturnsNilOnCleanEof() throws {
        let (a, b) = socketPair()
        defer { Darwin.close(b) }
        Darwin.close(a)   // peer closes before sending anything
        let out = try Framing.readFrame(from: b)
        XCTAssertNil(out, "clean EOF must return nil")
    }

    func testReadRaisesTruncatedWhenHeaderCompleteButBodyShort() throws {
        let (a, b) = socketPair()
        defer { Darwin.close(b) }
        // Promise 8 bytes, send only 3, then close.
        var header: UInt32 = UInt32(8).bigEndian
        _ = withUnsafeBytes(of: &header) { ptr in
            Darwin.write(a, ptr.baseAddress!, 4)
        }
        let partial: [UInt8] = [0x61, 0x62, 0x63]
        _ = partial.withUnsafeBufferPointer { ptr in
            Darwin.write(a, ptr.baseAddress!, 3)
        }
        Darwin.close(a)
        XCTAssertThrowsError(try Framing.readFrame(from: b)) { err in
            guard case Framing.FrameError.frameTruncated = err else {
                XCTFail("expected .frameTruncated, got \(err)")
                return
            }
        }
    }

    /// Empty-body frame is legal and round-trips cleanly. Pin
    /// because some legacy helpers used 0-length acks during
    /// streaming setup.
    func testEmptyBodyRoundTrips() throws {
        let (a, b) = socketPair()
        defer { Darwin.close(a); Darwin.close(b) }
        try Framing.writeFrame(to: a, body: Data())
        let out = try Framing.readFrame(from: b)
        XCTAssertEqual(out, Data())
    }
}
