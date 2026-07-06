import Foundation

/// The ENTIRE root command surface exposed over XPC. Deliberately tiny and
/// strictly typed. The root helper NEVER accepts an arbitrary SMC key/value or
/// an arbitrary (pid, signal) — every future privileged command is one narrowly-
/// typed method with server-side validation (see `CommandGuard`).
///
/// **M2 (this skeleton) implements ONLY `ping` + `capabilities`** — zero
/// privileged side effects — so the audit_token→SecCode→Team-ID auth gate can be
/// exercised end-to-end before any dangerous command exists.
///
/// M3 (fan) and M4 (root/other-user kill) each add ONE method here, INSIDE this
/// helper, gated + reviewed separately. They are written as comments now so the
/// intended shape is on record but none of it is reachable.
@objc public protocol MachineRootHelperProtocol {
    /// Liveness + version handshake. No side effects.
    func ping(reply: @escaping (String) -> Void)

    /// What this root-helper build can actually do. In M2 every privileged
    /// capability is false — the app must treat a missing/false capability as
    /// "hide the control", exactly like the user-helper's local_control_capability.
    func capabilities(reply: @escaping ([String: Bool]) -> Void)

    // ── DEFERRED — intentionally NOT part of the M2 protocol ──────────────────
    //
    // M3 fan control (ONLY after the M0 go/no-go + a real-hardware revert test):
    //   func setFan(index: Int, mode: Int, targetRPM: Int,
    //               reply: @escaping (_ ok: Bool, _ error: String?) -> Void)
    //   func revertAllFansToAuto(reply: @escaping (_ ok: Bool) -> Void)
    //   func heartbeat(reply: @escaping (_ ok: Bool) -> Void)   // dead-man's-switch feed
    //
    // M4 root/other-user kill (owner chose "add later"):
    //   func killPid(_ pid: Int, signal: Int32,
    //                reply: @escaping (_ ok: Bool, _ error: String?) -> Void)
}

/// Well-known identifiers for the XPC interface. Kept in the core so the daemon
/// and any future client wrapper agree on one source of truth.
public enum RootHelperInterface {
    /// Mach service name the daemon binds and a client connects to. Either
    /// install mechanism (SMAppService.daemon or a system-domain root .pkg
    /// LaunchDaemon) registers this same name — nothing here presumes which.
    /// TODO(owner): confirm this matches the final launchd/SMAppService plist.
    public static let machServiceName = "yyh.CLI-Pulse.machine-root-helper"

    /// Version string surfaced by `ping`, so a client can floor-check the daemon.
    public static let version = "0.0.1-m2-skeleton"
}
