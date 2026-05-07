import Foundation
import Darwin

/// Shared utility for running short bounded subprocesses (`vm_stat`,
/// `ps`, etc.) used by the collectors. Combines three invariants the
/// naive `Process` + `waitUntilExit` pattern gets wrong:
///
///   1. **Concurrent stdout drain** — pipes to `Pipe()` and drains
///      via a detached `Task` so the child never blocks on the OS pipe
///      buffer (~64 KB on macOS). Without this, a `ps`/`vm_stat` that
///      emits more than the buffer holds blocks on `write()` until the
///      parent reads, but the parent is busy waiting for the child
///      to exit — classic deadlock.
///
///   2. **Cooperative cancellation** — uses `try await Task.sleep(...)`
///      in the polling loop so the outer task can cancel us. Wraps
///      the whole thing in `withTaskCancellationHandler` so cancel
///      reaps the child cleanly.
///
///   3. **Hard timeout with SIGTERM grace + SIGKILL** — bounded by
///      `timeoutSeconds`. On expiry we `process.terminate()` (SIGTERM),
///      give the child a 1-s grace period via a synchronous
///      `Thread.sleep` (deliberate; `Task.sleep` would honor any
///      outer cancel and skip the grace), then `kill(pid, SIGKILL)`
///      if still alive. Mirrors `GitCollector`'s approach in Slice 1.
///
/// Phase 4E Slice 2a Gemini P0/P1 fix — replaces the per-collector
/// hand-rolled subprocess code which had a `semaphore.wait()` /
/// `Thread.sleep` polling loop that could deadlock the cooperative
/// thread pool and ignored cancellation.
enum SubprocessRunner {

    /// Run `executable arguments...`, return UTF-8 stdout on success
    /// (exit code 0), `nil` on any failure (spawn error, non-zero
    /// exit, timeout, cancellation). Stderr is discarded.
    static func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // discard

        // Drain concurrently — start BEFORE we begin polling for exit
        // so a child that emits >64 KB doesn't block on a full pipe.
        let drainTask = Task<Data, Never>.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            drainTask.cancel()
            return nil
        }

        let pid = process.processIdentifier
        let deadlineNs = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutSeconds * 1_000_000_000)

        let success: Bool
        do {
            try await withTaskCancellationHandler {
                while process.isRunning {
                    if DispatchTime.now().uptimeNanoseconds > deadlineNs {
                        throw RunnerError.timedOut
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } onCancel: {
                // Synchronous reap on outer-task cancel. `Thread.sleep`
                // is deliberate — `Task.sleep` would re-throw the
                // cancellation immediately and skip the SIGTERM grace.
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 1.0)
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
            success = true
        } catch {
            // Either timeout or cancellation re-thrown out of the
            // polling loop. Reap the child if still alive.
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
            success = false
        }

        guard success, process.terminationStatus == 0 else {
            return nil
        }
        let data = await drainTask.value
        return String(data: data, encoding: .utf8)
    }

    private enum RunnerError: Error {
        case timedOut
    }
}
