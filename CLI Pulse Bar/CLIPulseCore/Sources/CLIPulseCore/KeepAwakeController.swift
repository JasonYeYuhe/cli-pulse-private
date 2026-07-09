// KeepAwakeController.swift — v1.42 "Keep Awake" (Amphetamine-style).
//
// One-click "keep the Mac awake": holds an IOKit power assertion of type
// kIOPMAssertionTypePreventUserIdleSystemSleep — the DISPLAY may still sleep
// on its normal timer, but the SYSTEM won't idle-sleep while the assertion is
// held. This is exactly `caffeinate -i` / Amphetamine's default session:
//   • no privileges, no daemon, no entitlement — works in EVERY build
//     (MAS-sandboxed included; Amphetamine itself ships on the App Store);
//   • the assertion dies with this process, so a crash can never wedge the
//     machine awake (the OS releases assertions of dead processes).
//
// LID-CLOSED option (v1.42.1, Amphetamine's "Closed-Display Mode"): an
// ADDITIONAL kIOPMAssertionTypePreventSystemSleep assertion. On AC POWER it
// prevents lid-close (clamshell) sleep — screen off, system running, network
// up. On BATTERY the OS ignores it entirely (hard limit without root
// `pmset disablesleep`; `man caffeinate` documents -s as AC-only), so the UI
// labels the option "(AC power only)". The BASE idle assertion is always held
// too, so battery idle-sleep protection keeps working regardless.
//
// Held by the shared singleton so the LOCAL Machine-tab card and the REMOTE
// machine-command executor drive the SAME assertions (single owner, one truth).
// TTL uses the MONOTONIC clock (ProcessInfo.systemUptime) like the fan boost —
// wall-clock jumps can't stretch or clip a hold. nil TTL = indefinite
// (Amphetamine's default), bounded only by the user turning it off.

#if os(macOS)
import Foundation
import IOKit.pwr_mgt

@MainActor
public final class KeepAwakeController: ObservableObject {
    public static let shared = KeepAwakeController()

    /// Remote/server clamp is 60s..24h; the local UI may pass nil (indefinite).
    public static let minTTL = 60
    public static let maxTTL = 86_400

    /// Injected-seam assertion type names (also what tests assert on).
    public static let idleAssertionType = kIOPMAssertionTypePreventUserIdleSystemSleep as String
    public static let systemAssertionType = kIOPMAssertionTypePreventSystemSleep as String

    /// True while the base (idle) power assertion is held.
    @Published public private(set) var isActive = false
    /// True while the ADDITIONAL lid-close (PreventSystemSleep) assertion is
    /// held. Effective on AC power only — on battery the OS ignores it.
    @Published public private(set) var lidSleepPrevented = false
    /// Wall-clock end for DISPLAY ONLY (countdown label). The authoritative
    /// expiry is monotonic (`expiresAtUptime`). nil while off or indefinite.
    @Published public private(set) var endsAt: Date?

    private var assertionID: IOPMAssertionID?      // PreventUserIdleSystemSleep
    private var lidAssertionID: IOPMAssertionID?   // PreventSystemSleep (lid option)
    private var expiresAtUptime: Double?
    private var ttlTask: Task<Void, Never>?

    // Injected seams (tests): real IOPM calls by default. `type` is one of the
    // *AssertionType statics above.
    private let createAssertion: @Sendable (String, String) -> IOPMAssertionID?
    private let releaseAssertion: @Sendable (IOPMAssertionID) -> Void
    private let now: @Sendable () -> Double

