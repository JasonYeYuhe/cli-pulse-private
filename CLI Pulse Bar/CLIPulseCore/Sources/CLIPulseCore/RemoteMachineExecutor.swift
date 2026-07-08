// RemoteMachineExecutor.swift — v1.41 "Mobile Machine", Track B Mac side.
//
// The phone enqueues a fan/LPM REQUEST in the cloud `machine_commands` queue; the
// Python helper relays it over the local UDS; THIS executor (the Mac app, DEVID
// only) is what actually drives the root fan daemon via FanControlClient. The
// helper can't speak NSXPC, so the fan dead-man heartbeat (FanControlClient's
// 2.5 s client beat / the daemon's 8 s dead-man) stays entirely local — a cloud
// command is a *request*, never a hold.
//
// Loop (~2 s) while the Settings opt-in is ON && the fan daemon isAvailable():
//   1. revert a held boost whose TTL expired OR that we can no longer honor;
//   2. report our live control state so the phone renders ONLY controls we honor
//      (the helper treats a report as "alive" for 15 s — we MUST report each tick);
//   3. pull queued commands, execute via FanControlClient, ack each with a typed result.
//
// Safety invariants (DEV_PLAN §7): opt-in default OFF; boost bounded by a TTL we
// revert locally; on stop() we revert; on app quit (no quit hook exists) the
// FanControlClient dealloc stops the beat and the daemon's 8 s dead-man reverts.
//
// Kept deliberately I/O-free at its core: `tick()` is driven synchronously in
// tests with a fake FanControlling + fake relay + injected clock (mirrors the
// root daemon's DeadMansSwitch test pattern) — no real timers, no XPC, no UDS.

import Foundation

#if os(macOS)

/// One fan/LPM command drained from the helper relay.
public struct RemoteMachineCommand: Sendable, Equatable {
    public let id: String
    public let kind: String        // set_fan_target | revert_fan_auto | set_low_power_mode
    public let rpm: Int?           // set_fan_target
    public let ttlSeconds: Int?    // set_fan_target (boost hold duration)
    public let on: Bool?           // set_low_power_mode
    public let createdAt: Double?   // epoch seconds (server), for staleness defense-in-depth

    public init(id: String, kind: String, rpm: Int? = nil, ttlSeconds: Int? = nil,
                on: Bool? = nil, createdAt: Double? = nil) {
        self.id = id; self.kind = kind; self.rpm = rpm
        self.ttlSeconds = ttlSeconds; self.on = on; self.createdAt = createdAt
    }
}

/// The executor's live control state, reported to the helper each tick.
public struct RemoteMachineControlState: Sendable, Equatable {
    public let remoteFan: Bool
    public let remoteLPM: Bool
    public let boostActive: Bool
    public let boostTargetRPM: Int?

    public init(remoteFan: Bool, remoteLPM: Bool, boostActive: Bool, boostTargetRPM: Int?) {
        self.remoteFan = remoteFan; self.remoteLPM = remoteLPM
        self.boostActive = boostActive; self.boostTargetRPM = boostTargetRPM
    }
}

/// The fan-daemon surface the executor drives. `FanControlClient` conforms; tests
/// inject a fake. (Boost-only + LPM; the 2.5 s hold heartbeat is armed inside
/// startBoost and stopped inside revert — the executor only manages the TTL.)
public protocol FanControlling: Sendable {
    func isAvailable() async -> Bool
    func startBoost(targetRPM: Int) async -> (ok: Bool, error: String?)
    func revert() async -> Bool
    func setLowPowerMode(_ on: Bool) async -> Bool
}

/// The helper-UDS relay surface. `LocalSessionControlClient` conforms; tests inject a fake.
public protocol MachineControlRelaying: Sendable {
    func pullMachineCommands() async throws -> [RemoteMachineCommand]
    func completeMachineCommand(id: String, status: String, error: String?) async throws
    func reportMachineControlState(_ state: RemoteMachineControlState) async throws
}

/// Default AppStorage/UserDefaults key gating remote machine control (default OFF).
public let kRemoteMachineControlEnabledKey = "cli_pulse_remote_machine_control_enabled"

