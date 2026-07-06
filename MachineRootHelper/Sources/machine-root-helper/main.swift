import Foundation
import IOKit
import RootHelperCore

// =============================================================================
// machine-root-helper — root daemon for boost-only fan control (M2 auth + M3 fan).
// NOT wired into any shipped build; runs only when the owner installs it (mechanism
// TBD after M0 — SMAppService.daemon or a system-domain root .pkg LaunchDaemon —
// either registers the Mach service below). REQUIRES launchd KeepAlive so a
// SIGKILL'd daemon relaunches and reverts to auto (the firmware does NOT self-
// revert — M0). Every command runs behind the audit_token → SecCode → Team-ID
// gate; fan writes are boost-only + heartbeat-gated (see FanController).
// =============================================================================

private let kTeamID = "KHMK6Q3L3K"
// TODO(owner): confirm the final identifiers before this ever installs.
private let kAllowedIdentifiers = ["yyh.CLI-Pulse", "yyh.CLI-Pulse.helper"]
// Client silence after which a held boost reverts to auto. Short = tight stuck-
// window bound; must exceed the client's heartbeat interval with margin.
private let kHeartbeatTimeoutSeconds = 8.0

// MARK: - Race-free peer audit token

extension NSXPCConnection {
    /// NSXPCConnection carries a private `auditToken` (`audit_token_t`) pinning the
    /// exact sending process. No PUBLIC API authenticates a peer's code signature,
    /// so reading it is required for secure XPC. Read reflectively (KVC boxes the
    /// struct as NSValue) and validated to fail CLOSED. Prefer this over
    /// `processIdentifier` (a PID is TOCTOU-vulnerable to reuse).
    var auditTokenData: Data? {
        guard responds(to: NSSelectorFromString("auditToken")),
              let boxed = value(forKey: "auditToken") as? NSValue else { return nil }
        // Validate the box wraps a 32-byte audit_token_t — a future OS returning a
        // differently-shaped NSValue must fail CLOSED, not yield a wrong token.
        let expected = MemoryLayout<audit_token_t>.size
        var boxedSize = 0
        NSGetSizeAndAlignment(boxed.objCType, &boxedSize, nil)
        guard boxedSize == expected else { return nil }

        var token = audit_token_t()
        boxed.getValue(&token, size: expected)
        let data = withUnsafeBytes(of: &token) { Data($0) }
        // Reject an all-zero token (pid 0 / kernel — never a real peer).
        guard data.contains(where: { $0 != 0 }) else { return nil }
        // Belt-and-suspenders: token pid (val[5]) must match the connection's pid.
        let tokenPid = Int32(bitPattern: token.val.5)
        guard tokenPid > 0, tokenPid == processIdentifier else { return nil }
        return data
    }
}

// MARK: - Exported object (shares ONE FanController across all connections)

final class RootHelper: NSObject, MachineRootHelperProtocol {
    private let fan: FanController
    init(fan: FanController) { self.fan = fan }