    public init(
        createAssertion: @escaping @Sendable (String, String) -> IOPMAssertionID? = { reason, type in
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                type as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id)
            return rc == kIOReturnSuccess ? id : nil
        },
        releaseAssertion: @escaping @Sendable (IOPMAssertionID) -> Void = { id in
            IOPMAssertionRelease(id)
        },
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        self.now = now
    }

    /// Start (or restart) a keep-awake hold. `ttlSeconds` nil = indefinite;
    /// values are clamped to 60s..24h. Re-enabling while active just re-arms
    /// the TTL and adjusts the lid assertion (base assertion is reused — no
    /// flicker). Returns false only when the OS refuses the BASE assertion
    /// (effectively never); a lid-assertion failure degrades gracefully
    /// (`lidSleepPrevented` stays false, base hold still works).
    @discardableResult
    public func enable(ttlSeconds: Int? = nil, preventLidSleep: Bool = false) -> Bool {
        // Reuse the live base assertion when present; otherwise create one.
        if assertionID == nil {
            guard let id = createAssertion("CLI Pulse — Keep Awake", Self.idleAssertionType) else {
                return false
            }
            assertionID = id
        }
        isActive = true
        applyLidAssertion(preventLidSleep)
        armTTL(ttlSeconds)
        return true
    }

    /// Live-adjust the lid-close hold while a session is active (the Mac card's
    /// sub-toggle). No-op when inactive — the preference is applied on enable.
    public func setPreventLidSleep(_ on: Bool) {
        guard isActive else { return }
        applyLidAssertion(on)
    }

    /// Release the hold (idempotent) — both assertions.
    public func disable() {
        ttlTask?.cancel(); ttlTask = nil
        expiresAtUptime = nil
        endsAt = nil
        if let id = lidAssertionID {
            releaseAssertion(id)
            lidAssertionID = nil
        }
        lidSleepPrevented = false
        if let id = assertionID {
            releaseAssertion(id)
            assertionID = nil
        }
        isActive = false
    }

    /// Seconds until the TTL fires (nil while off or indefinite). Monotonic.
    public var remainingSeconds: Int? {
        guard isActive, let expires = expiresAtUptime else { return nil }
        return max(0, Int(expires - now()))
    }

    // MARK: - Lid (PreventSystemSleep) assertion

    private func applyLidAssertion(_ wanted: Bool) {
        if wanted, lidAssertionID == nil {
            // Graceful degrade on failure: base hold keeps working, the
            // published flag stays false so the UI tells the truth.
            lidAssertionID = createAssertion("CLI Pulse — Keep Awake (lid closed)", Self.systemAssertionType)
        } else if !wanted, let id = lidAssertionID {
            releaseAssertion(id)
            lidAssertionID = nil
        }
        lidSleepPrevented = lidAssertionID != nil
    }

    // MARK: - TTL (monotonic; single task, re-armed on every enable)

    private func armTTL(_ ttlSeconds: Int?) {
        ttlTask?.cancel(); ttlTask = nil
        guard let raw = ttlSeconds else {
            expiresAtUptime = nil
            endsAt = nil
            return   // indefinite
        }
        let ttl = min(max(raw, Self.minTTL), Self.maxTTL)
        expiresAtUptime = now() + Double(ttl)
        endsAt = Date().addingTimeInterval(Double(ttl))
        ttlTask = Task { [weak self] in
            // Sleep-then-recheck loop: systemUptime pauses across a (forced)
            // sleep, so a single fixed sleep could fire early relative to the
            // monotonic deadline. Loop until the deadline truly passes.
            while !Task.isCancelled {
                guard let self else { return }
                let remaining = await self.remainingForTTLTask()
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: UInt64(min(remaining, 30) * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.expireFromTTL()
        }
    }

    private func remainingForTTLTask() -> Double {
        guard let expires = expiresAtUptime else { return 0 }
        return expires - now()
    }

    private func expireFromTTL() {
        guard isActive, let expires = expiresAtUptime, now() >= expires else { return }
        disable()
    }
}

// MARK: - Executor seam

/// The keep-awake surface the remote machine-command executor drives.
/// `KeepAwakeController` conforms; tests inject a fake.
public protocol KeepAwakeControlling: Sendable {
    func setKeepAwake(_ on: Bool, ttlSeconds: Int?, preventLidSleep: Bool) async -> Bool
    func isKeepAwakeActive() async -> Bool
    func isLidSleepPrevented() async -> Bool
}

extension KeepAwakeController: KeepAwakeControlling {
    public func setKeepAwake(_ on: Bool, ttlSeconds: Int?, preventLidSleep: Bool) async -> Bool {
        on ? enable(ttlSeconds: ttlSeconds, preventLidSleep: preventLidSleep)
           : { disable(); return true }()
    }
    public func isKeepAwakeActive() async -> Bool { isActive }
    public func isLidSleepPrevented() async -> Bool { lidSleepPrevented }
}
#endif
