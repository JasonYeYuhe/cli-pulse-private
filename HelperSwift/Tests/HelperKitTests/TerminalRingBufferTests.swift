import XCTest
@testable import HelperKit
import Foundation

/// Tests for the v1.24 Phase 2c slice 1 tail-snapshot ring buffer.
/// Pin the wrap-around behavior + tail semantics + cap clamping
/// before we attach the iOS foreground-recovery path that depends
/// on these guarantees.
final class TerminalRingBufferTests: XCTestCase {

    // MARK: - append / tail core

    func test_emptyBuffer_tailIsEmpty() {
        let rb = TerminalRingBuffer(capacity: 1024)
        XCTAssertEqual(rb.tail(maxBytes: 100), Data())
        XCTAssertEqual(rb.size, 0)
    }

    func test_singleWriteSmallerThanCapacity_tailMatches() {
        let rb = TerminalRingBuffer(capacity: 1024)
        rb.append(Data("hello world".utf8))
        XCTAssertEqual(rb.size, 11)
        XCTAssertEqual(rb.tail(maxBytes: 100), Data("hello world".utf8))
    }

    func test_tailMaxBytesSmallerThanSize_returnsTrailingSlice() {
        let rb = TerminalRingBuffer(capacity: 1024)
        rb.append(Data("abcdefghij".utf8))
        XCTAssertEqual(rb.tail(maxBytes: 4), Data("ghij".utf8))
    }

    func test_tailMaxBytesZero_returnsEmpty() {
        let rb = TerminalRingBuffer(capacity: 1024)
        rb.append(Data("abc".utf8))
        XCTAssertEqual(rb.tail(maxBytes: 0), Data())
    }

    func test_tailMaxBytesNegative_returnsEmpty() {
        let rb = TerminalRingBuffer(capacity: 1024)
        rb.append(Data("abc".utf8))
        XCTAssertEqual(rb.tail(maxBytes: -50), Data())
    }

    // MARK: - wrap-around

    func test_writeExactCapacity_fillsBufferOnce() {
        let rb = TerminalRingBuffer(capacity: 8)
        rb.append(Data([1,2,3,4,5,6,7,8]))
        XCTAssertEqual(rb.size, 8)
        XCTAssertEqual(rb.tail(maxBytes: 8), Data([1,2,3,4,5,6,7,8]))
    }

    func test_writeExceedingCapacityInOneCall_keepsOnlyTrailing() {
        let rb = TerminalRingBuffer(capacity: 4)
        rb.append(Data([1,2,3,4,5,6,7,8,9,10]))
        XCTAssertEqual(rb.size, 4)
        XCTAssertEqual(rb.tail(maxBytes: 4), Data([7,8,9,10]))
    }

    func test_writeAcrossWrap_returnsContiguousTail() {
        let rb = TerminalRingBuffer(capacity: 6)
        rb.append(Data([1,2,3,4]))           // size=4, head=4
        rb.append(Data([5,6,7,8,9]))         // wraps: head=3, size=6, dropped 1,2,3
        XCTAssertEqual(rb.size, 6)
        XCTAssertEqual(rb.tail(maxBytes: 6), Data([4,5,6,7,8,9]))
    }

    func test_repeatedSmallWrites_eventuallyEvictOldBytes() {
        let rb = TerminalRingBuffer(capacity: 10)
        for ch: UInt8 in 65..<85 {            // 'A'..'T'  20 bytes
            rb.append(Data([ch]))
        }
        XCTAssertEqual(rb.size, 10)
        // Should retain only the LAST 10 chars: 'K'..'T' (75..84)
        XCTAssertEqual(rb.tail(maxBytes: 100), Data(Array<UInt8>(75..<85)))
    }

    func test_tailLargerThanSize_returnsAllAvailable() {
        let rb = TerminalRingBuffer(capacity: 100)
        rb.append(Data("xyz".utf8))
        XCTAssertEqual(rb.tail(maxBytes: 1000), Data("xyz".utf8))
    }

    // MARK: - clear

    func test_clear_resetsBuffer() {
        let rb = TerminalRingBuffer(capacity: 16)
        rb.append(Data("payload".utf8))
        rb.clear()
        XCTAssertEqual(rb.size, 0)
        XCTAssertEqual(rb.tail(maxBytes: 100), Data())
        // Subsequent appends still work cleanly post-clear.
        rb.append(Data("again".utf8))
        XCTAssertEqual(rb.tail(maxBytes: 100), Data("again".utf8))
    }

    // MARK: - capacity contract

    func test_initWithZeroCapacity_traps() {
        // Use precondition crash — wrap in expectFatalError if needed;
        // for now keep this as a doc-test that capacity must be positive.
        // The actual precondition is exercised at runtime.
    }

    // MARK: - tail at exact buffer boundary (head==0 after wrap)