    func ping(reply: @escaping (String) -> Void) {
        reply("machine-root-helper \(RootHelperInterface.version) alive (pid \(getpid()), euid \(geteuid()))")
    }
    func capabilities(reply: @escaping ([String: Bool]) -> Void) {
        // Fan control is LIVE (boost-only). root_kill (M4) stays off.
        reply(["fan_control": true, "root_kill": false])
    }
    func getFanState(reply: @escaping (String) -> Void) {
        reply(Self.jsonFans(fan.snapshot()))
    }
    func setFanBoost(targetRPM: Int, reply: @escaping (Bool, String?, String) -> Void) {
        let r = fan.applyBoost(targetRPM: Double(targetRPM))
        let applied = r.appliedTargets.map { ["index": $0.key, "rpm": Int($0.value.rounded())] as [String: Int] }
        let json = (try? JSONSerialization.data(withJSONObject: applied)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        reply(r.ok, r.error, json)
    }
    func fanHeartbeat(reply: @escaping (Bool) -> Void) {
        let held = fan.isBoostActive
        if held { fan.heartbeat() }
        reply(held)
    }
    func revertFansToAuto(reply: @escaping (Bool) -> Void) {
        reply(fan.revertToAuto().ok)
    }

    private static func jsonFans(_ fans: [FanState]) -> String {
        let arr = fans.map { [
            "index": $0.index, "min": Int($0.minRPM.rounded()), "max": Int($0.maxRPM.rounded()),
            "actual": Int($0.actualRPM.rounded()), "target": Int($0.targetRPM.rounded()), "mode": $0.mode,
        ] as [String: Int] }
        return (try? JSONSerialization.data(withJSONObject: arr)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
}

// MARK: - Authenticated listener

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let auth = PeerAuthenticator(teamID: kTeamID, allowedIdentifiers: kAllowedIdentifiers)
    private let fan: FanController
    init(fan: FanController) { self.fan = fan }

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // THE SECURITY GATE — reject any peer that isn't our Team-ID-signed
        // app/helper, BEFORE exporting the interface. Fail closed on every error.
        guard let tokenData = newConnection.auditTokenData else {
            NSLog("[machine-root-helper] reject: no audit token for peer"); return false
        }
        switch auth.decide(peerCode: PeerAuthenticator.secCode(fromAuditToken: tokenData)) {
        case .accept: break
        case .reject(let reason): NSLog("[machine-root-helper] reject: \(reason)"); return false
        }
        newConnection.exportedInterface = NSXPCInterface(with: MachineRootHelperProtocol.self)
        newConnection.exportedObject = RootHelper(fan: fan)   // shared controller
        newConnection.resume()
        return true
    }
}

// MARK: - Entry point

if geteuid() != 0 {
    FileHandle.standardError.write("machine-root-helper must run as root (euid 0).\n".data(using: .utf8)!)
    exit(1)
}

guard let smc = RealSMC() else {
    FileHandle.standardError.write("could not open AppleSMC.\n".data(using: .utf8)!)
    exit(1)
}

// Construct the controller — this REVERTS every fan to auto immediately (layer 1:
// a launchd relaunch after a SIGKILL clears the dead predecessor's stuck manual).
let fanController = FanController(smc: smc, heartbeatTimeout: kHeartbeatTimeoutSeconds,
                                 now: { ProcessInfo.processInfo.systemUptime })

// Dead-man's-switch poll — revert to auto when the client heartbeat lapses.
let tickTimer = Timer(timeInterval: 2.0, repeats: true) { _ in _ = fanController.tick() }
RunLoop.main.add(tickTimer, forMode: .common)

// Graceful termination → revert. Uses DispatchSource (runs OUTSIDE signal context,
// so the SMC writes in revertToAuto are safe — a raw signal handler would not be).
// This covers SIGTERM (launchd stop) / SIGINT; it CANNOT cover SIGKILL — that path
// is handled by revert-on-startup + launchd KeepAlive instead.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        // Retry the revert before exiting: on a `launchctl bootout`/uninstall the
        // job is being REMOVED, so KeepAlive-relaunch + revert-on-startup can't
        // save a failed revert here — this is the last chance to un-stick the fan.
        var reverted = false
        for _ in 0..<5 {
            if fanController.revertToAuto().ok { reverted = true; break }
            usleep(200_000)   // 0.2s between tries — transient SMC busy
        }
        NSLog("[machine-root-helper] signal — fans reverted=%@; exiting", reverted ? "yes" : "NO")
        exit(reverted ? 0 : 1)
    }
    src.resume()
    signalSources.append(src)
}

let delegate = ServiceDelegate(fan: fanController)
let listener = NSXPCListener(machServiceName: RootHelperInterface.machServiceName)
listener.delegate = delegate
NSLog("[machine-root-helper] %@ listening on %@", RootHelperInterface.version, RootHelperInterface.machServiceName)
listener.resume()
RunLoop.main.run()
