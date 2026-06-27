import XCTest
@testable import CLIPulseCore

final class CollectorConcurrencyTests: XCTestCase {

    /// Tracks how many tasks are in `work` at once and the high-water mark.
    private actor ConcurrencyTracker {
        private(set) var current = 0
        private(set) var maxObserved = 0
        func enter() { current += 1; maxObserved = max(maxObserved, current) }
        func leave() { current -= 1 }
    }

    func test_mapWithConcurrencyLimit_never_exceeds_limit() async {
        let tracker = ConcurrencyTracker()
        let items = Array(0..<40)
        let out = await mapWithConcurrencyLimit(items, maxConcurrent: 4) { i -> Int? in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 3_000_000) // force overlap
            await tracker.leave()
            return i
        }
        let peak = await tracker.maxObserved
        XCTAssertLessThanOrEqual(peak, 4, "more than 4 collectors ran concurrently (peak \(peak))")
        XCTAssertGreaterThan(peak, 1, "expected real concurrency, not serial execution")
        XCTAssertEqual(out.count, 40, "every item must be processed")
        XCTAssertEqual(Set(out), Set(items))
    }

    func test_mapWithConcurrencyLimit_limit_one_is_serial() async {
        let tracker = ConcurrencyTracker()
        let out = await mapWithConcurrencyLimit(Array(0..<10), maxConcurrent: 1) { i -> Int? in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 1_000_000)
            await tracker.leave()
            return i
        }
        let peak = await tracker.maxObserved
        XCTAssertEqual(peak, 1, "maxConcurrent:1 must run strictly serially")
        XCTAssertEqual(out.count, 10)
    }

    func test_mapWithConcurrencyLimit_drops_nil_and_handles_empty() async {
        let out = await mapWithConcurrencyLimit(Array(0..<10), maxConcurrent: 3) { i -> Int? in
            i.isMultiple(of: 2) ? i : nil
        }
        XCTAssertEqual(Set(out), Set([0, 2, 4, 6, 8]))
        let empty = await mapWithConcurrencyLimit([Int](), maxConcurrent: 3) { $0 }
        XCTAssertTrue(empty.isEmpty)
    }

    func test_collectorErrorLog_serializes_concurrent_appends() async throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clpulse-collector-log-\(UUID().uuidString).log")
        try? FileManager.default.removeItem(at: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let log = CollectorErrorLog(url: tmp)
        let n = 200
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask { await log.append("[Collector] provider-\(i) failed: boom-\(i)") }
            }
        }

        let content = try String(contentsOf: tmp, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, n, "every append must be exactly one intact line (no interleave/truncation)")

        // Each line must be intact and carry a unique, parseable boom-K marker.
        var seen = Set<Int>()
        for line in lines {
            XCTAssertTrue(line.contains("[Collector] provider-"), "garbled line: \(line)")
            guard let r = line.range(of: "boom-"), let k = Int(line[r.upperBound...]) else {
                return XCTFail("corrupted/interleaved message: \(line)")
            }
            seen.insert(k)
        }
        XCTAssertEqual(seen.count, n, "every message must appear exactly once and intact")
    }
}
