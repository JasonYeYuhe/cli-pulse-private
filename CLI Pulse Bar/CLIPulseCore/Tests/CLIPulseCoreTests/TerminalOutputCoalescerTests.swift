import XCTest
@testable import CLIPulseCore
import Foundation

/// Tests for the v1.24 Phase 3 Codex HIGH H1 mitigation: cap
/// Swift→WKWebView bridge crossings to ~60/sec regardless of
/// producer rate. Pin two contracts:
///   1. Concatenation across the 16 ms window — N appends → 1 flush.
///   2. No flush scheduled when buffer is empty; idle does not burn
///      timer cycles.
final class TerminalOutputCoalescerTests: XCTestCase {

    /// Helper: collect flushes into an array under a NSLock so tests
    /// can assert on the boundary without TSan warnings.
    final class FlushSink: @unchecked Sendable {
        private let lock = NSLock()
        private var _flushes: [Data] = []
        var flushes: [Data] {
            lock.lock(); defer { lock.unlock() }
            return _flushes
        }
        func handler() -> @Sendable (Data) -> Void {
            return { [weak self] data in
                guard let self else { return }
                self.lock.lock(); self._flushes.append(data); self.lock.unlock()
            }
        }
        var concatenated: Data {
            lock.lock(); defer { lock.unlock() }
            return _flushes.reduce(Data(), +)
        }
    }

    // MARK: - core contract

    func test_appendsWithinWindowCoalesceIntoOneFlush() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 0.05,                 // 50 ms — comfortable for CI
            flushQueue: .global(qos: .userInitiated),
            onFlush: sink.handler())
        coal.append(Data("a".utf8))
        coal.append(Data("b".utf8))
        coal.append(Data("c".utf8))
        // Each individual append happens before any flush deadline,
        // so we expect exactly ONE flush carrying "abc".
        let exp = expectation(description: "single flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(sink.flushes.count, 1)
        XCTAssertEqual(sink.concatenated, Data("abc".utf8))
    }

    func test_emptyAppend_isNoOp_noFlushScheduled() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 0.05,
            onFlush: sink.handler())
        coal.append(Data())
        XCTAssertFalse(coal.hasScheduledFlush)
        XCTAssertEqual(coal.pendingByteCount, 0)
        // Wait past the window — still nothing flushed.
        let exp = expectation(description: "no flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(sink.flushes.count, 0)
    }

    func test_secondWindowAfterFirstFlush_emitsSecondBatch() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 0.05,
            onFlush: sink.handler())
        coal.append(Data("first-".utf8))
        let exp1 = expectation(description: "first flush done")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exp1.fulfill() }
        wait(for: [exp1], timeout: 1.0)
        XCTAssertEqual(sink.flushes.count, 1)

        coal.append(Data("second".utf8))
        let exp2 = expectation(description: "second flush done")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exp2.fulfill() }
        wait(for: [exp2], timeout: 1.0)
        XCTAssertEqual(sink.flushes.count, 2)
        XCTAssertEqual(sink.flushes[0], Data("first-".utf8))
        XCTAssertEqual(sink.flushes[1], Data("second".utf8))
    }

    func test_pendingByteCount_reflectsBufferBeforeFlush() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 1.0,                  // long window so we can observe
            onFlush: sink.handler())
        coal.append(Data("hello".utf8))
        XCTAssertEqual(coal.pendingByteCount, 5)
        XCTAssertTrue(coal.hasScheduledFlush)
        coal.flushNow()
        XCTAssertEqual(coal.pendingByteCount, 0)
        XCTAssertFalse(coal.hasScheduledFlush)
        XCTAssertEqual(sink.concatenated, Data("hello".utf8))
    }

    // MARK: - flushNow

    func test_flushNow_drainsImmediately() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 5.0,                  // 5 seconds — would not fire in test
            onFlush: sink.handler())
        coal.append(Data("urgent".utf8))
        coal.flushNow()
        XCTAssertEqual(sink.flushes.count, 1)
        XCTAssertEqual(sink.flushes[0], Data("urgent".utf8))
        XCTAssertFalse(coal.hasScheduledFlush)
    }

    func test_flushNow_onEmptyBuffer_isNoOp() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 0.05,
            onFlush: sink.handler())
        coal.flushNow()
        XCTAssertEqual(sink.flushes.count, 0)
    }

    func test_flushNow_thenAppend_reschedulesNextWindow() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 0.05,
            onFlush: sink.handler())
        coal.append(Data("a".utf8))
        coal.flushNow()
        XCTAssertEqual(sink.flushes.count, 1)
        // Subsequent appends arm a fresh window — flushes count must
        // continue ticking up.
        coal.append(Data("b".utf8))
        XCTAssertTrue(coal.hasScheduledFlush)
        let exp = expectation(description: "second flush")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)
        XCTAssertEqual(sink.flushes.count, 2)
        XCTAssertEqual(sink.flushes[1], Data("b".utf8))
    }

    // MARK: - high-frequency stress

    /// Simulate a burst of 1000 small appends (typical of dense
    /// stdout). All bytes must reach the sink; flush count must be
    /// dramatically smaller than append count (we're capping bridge
    /// crossings — that's the whole point).
    func test_thousandAppendsBatchInto_FarFewerFlushes() {
        let sink = FlushSink()
        let coal = TerminalOutputCoalescer(
            windowSeconds: 0.02,
            onFlush: sink.handler())
        for i in 0..<1000 {
            coal.append(Data("\(i),".utf8))
        }
        // Wait for the last window to elapse plus a margin.
        let exp = expectation(description: "drained")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 2.0)
        let totalBytes = sink.flushes.reduce(0) { $0 + $1.count }
        let expectedBytes = (0..<1000).reduce(0) { $0 + "\($1),".utf8.count }
        XCTAssertEqual(totalBytes, expectedBytes,
                       "all bytes must reach the sink — coalescing must never DROP data")
        XCTAssertLessThan(sink.flushes.count, 1000,
                          "expected coalescing to reduce flush count well below append count")
    }
}
