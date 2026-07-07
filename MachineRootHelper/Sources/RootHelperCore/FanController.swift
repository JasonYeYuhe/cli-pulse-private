import Foundation

/// A single fan's live SMC state.
public struct FanState: Equatable {
    public let index: Int
    public let minRPM: Double
    public let maxRPM: Double
    public let actualRPM: Double
    public let targetRPM: Double
    public let mode: Int            // 0 = Apple auto, 1 = manual
    public init(index: Int, minRPM: Double, maxRPM: Double, actualRPM: Double, targetRPM: Double, mode: Int) {
        self.index = index; self.minRPM = minRPM; self.maxRPM = maxRPM
        self.actualRPM = actualRPM; self.targetRPM = targetRPM; self.mode = mode
    }
}

/// Abstraction over the SMC fan I/O so `FanController`'s SAFETY logic is unit-
/// testable with a fake, without touching hardware. The real implementation
/// (`RealSMC` in the daemon target) writes only `F{n}Md`/`F{n}Tg` (proven on the
/// owner's Mac in the M0 spike — no `Ftst` needed on this SoC). Writes return
/// false on any failure so the controller can fail SAFE.
public protocol FanSMC {
    func fanCount() -> Int
    func readFan(_ index: Int) -> FanState?
    @discardableResult func writeManualMode(_ index: Int, manual: Bool) -> Bool
    @discardableResult func writeTargetRPM(_ index: Int, rpm: Double) -> Bool
}

public struct FanActionResult: Equatable {
    public let ok: Bool
    public let error: String?
    /// Per-fan applied target after clamping (index → rpm). Empty on failure.
    public let appliedTargets: [Int: Double]
    public init(ok: Bool, error: String? = nil, appliedTargets: [Int: Double] = [:]) {
        self.ok = ok; self.error = error; self.appliedTargets = appliedTargets
    }
}

/// The safety-critical heart of fan control. Because the firmware does NOT
/// self-revert after a `kill -9` (M0), a manual boost is "sticky", so this type
/// enforces the layered fail-safe. ALL state AND all `smc` access are serialized
/// under a single `NSLock` (fan ops are infrequent; correctness > concurrency —
/// concurrent IOKit calls on one connection aren't safe anyway).
///
///   1. **Revert-on-startup** (init) — paired with launchd KeepAlive, a relaunch
///      after a SIGKILL clears the dead predecessor's stuck manual state.
///   2. **Boost-only** — `applyBoost` clamps each fan to >= its captured auto RPM;
///      a stuck fan is always stuck-HIGH (safe), never stuck-LOW.
///   3. **Heartbeat-gated hold** — a boost is held only while the client
///      heartbeats; `tick()` reverts on lapse.
///   4. **Explicit revert** — `revertToAuto()` on the client's Auto button / stop.
///
/// EVERY write result is checked. A failed write NEVER leaves a fan stranded in
/// manual: apply reverts on failure; tick/revert retry on the next tick until the
/// fan is confirmed back in auto. TjMax throttling is the ultimate backstop.
public final class FanController {
    private let smc: FanSMC
    private let now: () -> Double
    private let heartbeatTimeout: Double
    private let lock = NSLock()
    // ── all fields below are guarded by `lock` ──
    private var boostActive = false
    private var lastBeat: Double
    // Auto-demand floor per fan, captured at boost-SESSION start (fan in auto) and
    // reused for in-session adjustments — never re-derived from a fan already in
    // manual (its F{n}Tg is then the manual target and the floor would ratchet).
    private var capturedFloors: [Int: Double] = [:]

    public init(smc: FanSMC, heartbeatTimeout: Double, now: @escaping () -> Double,
                revertOnInit: Bool = true) {
        precondition(heartbeatTimeout > 0, "heartbeat timeout must be positive")
        self.smc = smc
        self.heartbeatTimeout = heartbeatTimeout
        self.now = now
        self.lastBeat = now()
        if revertOnInit {
            lock.lock(); _ = revertAllToAutoLocked(); lock.unlock()
        }
    }

    /// Write auto (mode 0) to every fan. Returns true iff EVERY write succeeded.
    /// Assumes `lock` is held. Does NOT touch `boostActive`/`capturedFloors` — the
    /// caller updates state so it can decide (e.g. keep boostActive armed on a
    /// partial failure so the dead-man's-switch retries).
    private func revertAllToAutoLocked() -> Bool {
        let n = max(smc.fanCount(), 0)
        var allOK = true
        for i in 0..<n where !smc.writeManualMode(i, manual: false) { allOK = false }
        return allOK
    }

