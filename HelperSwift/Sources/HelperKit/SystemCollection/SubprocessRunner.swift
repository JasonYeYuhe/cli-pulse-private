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
public enum SubprocessRunner {

    /// Granular result of a subprocess run. `KeychainReader` and other
    /// callers need to distinguish "process exited with code 44 because
    /// the Keychain item doesn't exist" from "watchdog tripped" — the
    /// former should not trigger a 24 h denial cache, the latter
    /// should. (Phase 4E Slice 2b Gemini P0.)
    public enum RunResult: Sendable, Equatable {
        /// `executable` exited 0. Returns its full stdout (may be empty).
        case success(stdout: String)
        /// `executable` exited non-zero. Returns the exit code AND
        /// whatever stdout was captured before exit (often empty for
        /// CLI tools that print errors to stderr only). Stderr is
        /// always discarded by this runner.
        case nonZeroExit(code: Int32, stdout: String)
        /// `Process.run()` itself threw — usually `executable` doesn't
        /// exist, or the spawn was denied by sandbox / SIP rules.
        case spawnError
        /// Hard `timeoutSeconds` deadline elapsed. The child is reaped
        /// (SIGTERM + 1 s grace + SIGKILL).
        case timedOut
        /// Outer task was cancelled before the child exited. The child
        /// is reaped as for `timedOut`.
        case cancelled
    }

    /// Granular variant — returns the exit code so callers like
    /// `KeychainReader` can disambiguate "service not found" (44)
    /// from "user denied" / "watchdog tripped".
    public static func runCapturingExit(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()  // discard

        let drainTask = Task<Data, Never>.detached(priority: .utility) {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }

        do {
            try process.run()
        } catch {
            drainTask.cancel()
            return .spawnError
        }

        let pid = process.processIdentifier
        let deadlineNs = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutSeconds * 1_000_000_000)

        enum WaitOutcome { case exited, timedOut, cancelled }
        var outcome: WaitOutcome = .exited
        do {
            try await withTaskCancellationHandler {
                while process.isRunning {
                    if DispatchTime.now().uptimeNanoseconds > deadlineNs {
                        throw RunnerError.timedOut
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
            } onCancel: {
                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 1.0)
                    if process.isRunning {
                        kill(pid, SIGKILL)
                    }
                }
            }
        } catch RunnerError.timedOut {
            outcome = .timedOut
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        } catch {
            outcome = .cancelled
            if process.isRunning {
                process.terminate()
                Thread.sleep(forTimeInterval: 1.0)
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }

        switch outcome {
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .exited:
            let data = await drainTask.value
            let stdout = String(data: data, encoding: .utf8) ?? ""
            let code = process.terminationStatus
            if code == 0 { return .success(stdout: stdout) }
            return .nonZeroExit(code: code, stdout: stdout)
        }
    }

    /// Convenience wrapper for callers that don't care about exit-code
    /// distinctions: returns stdout on success, `nil` on any failure.
    /// Existing 2a callers (`DeviceSnapshotCollector`, `SessionDetector`)
    /// continue to use this; KeychainReader uses `runCapturingExit`.
    public static func run(
        executable: URL,
        arguments: [String],
        timeoutSeconds: TimeInterval
    ) async -> String? {
        switch await runCapturingExit(
            executable: executable,
            arguments: arguments,
            timeoutSeconds: timeoutSeconds
        ) {
        case .success(let stdout): return stdout
        case .nonZeroExit, .spawnError, .timedOut, .cancelled: return nil
        }
    }

    private enum RunnerError: Error {
        case timedOut
    }
}
