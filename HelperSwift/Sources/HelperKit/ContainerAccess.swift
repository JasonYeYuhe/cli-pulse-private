import Foundation

/// The helper's first app-group-container access stalls under launchd. ROOT
/// CAUSE, measured on macOS 26.5 (2026-07-17): a **TCC
/// `kTCCServiceSystemPolicyAppData` consult**, not containermanagerd and not the
/// app-group entitlement.
///
///   * shell:   ~0.03s — the responsible process (Terminal/iTerm) already holds
///              the grant, so attribution short-circuits.
///   * launchd: 1–10s, wildly variable, >20s tail — no responsible app, so tccd
///              does full attribution + code-sign validation, and if it decides
///              to ASK the user, the `open(2)` blocks until they answer.
///   * no grant row: instant EPERM — a fast deny, not a hang.
///
/// **The cost is per-PROCESS and is never shared.** The first `open(2)` pays in
/// full; later opens in that process are ~0.02s. Nothing about the machine ever
/// gets "warmer" — which is why respawning to escape it cannot work, and why the
/// Python helper's 12s-watchdog-plus-`os._exit(75)` design respawned 2,816 times
/// across 10h07m without ever binding its socket. See
/// `PROJECT_FIX_2026-07-17_helper-watchdog-unbounded-respawn.md` and
/// `helper/cli_pulse_helper.py:_rotate_token_best_effort`, which this mirrors.
///
/// The Swift helper had the WORSE variant of the same bug: it called
/// `AuthToken.rotateToken()` straight on the main thread with only a `try/catch`.
/// The catch encodes the right policy ("continuing with empty token") — but a
/// HANG never throws, so it never ran. Observed live: the bundled helper blocked
/// in `open` for minutes (2564/2564 samples), holding a "CLI Pulse would like to
/// access data from other apps" prompt open and re-asking the user each time it
/// was dismissed. That is the pre-1.29 permanent silent hang, which is worse than
/// a restart loop because launchd cannot recover a hung process.
public enum ContainerAccess {

    /// Bounded wait for the first container touch. Sized to the MEASURED
    /// distribution (1–10s typical, >20s tail), not to an assumed "warm" cost —
    /// the Python helper's 12s ceiling was tripping on the tail and killing
    /// starts that would have succeeded a moment later.
    public static let defaultWaitSeconds: TimeInterval = 25.0

    /// Thread-safe result slot. The worker may still be running (blocked in the
    /// consult) when we abandon it, so every access is locked.
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _token: String?
        private var _error: Error?
        func finish(token: String?, error: Error?) {
            lock.lock(); defer { lock.unlock() }
            _token = token; _error = error
        }
        var token: String? { lock.lock(); defer { lock.unlock() }; return _token }
        var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
    }

    /// Run `rotate` with a deadline. **Never exits the process.**
    ///
    /// Returns the token on success, or `nil` when the deadline passed — meaning
    /// the container is stalled RIGHT NOW, and the caller must not touch it again
    /// this start (the UDS socket lives in that same container, so binding would
    /// hang the daemon outright).
    ///
    /// Rethrows whatever `rotate` throws: a raise is NOT a stall — the container
    /// answered, so the caller's existing best-effort handling is still correct
    /// and binding remains safe.
    ///
    /// The worker runs on a detached `Thread` that we simply abandon on timeout.
    /// It cannot keep the process alive (Foundation threads don't block `exit`),
    /// and if the stalled open ever completes it just writes the token, which the
    /// next start picks up. Doing this on the main thread — as the pre-fix code
    /// did — leaves no escape from a stall at all.
    public static func rotateTokenBestEffort(
        timeout: TimeInterval = defaultWaitSeconds,
        rotate: @escaping @Sendable () throws -> String = { try AuthToken.rotateToken() },
        log: (@Sendable (String) -> Void)? = nil
    ) throws -> String? {
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let worker = Thread {
            do {
                box.finish(token: try rotate(), error: nil)
            } catch {
                box.finish(token: nil, error: error)
            }
            sem.signal()
        }
        worker.name = "rotate-token"
        let started = Date()
        worker.start()

        if sem.wait(timeout: .now() + timeout) == .timedOut {
            log?(
                "error: app-group container access still stalled after \(Int(timeout))s — "
                + "starting WITHOUT the local UDS surface. This is a TCC "
                + "SystemPolicyAppData consult under launchd; it is per-process, so "
                + "respawning cannot help and we deliberately do not. Cloud sync keeps "
                + "running; the same-machine fast path returns on the next helper start."
            )
            return nil
        }
        if let error = box.error { throw error }
        let waited = Date().timeIntervalSince(started)
        if waited > 1.0 {
            // The consult being slow but COMPLETING is the normal launchd case —
            // and exactly what a too-tight ceiling would kill.
            log?("cli_pulse_helper: app-group container access took \(String(format: "%.1f", waited))s (TCC consult)")
        }
        return box.token
    }
}