    /// Apply a boost to every fan, clamped boost-only into [capturedAuto, max].
    /// Fails SAFE: refuses without touching hardware if any fan's range is
    /// unreadable, and if any WRITE fails it reverts everything to auto and
    /// returns ok:false (never leaves a fan stuck manual at an unverified target).
    @discardableResult
    public func applyBoost(targetRPM: Double) -> FanActionResult {
        lock.lock(); defer { lock.unlock() }
        let n = smc.fanCount()
        guard n > 0 else { return FanActionResult(ok: false, error: "no fans") }

        // Pre-validate + clamp EVERY fan before writing any (floors committed only
        // on full success — a mid-loop failure must not mutate session floors).
        var clamped: [Int: Double] = [:]
        var floors: [Int: Double] = [:]
        for i in 0..<n {
            guard let st = smc.readFan(i) else {
                return FanActionResult(ok: false, error: "fan \(i) unreadable — refusing (fail-safe)")
            }
            let floor = capturedFloors[i] ?? max(st.actualRPM, st.targetRPM)
            floors[i] = floor
            switch CommandGuard.clampBoostTarget(requestedRPM: targetRPM, autoFloorRPM: floor,
                                                 minRPM: st.minRPM, maxRPM: st.maxRPM) {
            case .success(let rpm): clamped[i] = rpm
            case .failure(let e): return FanActionResult(ok: false, error: "fan \(i) range invalid (\(e))")
            }
        }

        // Write mode THEN target (the sequence M0 proved this SoC accepts), and
        // CHECK BOTH results. On any failure, revert everything to auto and report
        // failure — do NOT leave a fan in manual at an unverified/pre-existing
        // (possibly below-auto) target. (Ordering note: target-before-mode would
        // let a failed mode-flip leave the fan in auto, but M0 only validated
        // mode-then-target on this SoC; the revert-on-failure below makes either
        // ordering safe, so we keep the proven one.)
        for i in clamped.keys.sorted() {
            let rpm = clamped[i]!
            let okMode = smc.writeManualMode(i, manual: true)
            let okTarget = okMode ? smc.writeTargetRPM(i, rpm: rpm) : false
            if !okMode || !okTarget {
                _ = revertAllToAutoLocked()          // best-effort: put every fan back to auto
                boostActive = false
                capturedFloors.removeAll()
                return FanActionResult(ok: false,
                                       error: "fan \(i) write failed — reverted to auto (fail-safe)")
            }
        }

        capturedFloors = floors
        boostActive = true
        lastBeat = now()
        return FanActionResult(ok: true, appliedTargets: clamped)
    }

    /// Feed the heartbeat (client alive + wants the boost held).
    public func heartbeat() { lock.lock(); lastBeat = now(); lock.unlock() }

    /// Poll on the daemon run loop. Reverts to auto if a held boost's heartbeat
    /// has lapsed. Returns true iff it reverted SUCCESSFULLY on this call. If the
    /// revert write fails, `boostActive` stays armed so the NEXT tick retries —
    /// the fan is never abandoned in manual.
    @discardableResult
    public func tick() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard boostActive, now() - lastBeat > heartbeatTimeout else { return false }
        let ok = revertAllToAutoLocked()
        if ok {
            boostActive = false
            capturedFloors.removeAll()
        }
        // On failure: leave boostActive == true so the next tick retries.
        return ok
    }

    /// Explicitly revert every fan to Apple auto. Returns ok:false (and stays
    /// armed) if any fan failed to revert, so the dead-man's-switch keeps trying.
    @discardableResult
    public func revertToAuto() -> FanActionResult {
        lock.lock(); defer { lock.unlock() }
        let ok = revertAllToAutoLocked()
        if ok {
            boostActive = false
            capturedFloors.removeAll()
        }
        return FanActionResult(ok: ok, error: ok ? nil : "one or more fans failed to revert")
    }

    /// Snapshot of every fan (for the client UI / getFanState). Under the lock so
    /// SMC reads don't interleave with writes on the same IOKit connection.
    public func snapshot() -> [FanState] {
        lock.lock(); defer { lock.unlock() }
        return (0..<max(smc.fanCount(), 0)).compactMap { smc.readFan($0) }
    }

    public var isBoostActive: Bool { lock.lock(); defer { lock.unlock() }; return boostActive }
}
