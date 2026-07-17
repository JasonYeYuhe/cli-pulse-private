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

    /// Rotate the token, waiting out a stalled container. **Never exits, never
    /// starts a second rotation.**
    ///
    /// Runs `rotate` on ONE detached thread and waits, reporting via `log` every
    /// `reportEvery` seconds so a stall is visible instead of silent. Returns the
    /// token once the consult resolves; rethrows whatever `rotate` throws (a throw
    /// is NOT a stall — the container answered).
    ///
    /// Why wait rather than retry (review: codex): a retry would `open(2)` again,
    /// which starts a SECOND TCC consult — i.e. a second permission dialog — and
    /// races the first on `AuthToken`'s FIXED tmp path
    /// (`helper-auth-token.tmp`), so two rotations can rename each other's
    /// temporary file and the returned token need not be the one installed on
    /// disk. Retrying makes the user's prompt problem worse and corrupts state;
    /// there is exactly one consult to answer, so we keep exactly one in flight.
    ///
    /// Why not give up and start anyway: everything the daemon needs lives in the
    /// same container — the UDS socket path, and the pairing that
    /// `cloudConfigSnapshot()` reads via `UserDefaults(suiteName:)`. A stalled
    /// container leaves nothing useful to do, so "degrade and carry on" is not
    /// available here. (The Python helper CAN run cloud-only while stalled,
    /// because its config is `~/.cli-pulse-helper.json`, outside the container.
    /// That asymmetry is why its design does not port directly.)
    ///
    /// Why not exit: this agent is `KeepAlive=true` with `ThrottleInterval=30`, so
    /// exiting is a 30s respawn loop — each respawn a fresh full-price consult and
    /// a fresh prompt. That is 1.29.0's mistake at a slower tempo.
    ///
    /// What this DOES buy over the pre-fix code, which called `rotateToken()`
    /// straight on the main thread: the main thread is never parked inside
    /// `open(2)` in the kernel, the stall is logged rather than silent, and the
    /// process stays killable so launchd and the user can still act on it.
    public static func rotateTokenWaitingForContainer(
        reportEvery: TimeInterval = defaultWaitSeconds,
        rotate: @escaping @Sendable () throws -> String = { try AuthToken.rotateToken() },
        log: (@Sendable (String) -> Void)? = nil
    ) throws -> String {
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
        worker.start()

        var waited: TimeInterval = 0
        while sem.wait(timeout: .now() + reportEvery) == .timedOut {
            waited += reportEvery
            log?(
                "cli_pulse_helper: app-group container access still stalled after "
                + "\(Int(waited))s. This is a TCC SystemPolicyAppData consult under "
                + "launchd — macOS is waiting for the user to answer \"CLI Pulse would "
                + "like to access data from other apps\". Holding ONE consult open and "
                + "waiting: retrying would only open a second one (another dialog), and "
                + "exiting would respawn into a third. Nothing else can start until this "
                + "resolves — the socket AND the pairing both live in that container."
            )
        }
        if let error = box.error { throw error }
        if waited > 0 {
            log?("cli_pulse_helper: app-group container access completed after ~\(Int(waited))s (TCC consult answered)")
        }
        // The worker signalled, so exactly one of token/error is set.
        return box.token ?? ""
    }
}
