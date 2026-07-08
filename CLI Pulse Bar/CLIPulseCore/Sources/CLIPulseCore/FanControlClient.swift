#if os(macOS)
import Foundation
import os

private let fanLog = Logger(subsystem: "com.cli-pulse.bar", category: "fan-control")

/// App-side copy of the root daemon's XPC contract (the daemon defines the
/// authoritative one in `MachineRootHelper`). An XPC interface is shared by
/// contract, so the two must stay identical — see `MachineRootHelper/Sources/
/// RootHelperCore/RootHelperProtocol.swift`. Keep in lockstep.
@objc protocol MachineRootHelperXPC {
    func ping(reply: @escaping (String) -> Void)
    func capabilities(reply: @escaping ([String: Bool]) -> Void)
    func getFanState(reply: @escaping (_ fansJSON: String) -> Void)
    func setFanBoost(targetRPM: Int, reply: @escaping (_ ok: Bool, _ error: String?, _ appliedJSON: String) -> Void)
    func fanHeartbeat(reply: @escaping (_ held: Bool) -> Void)
    func revertFansToAuto(reply: @escaping (_ ok: Bool) -> Void)
    func setLowPowerMode(_ on: Bool, reply: @escaping (_ ok: Bool, _ error: String?) -> Void)
}

/// Client for the **root** fan-control daemon (DEVID only; the daemon is a
/// privileged LaunchDaemon). Distinct from `LocalSessionControlClient`, which
/// talks to the unsandboxed USER helper over a UDS. This talks to the root
/// daemon over a privileged Mach service and is only reachable when the owner
/// has installed that daemon — otherwise every call fails and the UI hides the
/// fan card.
///
/// Safety contract mirrored from the daemon: a boost is held ONLY while this
/// client keeps heart-beating. `startBoost` therefore arms a heartbeat timer, and
/// `stop()` / `deinit` revert to auto — so quitting the app or closing the view
/// returns the fans to Apple auto even before the daemon's own heartbeat timeout.
public final class FanControlClient: @unchecked Sendable, FanControlling {
    public static let machServiceName = "yyh.CLI-Pulse.machine-root-helper"
    // Well under the daemon's kHeartbeatTimeoutSeconds (8s) so a single dropped
    // beat doesn't trip the dead-man's-switch.
    private static let heartbeatInterval: TimeInterval = 2.5

    public struct FanInfo: Sendable, Identifiable, Equatable {
        public let index: Int
        public let minRPM: Int
        public let maxRPM: Int
        public let actualRPM: Int
        public let targetRPM: Int
        public let mode: Int          // 0 = auto, 1 = manual
        public var id: Int { index }
        public var isManual: Bool { mode == 1 }
    }

    private let queue = DispatchQueue(label: "com.cli-pulse.fan-control")
    private var connection: NSXPCConnection?
    private var heartbeat: DispatchSourceTimer?

    public init() {}
    deinit { heartbeat?.cancel() }

    // MARK: - Connection

    private func proxy(_ onError: @escaping () -> Void) -> MachineRootHelperXPC? {
        if connection == nil {
            let c = NSXPCConnection(machServiceName: Self.machServiceName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: MachineRootHelperXPC.self)
            c.invalidationHandler = { [weak self] in
                fanLog.debug("fan daemon connection invalidated")
                self?.queue.async { self?.connection = nil }
            }
            c.interruptionHandler = { fanLog.debug("fan daemon connection interrupted") }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { err in
            fanLog.debug("fan daemon proxy error: \(err.localizedDescription, privacy: .public)")
            onError()
        } as? MachineRootHelperXPC
    }

    private func call<T>(_ body: @escaping (MachineRootHelperXPC, @escaping (T) -> Void) -> Void,
                        timeout: TimeInterval = 3,
                        fallback: T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let done = Resumer(cont)
            queue.async {
                guard let p = self.proxy({ done.resume(fallback) }) else { done.resume(fallback); return }
                body(p) { value in done.resume(value) }
            }
            queue.asyncAfter(deadline: .now() + timeout) { done.resume(fallback) }
        }
    }

