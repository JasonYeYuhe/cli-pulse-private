// KeepAwakeController.swift — v1.42 "Keep Awake" (Amphetamine-style).
//
// One-click "keep the Mac awake": holds an IOKit power assertion of type
// kIOPMAssertionTypePreventUserIdleSystemSleep — the DISPLAY may still sleep
// on its normal timer, but the SYSTEM won't idle-sleep while the assertion is
// held. This is exactly `caffeinate -i` / Amphetamine's default session:
//   • no privileges, no daemon, no entitlement — works in EVERY build
//     (MAS-sandboxed included; Amphetamine itself ships on the App Store);
//   • does NOT prevent lid-close sleep (clamshell needs external display
//     rules) and does NOT prevent a user-initiated  → Sleep;
//   • the assertion dies with this process, so a crash can never wedge the
//     machine awake (the OS releases assertions of dead processes).
//
// Held by the shared singleton so the LOCAL Machine-tab card and the REMOTE
// machine-command executor drive the SAME assertion (single owner, one truth).
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

    /// True while the power assertion is held.
    @Published public private(set) var isActive = false
    /// Wall-clock end for DISPLAY ONLY (countdown label). The authoritative
    /// expiry is monotonic (`expiresAtUptime`). nil while off or indefinite.
    @Published public private(set) var endsAt: Date?

    private var assertionID: IOPMAssertionID?
    private var expiresAtUptime: Double?
    private var ttlTask: Task<Void, Never>?

    // Injected seams (tests): real IOPM calls by default.
    private let createAssertion: @Sendable (String) -> IOPMAssertionID?
    private let releaseAssertion: @Sendable (IOPMAssertionID) -> Void
    private let now: @Sendable () -> Double

    public init(
        createAssertion: @escaping @Sendable (String) -> IOPMAssertionID? = { reason in
            var id: IOPMAssertionID = 0
            let rc = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
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
    /// the TTL (same assertion — no flicker). Returns false only when the OS
    /// refuses the assertion (effectively never in practice).
    @discardableResult
    public func enable(ttlSeconds: Int? = nil) -> Bool {
        // Reuse the live assertion when present; otherwise create one.
        if assertionID == nil {
            guard let id = createAssertion("CLI Pulse — Keep Awake") else { return false }
            assertionID = id
        }
        isActive = true
        armTTL(ttlSeconds)
        return true
    }

    /// Release the hold (idempotent).
    public func disable() {
        ttlTask?.cancel(); ttlTask = nil
        expiresAtUptime = nil
        endsAt = nil
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
    func setKeepAwake(_ on: Bool, ttlSeconds: Int?) async -> Bool
    func isKeepAwakeActive() async -> Bool
}

extension KeepAwakeController: KeepAwakeControlling {
    public func setKeepAwake(_ on: Bool, ttlSeconds: Int?) async -> Bool {
        on ? enable(ttlSeconds: ttlSeconds) : { disable(); return true }()
    }
    public func isKeepAwakeActive() async -> Bool { isActive }
}
#endif
