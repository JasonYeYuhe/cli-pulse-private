import Foundation
import RootHelperCore

// =============================================================================
// M2 root helper daemon — SKELETON. NOT wired into any shipped build. Runs only
// when the owner explicitly installs it (mechanism TBD after M0: SMAppService.
// daemon or a system-domain root .pkg LaunchDaemon — either registers the Mach
// service name below). Exposes ONLY ping/capabilities: no fan write, no kill.
// Its whole M2 job is to prove the audit_token → SecCode → Team-ID XPC auth gate
// end to end. Every privileged command (M3/M4) is added later, behind this same
// authenticated listener, gated + reviewed separately.
// =============================================================================

// Apple Developer Team ID (leaf cert subject.OU) that every caller must carry.
private let kTeamID = "KHMK6Q3L3K"
// Bundle identifiers permitted to call the daemon — the app + the user-helper.
// TODO(owner): confirm the final identifiers before this ever installs.
private let kAllowedIdentifiers = ["yyh.CLI-Pulse", "yyh.CLI-Pulse.helper"]

// MARK: - Race-free peer audit token

extension NSXPCConnection {
    /// NSXPCConnection carries a private `auditToken` (`audit_token_t`) that pins
    /// the exact sending process for this connection. There is no PUBLIC API to
    /// authenticate a peer's code signature, so reading it is required for secure
    /// XPC — Apple's own sample code does the equivalent via a bridging header.
    /// We read it reflectively (KVC boxes the struct as an NSValue) and repackage
    /// the raw bytes so `PeerAuthenticator.secCode(fromAuditToken:)` can resolve a
    /// SecCode. Fails closed (nil) if the property shape ever changes on a future
    /// OS — the listener then rejects the connection.
    ///
    /// SECURITY NOTE: prefer the per-connection `auditToken` over `processIdentifier`
    /// — a PID is TOCTOU-vulnerable to reuse; the audit token is not.
    var auditTokenData: Data? {
        guard responds(to: NSSelectorFromString("auditToken")),
              let boxed = value(forKey: "auditToken") as? NSValue else { return nil }
        // Validate the box ACTUALLY wraps an audit_token_t (32 bytes) before
        // copying — a future OS returning a differently-shaped NSValue must fail
        // CLOSED (nil), never yield a partially-filled (wrong) token. Checking
        // only that the selector exists is not enough (security review Finding 1).
        let expected = MemoryLayout<audit_token_t>.size
        var boxedSize = 0
        NSGetSizeAndAlignment(boxed.objCType, &boxedSize, nil)
        guard boxedSize == expected else { return nil }

        var token = audit_token_t()
        boxed.getValue(&token, size: expected)
        let data = withUnsafeBytes(of: &token) { Data($0) }

        // Reject an all-zero token: a zeroed audit_token_t maps to pid 0 / the
        // kernel — never a legitimate XPC peer, and exactly what a partial fill
        // would leave behind.
        guard data.contains(where: { $0 != 0 }) else { return nil }

        // Belt-and-suspenders: the token's pid must match the connection's own
        // reported pid. A mismatch means the box isn't this peer's token → reject.
        // pid is val[5] of audit_token_t (auid,euid,egid,ruid,rgid,PID,asid,pidver)
        // — read directly to avoid a libbsm link dependency for one accessor.
        let tokenPid = Int32(bitPattern: token.val.5)
        guard tokenPid > 0, tokenPid == processIdentifier else { return nil }
        return data
    }
}

// MARK: - Exported object (M2: introspection only, zero privileged effect)

final class RootHelper: NSObject, MachineRootHelperProtocol {
    func ping(reply: @escaping (String) -> Void) {
        reply("machine-root-helper \(RootHelperInterface.version) alive (pid \(getpid()), euid \(geteuid()))")
    }
    func capabilities(reply: @escaping ([String: Bool]) -> Void) {
        // M2: NO privileged capability is live. The client hides every control
        // whose capability is false/absent — same discipline as the user-helper.
        reply(["fan_control": false, "root_kill": false])
    }
}

// MARK: - Authenticated listener

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let auth = PeerAuthenticator(teamID: kTeamID, allowedIdentifiers: kAllowedIdentifiers)

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // THE SECURITY GATE. Reject any peer that is not our Team-ID-signed
        // app/helper, BEFORE exporting the interface. Fail closed on every error.
        guard let tokenData = newConnection.auditTokenData else {
            NSLog("[machine-root-helper] reject: no audit token for peer")
            return false
        }
        let code = PeerAuthenticator.secCode(fromAuditToken: tokenData)
        switch auth.decide(peerCode: code) {
        case .accept:
            break
        case .reject(let reason):
            NSLog("[machine-root-helper] reject: \(reason)")
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: MachineRootHelperProtocol.self)
        newConnection.exportedObject = RootHelper()
        newConnection.resume()
        return true
    }
}

// MARK: - Entry point

// Refuse to run un-privileged: the whole point is the root path. (M2 has no
// privileged command, but installing/running as non-root signals a misconfigured
// mechanism, so fail loudly rather than pretend.)
if geteuid() != 0 {
    FileHandle.standardError.write("machine-root-helper must run as root (euid 0).\n".data(using: .utf8)!)
    exit(1)
}

let delegate = ServiceDelegate()
let listener = NSXPCListener(machServiceName: RootHelperInterface.machServiceName)
listener.delegate = delegate
NSLog("[machine-root-helper] %@ listening on %@", RootHelperInterface.version, RootHelperInterface.machServiceName)
listener.resume()
RunLoop.main.run()
