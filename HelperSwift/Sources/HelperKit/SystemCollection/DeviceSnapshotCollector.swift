import Foundation
import Darwin

/// Collects a `DeviceSnapshot` at one tick — host CPU + memory
/// utilization. Mirrors the Python helper's `_collect_cpu_usage` /
/// `_collect_memory_usage` semantics 1:1.
///
/// Both metrics are deliberately int-percent (not float) and clamped
/// to 0…100. Errors degrade silently to 0 — the daemon never throws
/// out of `collect_all()`, just emits a partial result with the failed
/// component zeroed (matches Python's `try / except` graceful path).
public struct DeviceSnapshotCollector: Sendable {

    /// Override hooks for unit tests. The defaults invoke real `vm_stat`
    /// and read the live load average; tests inject canned outputs to
    /// pin the parser without spawning a subprocess.
    public struct TestHooks: Sendable {
        /// Returns the 1-minute load average. Default: `Darwin.getloadavg`.
        public var loadAverage1m: @Sendable () -> Double?

        /// Returns the host's logical CPU count. Default:
        /// `ProcessInfo.processInfo.activeProcessorCount`.
        public var cpuCount: @Sendable () -> Int

        /// Returns the raw stdout of `/usr/bin/vm_stat`. **Async** so
        /// the live path can use `Task.sleep` (which honors cooperative
        /// cancellation) and `await drainTask.value` (concurrent pipe
        /// drain — avoids 64 KB pipe-buffer deadlock if vm_stat ever
        /// produces unexpectedly large output). Tests pass a synchronous
        /// closure wrapped via `{ canned }` — Swift treats it as `async`
        /// without any ceremony. (Phase 4E Slice 2a Gemini P0/P1 fix.)
        public var vmStatOutput: @Sendable () async -> String?

        public init(
            loadAverage1m: @escaping @Sendable () -> Double?,
            cpuCount: @escaping @Sendable () -> Int,
            vmStatOutput: @escaping @Sendable () async -> String?
        ) {
            self.loadAverage1m = loadAverage1m
            self.cpuCount = cpuCount
            self.vmStatOutput = vmStatOutput
        }

        public static let live: TestHooks = TestHooks(
            loadAverage1m: { DeviceSnapshotCollector.liveLoadAverage1m() },
            cpuCount: { ProcessInfo.processInfo.activeProcessorCount },
            vmStatOutput: { await DeviceSnapshotCollector.liveVmStatOutput() }
        )
    }

    private let hooks: TestHooks

    public init(hooks: TestHooks = .live) {
        self.hooks = hooks
    }

    /// Top-level entry — collect both metrics. Never throws; component
    /// failures degrade silently to 0 (matches Python's `try/except`
    /// path in `collect_all`).
    public func collect() async -> DeviceSnapshot {
        async let cpu = collectCPU()
        async let memory = collectMemory()
        return await DeviceSnapshot(
            cpuUsage: cpu,
            memoryUsage: memory
        )
    }

    // MARK: - CPU (sync; pure arithmetic on the load-average reading)

    /// `min(100, max(0, int(load1m / cpuCount * 100)))`. Returns 0 on
    /// any error reading the load average. Mirrors Python's
    /// `_collect_cpu_usage`.
    public func collectCPU() -> Int {
        let count = max(hooks.cpuCount(), 1)
        guard let load = hooks.loadAverage1m() else { return 0 }
        return Self.cpuPercent(load: load, cpuCount: count)
    }

    /// Pure-function version of the CPU clamp+ratio for unit tests.
    public static func cpuPercent(load: Double, cpuCount: Int) -> Int {
        let count = max(cpuCount, 1)
        let pct = Int(load / Double(count) * 100.0)
        return max(0, min(100, pct))
    }

    private static func liveLoadAverage1m() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        let read = loads.withUnsafeMutableBufferPointer {
            Darwin.getloadavg($0.baseAddress, Int32($0.count))
        }
        guard read >= 1 else { return nil }
        return loads[0]
    }

    // MARK: - Memory (async via the vm_stat hook)

    /// Run `vm_stat` and compute used-percentage. Returns 0 on any
    /// failure — `nil` hook return, empty output, parse failure, or
    /// total-pages-zero. Mirrors Python's `_collect_memory_usage`.
    public func collectMemory() async -> Int {
        guard let output = await hooks.vmStatOutput(), !output.isEmpty else {
            return 0
        }
        return Self.memoryPercent(fromVmStat: output)
    }

    /// Pure-function memory-percent computation from raw vm_stat output.
    /// Same arithmetic as the Python helper — `(active+wired+compressed) /
    /// (free+speculative+active+wired+compressed+inactive)` — and the
    /// same 0-on-failure semantics.
    public static func memoryPercent(fromVmStat output: String) -> Int {
        let values = parseVmStat(output)
        let free = (values["Pages free"] ?? 0) + (values["Pages speculative"] ?? 0)
        let active = (values["Pages active"] ?? 0)
            + (values["Pages wired down"] ?? 0)
            + (values["Pages occupied by compressor"] ?? 0)
        let inactive = values["Pages inactive"] ?? 0
        let total = free + active + inactive
        guard total > 0 else { return 0 }
        let ratio = Double(active) / Double(total)
        return max(0, min(100, Int(ratio * 100.0)))
    }

    /// Parse `vm_stat` output into a `[key: pages]` dict. Each line
    /// has shape `Pages free: 12345.` — split on first colon then strip
    /// non-digit chars from the value, matching Python's
    /// `re.sub(r"[^0-9]", "", raw_value)`.
    public static func parseVmStat(_ output: String) -> [String: Int] {
        var values: [String: Int] = [:]
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let lineStr = String(line)
            guard let colonRange = lineStr.range(of: ":") else { continue }
            let key = String(lineStr[lineStr.startIndex..<colonRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let rawValue = String(lineStr[colonRange.upperBound..<lineStr.endIndex])
            let digits = rawValue.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            let digitsStr = String(String.UnicodeScalarView(digits))
            if !digitsStr.isEmpty, let parsed = Int(digitsStr) {
                values[key] = parsed
            }
        }
        return values
    }

    /// Run `/usr/bin/vm_stat` with bounded execution + concurrent stdout
    /// drain (avoids 64 KB pipe-buffer deadlock) + cooperative-
    /// cancellation honoring poll loop. Returns `nil` on any error.
    private static func liveVmStatOutput() async -> String? {
        return await SubprocessRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/vm_stat"),
            arguments: [],
            timeoutSeconds: 5.0
        )
    }
}
