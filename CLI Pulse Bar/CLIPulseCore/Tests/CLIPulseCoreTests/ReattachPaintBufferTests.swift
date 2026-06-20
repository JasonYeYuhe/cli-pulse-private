import XCTest
@testable import CLIPulseCore
import Foundation

/// v1.32.1 P1-4 — the race-safe reattach paint ordering lives in this pure
/// value type, so it carries the correctness tests. The adapter↔WKWebView
/// integration is verified on-device (WKWebView can't be instantiated in an
/// XCTest host).
final class ReattachPaintBufferTests: XCTestCase {

    private func d(_ s: String) -> Data { Data(s.utf8) }

    func test_startsBuffering() {
        let buf = ReattachPaintBuffer()
        XCTAssertTrue(buf.isBuffering)
    }

    func test_intakeWhileBuffering_holdsAndReturnsNil() {
        var buf = ReattachPaintBuffer()
        XCTAssertNil(buf.intake(d("a")))
        XCTAssertNil(buf.intake(d("b")))
        XCTAssertTrue(buf.isBuffering)
    }

    func test_flush_writesSnapshotThenBufferedInOrder() {
        var buf = ReattachPaintBuffer()
        _ = buf.intake(d("live1"))
        _ = buf.intake(d("live2"))
        let writes = buf.flush(afterSnapshot: d("SNAP"))
        XCTAssertEqual(writes.map { String(decoding: $0, as: UTF8.self) },
                       ["SNAP", "live1", "live2"])
        XCTAssertFalse(buf.isBuffering)
    }

    func test_flushWithEmptySnapshot_skipsSnapshotWrite() {
        // A failed get_tail_snapshot still releases the buffered live bytes.
        var buf = ReattachPaintBuffer()
        _ = buf.intake(d("live1"))
        let writes = buf.flush(afterSnapshot: Data())
        XCTAssertEqual(writes.map { String(decoding: $0, as: UTF8.self) }, ["live1"])
        XCTAssertFalse(buf.isBuffering)
    }

    func test_flushWithNoBufferedAndEmptySnapshot_isEmpty() {
        var buf = ReattachPaintBuffer()
        XCTAssertEqual(buf.flush(afterSnapshot: Data()).count, 0)
    }

    func test_intakeAfterFlush_passesThrough() {
        var buf = ReattachPaintBuffer()
        _ = buf.flush(afterSnapshot: d("SNAP"))
        let now = buf.intake(d("after"))
        XCTAssertEqual(now.map { String(decoding: $0, as: UTF8.self) }, "after")
    }

    func test_flushIsIdempotent() {
        var buf = ReattachPaintBuffer()
        _ = buf.intake(d("x"))
        let first = buf.flush(afterSnapshot: d("S"))
        XCTAssertEqual(first.count, 2)          // S + x
        let second = buf.flush(afterSnapshot: d("S2"))
        XCTAssertEqual(second.count, 0)          // second call is a no-op
    }

    func test_emptyChunksAreIgnored() {
        var buf = ReattachPaintBuffer()
        XCTAssertNil(buf.intake(Data()))         // empty held → nothing
        _ = buf.intake(d("real"))
        let writes = buf.flush(afterSnapshot: Data())
        XCTAssertEqual(writes.map { String(decoding: $0, as: UTF8.self) }, ["real"])
        // After flush, an empty live chunk still returns nil (not a passthrough).
        XCTAssertNil(buf.intake(Data()))
    }

    func test_orderingPreservedAcrossManyChunks() {
        var buf = ReattachPaintBuffer()
        let chunks = (0..<50).map { d("c\($0)") }
        for c in chunks { _ = buf.intake(c) }
        let writes = buf.flush(afterSnapshot: d("HEAD"))
        let expected = ["HEAD"] + (0..<50).map { "c\($0)" }
        XCTAssertEqual(writes.map { String(decoding: $0, as: UTF8.self) }, expected)
    }
}
