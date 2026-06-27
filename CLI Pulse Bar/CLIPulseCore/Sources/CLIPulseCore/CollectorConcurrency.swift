// CollectorConcurrency — bounded fan-out + serialized error logging for the
// per-refresh collector run. Extracted from DataRefreshManager.runCollectors so
// the concurrency bound and the log-write serialization are unit-testable.
//
// Before this: runCollectors spawned an UNBOUNDED task per enabled provider
// (~48) every ~120s (+ helper-sync + manual refresh), and each failing
// collector opened the same error log with FileHandle.seekToEndOfFile()+write()
// concurrently — a thundering herd of subprocess/network work and an append race
// that interleaved/truncated log lines exactly when many collectors failed at
// once.

import Foundation

/// Upper bound on collectors running concurrently within a single refresh.
/// Tunable; 8 keeps refresh responsive without serializing the whole run.
let maxConcurrentCollectors = 8

/// Runs `work` over `items` with at most `maxConcurrent` tasks in flight at any
/// instant, returning the non-nil outputs (order not guaranteed). A new task is
/// started only as an in-flight one completes, so memory/subprocess pressure is
/// bounded regardless of how many items there are.
func mapWithConcurrencyLimit<Item: Sendable, Output: Sendable>(
    _ items: [Item],
    maxConcurrent: Int,
    _ work: @escaping @Sendable (Item) async -> Output?
) async -> [Output] {
    let limit = max(1, maxConcurrent)
    var results: [Output] = []
    await withTaskGroup(of: Output?.self) { group in
        var next = 0
        let seed = min(limit, items.count)
        while next < seed {
            let item = items[next]
            next += 1
            group.addTask { await work(item) }
        }
        while let out = await group.next() {
            if let out { results.append(out) }
            if next < items.count {
                let item = items[next]
                next += 1
                group.addTask { await work(item) }
            }
        }
    }
    return results
}

/// Serializes appends to the collector error log. Many collectors failing at
/// once would otherwise each `seekToEndOfFile()`+`write()` the same file from
/// different threads, interleaving and truncating lines; funnelling every
/// append through one actor makes each line atomic with respect to the others.
actor CollectorErrorLog {
    /// Production sink (temp dir), matching the previous hard-coded path.
    static let shared = CollectorErrorLog(
        url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse_collector_errors.log"))

    private let url: URL

    init(url: URL) { self.url = url }

    /// Append one already-formatted message line (a timestamp is prepended).
    func append(_ message: String) {
        let entry = "\(sharedISO8601Formatter.string(from: Date())) \(message)\n"
        guard let data = entry.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            // File doesn't exist yet (or unwritable) — create it with this line.
            try? data.write(to: url, options: .atomic)
        }
    }
}
