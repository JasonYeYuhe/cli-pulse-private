import Foundation

/// Layered dead-man's-switch scaffold (DEV_PLAN rail 5). The fan-control danger
/// is that a `SIGKILL`/panic of the controlling process can't run cleanup, so a
/// forced-manual fan could be left stuck. The layered mitigation is: (a) the
/// daemon requires a periodic heartbeat from the app/user-helper — if it lapses,
/// the daemon reverts to Apple-auto; (b) the daemon re-asserts only a SHORT
/// manual window each heartbeat so a *dead* daemon lets the firmware auto-revert;
/// (c) a user-helper watchdog; (d) hardware TjMax as the ultimate backstop.
///
/// **In M2 there is NOTHING to revert (no fan write), so `onLapse` is a no-op /
/// log.** This type exists now — with an INJECTED clock so its timing contract is
/// unit-tested — so that when M3 wires `onLapse` to "revert all fans to auto",
/// the state machine is already proven. It does NOT itself run a timer; the
/// daemon ticks `check()` on its run loop (M2 leaves it un-armed).
public final class DeadMansSwitch {
    private let timeoutSeconds: Double
    private let now: () -> Double
    private let onLapse: () -> Void
    private let lock = NSLock()
    private var lastBeat: Double
    private var lapsedFired = false

    /// - Parameters:
    ///   - timeoutSeconds: silence longer than this fires `onLapse`.
    ///   - now: monotonic clock source (tests inject a fake).
    ///   - onLapse: revert action. M2 passes a logging no-op; M3 passes the fan
    ///     revert-to-auto.
    public init(timeoutSeconds: Double,
                now: @escaping () -> Double,
                onLapse: @escaping () -> Void) {
        precondition(timeoutSeconds > 0, "dead-man timeout must be positive")
        self.timeoutSeconds = timeoutSeconds
        self.now = now
        self.onLapse = onLapse
        self.lastBeat = now()
    }

    /// Feed the heartbeat. Re-arms the switch (a future lapse can fire again).
    public func beat() {
        lock.lock()
        lastBeat = now()
        lapsedFired = false
        lock.unlock()
    }

    /// Poll. Returns true iff the heartbeat has been silent past the timeout;
    /// fires `onLapse` EXACTLY ONCE per lapse (until the next `beat()`), so a
    /// tight poll loop doesn't spam the revert.
    @discardableResult
    public func check() -> Bool {
        lock.lock()
        let elapsed = now() - lastBeat
        let shouldFire = elapsed > timeoutSeconds && !lapsedFired
        if shouldFire { lapsedFired = true }
        lock.unlock()
        if shouldFire { onLapse() }
        return elapsed > timeoutSeconds
    }

    /// Seconds since the last heartbeat (diagnostics).
    public func silenceSeconds() -> Double {
        lock.lock(); defer { lock.unlock() }
        return now() - lastBeat
    }
}