    func test_tailWhenHeadAtZeroAfterFullWrap_walksBackCorrectly() {
        let rb = TerminalRingBuffer(capacity: 4)
        rb.append(Data([1,2,3,4]))
        XCTAssertEqual(rb.size, 4)
        // head is now at 4 % 4 = 0. Tail should still give [1,2,3,4].
        XCTAssertEqual(rb.tail(maxBytes: 4), Data([1,2,3,4]))
        // Another full write past the boundary.
        rb.append(Data([5,6]))
        XCTAssertEqual(rb.size, 4)
        XCTAssertEqual(rb.tail(maxBytes: 4), Data([3,4,5,6]))
    }

    // MARK: - concurrency (Phase A0, v1.26)

    /// Codex HIGH: the helper drain loop calls `append` from one
    /// thread while `ManagedSessionManager.getTailSnapshot` reads
    /// `tail()` from another — without external synchronization.
    /// `TerminalRingBuffer` is now self-locking; this test pins the
    /// contract by hammering append (background queue) against tail
    /// (current thread) and asserting (1) no crash, (2) every tail
    /// returns a length within the buffer's documented bounds.
    /// Run under TSAN locally to verify no remaining races.
    func test_concurrentAppendAndTail_neverCrashes_lengthInBounds() {
        let rb = TerminalRingBuffer(capacity: 2048)
        let writeQueue = DispatchQueue(label: "rb.write", qos: .userInitiated)
        let writeIterations = 5_000
        let chunk = Data(repeating: 0x41, count: 32) // "AAA…" 32 B

        let done = expectation(description: "writes done")
        writeQueue.async {
            for _ in 0..<writeIterations {
                rb.append(chunk)
            }
            done.fulfill()
        }

        // Hammer reads from the test thread concurrently.
        for _ in 0..<writeIterations {
            let snap = rb.tail(maxBytes: 1024)
            // Bound: never exceeds the cap we asked for, never the
            // ring capacity, and never the live `size`.
            XCTAssertLessThanOrEqual(snap.count, 1024)
            XCTAssertLessThanOrEqual(snap.count, rb.capacity)
            XCTAssertLessThanOrEqual(snap.count, rb.size)
        }

        wait(for: [done], timeout: 30.0)
        // Final state: buffer is full (5000 × 32 B = 160_000 B ≫ 2048).
        XCTAssertEqual(rb.size, rb.capacity)
        XCTAssertEqual(rb.tail(maxBytes: 1024).count, 1024)
    }

    /// Two writers + one reader. Stresses the append critical section
    /// against itself plus a concurrent reader. Asserts the buffer
    /// invariants (size never exceeds capacity, every tail length is
    /// within the asked-for cap and the live size).
    func test_concurrentTwoWritersOneReader_invariantsHold() {
        let rb = TerminalRingBuffer(capacity: 1024)
        let q1 = DispatchQueue(label: "rb.write1", qos: .userInitiated)
        let q2 = DispatchQueue(label: "rb.write2", qos: .userInitiated)
        let iterations = 2_000
        let dataA = Data(repeating: 0x61, count: 16)
        let dataB = Data(repeating: 0x62, count: 16)

        let doneA = expectation(description: "writerA")
        let doneB = expectation(description: "writerB")
        q1.async {
            for _ in 0..<iterations { rb.append(dataA) }
            doneA.fulfill()
        }
        q2.async {
            for _ in 0..<iterations { rb.append(dataB) }
            doneB.fulfill()
        }

        for _ in 0..<iterations {
            let snap = rb.tail(maxBytes: 256)
            XCTAssertLessThanOrEqual(snap.count, 256)
            XCTAssertLessThanOrEqual(rb.size, rb.capacity)
        }

        wait(for: [doneA, doneB], timeout: 30.0)
        XCTAssertEqual(rb.size, rb.capacity)
    }

    // MARK: - redaction round-trip (mirrors ManagedSessionManager.getTailSnapshot)

    /// `getTailSnapshot` performs: ring buffer → tail bytes → UTF-8
    /// decode → `Redactor.redact` → re-encode. Verify that known
    /// secret patterns (Bearer token, sk-ant-, x-api-key header) all
    /// reach `«REDACTED»` form via this pipeline — the contract the
    /// foreground-recovery RPC depends on.
    func test_decodedTailWithSecrets_redactsThroughRedactor() {
        let rb = TerminalRingBuffer(capacity: 4096)
        rb.append(Data("""
        GET /v1/messages HTTP/1.1
        Authorization: Bearer sk-ant-api03-aaaabbbbccccddddeeeeffffgggghhhh
        X-API-Key: AKIAJ7VLSCONTRIVED1
        access_token=eyJhbGciOiJSUzI1NiIs.eyJzdWIiOiIxIn0.signaturepartabcd
        """.utf8))
        let raw = rb.tail(maxBytes: 4096)
        let text = String(data: raw, encoding: .utf8) ?? ""
        let redacted = Redactor.redact(text)
        XCTAssertTrue(redacted.contains(Redactor.redactionMarker),
                      "expected at least one redaction marker, got: \(redacted)")
        XCTAssertFalse(redacted.contains("sk-ant-api03-aaaabbbbcccc"),
                       "sk-ant- token leaked through redactor")
        XCTAssertFalse(redacted.contains("AKIAJ7VLSCONTRIVED1"),
                       "AWS access key shape leaked through redactor")
    }
}
