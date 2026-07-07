import Foundation
import RootHelperCore

// `machine-root-helper xpcprobe` — acts as a CLIENT: connects to the running
// daemon's Mach service and calls the real XPC methods. Used to validate the
// audit_token → SecCode → Team-ID auth GATE on real hardware with a genuinely
// code-signed peer (which unit tests can't cover). When this binary is signed
// Developer ID + identifier ∈ kAllowedIdentifiers, the daemon should ACCEPT it;
// ad-hoc / wrong-team / wrong-identifier should be REJECTED (the connection is
// dropped and calls time out).
func runXpcProbe() -> Int32 {
    let conn = NSXPCConnection(machServiceName: RootHelperInterface.machServiceName, options: .privileged)
    conn.remoteObjectInterface = NSXPCInterface(with: MachineRootHelperProtocol.self)
    conn.invalidationHandler = { FileHandle.standardError.write("[probe] connection invalidated\n".data(using: .utf8)!) }
    conn.interruptionHandler = { FileHandle.standardError.write("[probe] connection interrupted\n".data(using: .utf8)!) }
    conn.resume()

    guard let proxy = conn.remoteObjectProxyWithErrorHandler({ err in
        FileHandle.standardError.write("[probe] proxy error: \(err.localizedDescription)\n".data(using: .utf8)!)
    }) as? MachineRootHelperProtocol else {
        print("[probe] FAILED to get remote proxy"); return 1
    }

    func call(_ name: String, timeout: TimeInterval = 5, _ body: (@escaping () -> Void) -> Void) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        body { sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            print("[probe] \(name): TIMEOUT — daemon REJECTED this peer (or not running)")
            return false
        }
        return true
    }

    var ok = true
    ok = call("ping") { done in proxy.ping { s in print("[probe] ping -> \(s)"); done() } } && ok
    if !ok { conn.invalidate(); return 2 }   // rejected → no point continuing
    _ = call("capabilities") { done in proxy.capabilities { c in print("[probe] capabilities -> \(c)"); done() } }
    _ = call("getFanState") { done in proxy.getFanState { j in print("[probe] fanState -> \(j)"); done() } }
    print("[probe] ACCEPTED — XPC auth gate let this signed peer through, round-trip OK")
    conn.invalidate()
    return 0
}