    /// Single-resume guard (an XPC reply + a timeout can both fire).
    private final class Resumer<T>: @unchecked Sendable {
        private let cont: CheckedContinuation<T, Never>
        private var done = false
        private let lock = NSLock()
        init(_ c: CheckedContinuation<T, Never>) { cont = c }
        func resume(_ v: T) { lock.lock(); let first = !done; done = true; lock.unlock(); if first { cont.resume(returning: v) } }
    }

    // MARK: - API

    /// The root daemon's capability map (empty if it's not installed/reachable).
    /// Drives which controls the Machine tab shows (fan_control, low_power_mode).
    public func capabilities() async -> [String: Bool] {
        await call({ (p, reply: @escaping ([String: Bool]) -> Void) in p.capabilities { reply($0) } }, fallback: [:])
    }

    /// True iff the root daemon is installed, reachable, and advertises fan
    /// control. The Machine tab shows the fan card only when this is true.
    public func isAvailable() async -> Bool {
        await capabilities()["fan_control"] == true
    }

    /// Toggle macOS Low Power Mode via the root daemon (reading the state is free
    /// client-side — `ProcessInfo.isLowPowerModeEnabled`; only setting needs root).
    @discardableResult
    public func setLowPowerMode(_ on: Bool) async -> Bool {
        await call({ (p, reply: @escaping (Bool) -> Void) in p.setLowPowerMode(on) { ok, _ in reply(ok) } }, fallback: false)
    }

    public func fanState() async -> [FanInfo] {
        let json = await call({ (p, reply: @escaping (String) -> Void) in p.getFanState { reply($0) } }, fallback: "[]")
        return Self.decodeFans(json)
    }

    /// Start (or adjust) a boost to `targetRPM` (the daemon clamps boost-only to
    /// [auto, max]). Arms the heartbeat so the boost is held. Returns the daemon's
    /// (ok, error).
    @discardableResult
    public func startBoost(targetRPM: Int) async -> (ok: Bool, error: String?) {
        let result: (Bool, String?) = await call({ (p, reply: @escaping ((Bool, String?)) -> Void) in
            p.setFanBoost(targetRPM: targetRPM) { ok, err, _ in reply((ok, err)) }
        }, fallback: (false, "fan daemon unreachable"))
        if result.0 { startHeartbeat() } else { stopHeartbeat() }
        return (result.0, result.1)
    }

    /// Revert all fans to Apple auto and stop heart-beating.
    @discardableResult
    public func revert() async -> Bool {
        stopHeartbeat()
        return await call({ p, reply in p.revertFansToAuto { reply($0) } }, fallback: false)
    }

    // MARK: - Heartbeat (holds the boost)

    private func startHeartbeat() {
        queue.async {
            self.heartbeat?.cancel()
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
            t.setEventHandler { [weak self] in
                guard let self, let p = self.proxy({}) else { return }
                p.fanHeartbeat { held in if !held { self.stopHeartbeat() } }
            }
            t.resume()
            self.heartbeat = t
        }
    }

    private func stopHeartbeat() {
        queue.async { self.heartbeat?.cancel(); self.heartbeat = nil }
    }

    // MARK: - Decode

    static func decodeFans(_ json: String) -> [FanInfo] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        func i(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? (v as? Int) ?? 0 }
        return arr.compactMap { row in
            guard let idx = row["index"] as? NSNumber ?? (row["index"] as? Int).map(NSNumber.init) else { return nil }
            return FanInfo(index: idx.intValue, minRPM: i(row["min"]), maxRPM: i(row["max"]),
                           actualRPM: i(row["actual"]), targetRPM: i(row["target"]), mode: i(row["mode"]))
        }
    }
}
#endif