public actor RemoteMachineExecutor {
    private let fan: FanControlling
    private let relay: MachineControlRelaying
    private let isEnabled: @Sendable () -> Bool
    private let now: @Sendable () -> Double
    private let pollIntervalNanos: UInt64

    // Boost hold state (only mutated on the actor).
    private var boostActive = false
    private var boostTargetRPM: Int?
    private var boostStartedAt: Double?
    private var boostTTL: Double?

    private var pollTask: Task<Void, Never>?

    public init(
        fan: FanControlling,
        relay: MachineControlRelaying,
        isEnabled: @escaping @Sendable () -> Bool = {
            UserDefaults.standard.bool(forKey: kRemoteMachineControlEnabledKey)
        },
        now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 },
        pollIntervalNanos: UInt64 = 2_000_000_000
    ) {
        self.fan = fan
        self.relay = relay
        self.isEnabled = isEnabled
        self.now = now
        self.pollIntervalNanos = pollIntervalNanos
    }

    // MARK: - Lifecycle

    public func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: (await self?.pollIntervalNanos) ?? 2_000_000_000)
            }
        }
    }

    public func stop() async {
        pollTask?.cancel()
        pollTask = nil
        if boostActive { await revertBoost() }
        // Best-effort: tell the phone controls are gone (helper freshness also lapses in 15 s).
        try? await relay.reportMachineControlState(
            RemoteMachineControlState(remoteFan: false, remoteLPM: false, boostActive: false, boostTargetRPM: nil))
    }

    /// True while a boost is being held (test/inspection).
    public var isBoosting: Bool { boostActive }

    // MARK: - One cycle (driven directly in tests)

    public func tick() async {
        let toggle = isEnabled()
        let available = await fan.isAvailable()
        let canControl = toggle && available

        // 1. Revert a held boost whose TTL expired OR that we can no longer honor
        //    (opt-in flipped off / daemon vanished). The FanControlClient heartbeat
        //    + daemon dead-man are the backstop; this is the prompt, in-app revert.
        if boostActive {
            let expired = boostStartedAt.map { now() - $0 >= (boostTTL ?? 0) } ?? true
            if expired || !canControl {
                await revertBoost()
            }
        }

        // 2. Feature off → go idle. We stop reporting; the helper's 15 s control
        //    freshness lapses and the next heartbeat clears devices.machine_controls,
        //    so the phone hides the controls. No UDS traffic while off (the default).
        guard toggle else { return }

        // 3. Report live state every tick so the phone renders ONLY honorable
        //    controls. Daemon unavailable → report false so the phone hides them.
        let state = RemoteMachineControlState(
            remoteFan: available, remoteLPM: available,
            boostActive: boostActive, boostTargetRPM: boostTargetRPM)
        try? await relay.reportMachineControlState(state)

        guard available else { return }

        // 4. Pull + execute. (The helper already dropped commands pulled >60 s ago;
        //    we additionally never actuate — the server validated the payload.)
        let commands = (try? await relay.pullMachineCommands()) ?? []
        for cmd in commands {
            await execute(cmd)
        }
    }

    // MARK: - Execute one command

    private func execute(_ cmd: RemoteMachineCommand) async {
        switch cmd.kind {
        case "set_fan_target":
            guard let rpm = cmd.rpm else {
                await complete(cmd, status: "failed", error: "clamped"); return
            }
            let (ok, err) = await fan.startBoost(targetRPM: rpm)
            if ok {
                boostActive = true
                boostTargetRPM = rpm
                boostStartedAt = now()
                boostTTL = Double(cmd.ttlSeconds ?? 900)
                await complete(cmd, status: "done", error: nil)
            } else {
                await complete(cmd, status: "failed", error: err ?? "daemon_unavailable")
            }

        case "revert_fan_auto":
            let ok = await fan.revert()
            clearBoostState()
            await complete(cmd, status: ok ? "done" : "failed", error: ok ? nil : "daemon_unavailable")

        case "set_low_power_mode":
            guard let on = cmd.on else {
                await complete(cmd, status: "failed", error: "clamped"); return
            }
            let ok = await fan.setLowPowerMode(on)
            await complete(cmd, status: ok ? "done" : "failed", error: ok ? nil : "daemon_unavailable")

        default:
            await complete(cmd, status: "failed", error: "unknown_kind")
        }
    }

    private func complete(_ cmd: RemoteMachineCommand, status: String, error: String?) async {
        try? await relay.completeMachineCommand(id: cmd.id, status: status, error: error)
    }

    private func revertBoost() async {
        _ = await fan.revert()
        clearBoostState()
    }

    private func clearBoostState() {
        boostActive = false
        boostTargetRPM = nil
        boostStartedAt = nil
        boostTTL = nil
    }
}

#endif
