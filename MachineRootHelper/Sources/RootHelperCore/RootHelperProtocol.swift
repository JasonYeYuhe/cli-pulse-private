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

    /// What this root-helper build can actually do. The app must treat a
    /// missing/false capability as "hide the control", like the user-helper's
    /// local_control_capability. `fan_control` is true once the daemon constructs
    /// a live FanController (M0 go decided: boost-only).
    func capabilities(reply: @escaping ([String: Bool]) -> Void)

    // ── M3 fan control (boost-only + heartbeat-gated; see FanController) ───────
    // The firmware does NOT self-revert after a controller crash (M0), so this is
    // ONLY safe with: revert-on-startup + boost-only clamp + heartbeat-gated hold
    // + launchd KeepAlive + a user-helper watchdog. NEVER exposes an arbitrary SMC
    // key/value — only a single boost target, clamped server-side to [auto, max].

    /// JSON array of current per-fan state (index/min/max/actual/target/mode).
    /// Read-only; the client renders the boost slider bounds off this.
    func getFanState(reply: @escaping (_ fansJSON: String) -> Void)

    /// Apply a BOOST to all fans (clamped boost-only to [auto, max]). Arms the
    /// heartbeat — the client MUST call `fanHeartbeat` on a short interval or the
    /// daemon reverts to auto. `appliedJSON` is the per-fan applied target.
    func setFanBoost(targetRPM: Int,
                     reply: @escaping (_ ok: Bool, _ error: String?, _ appliedJSON: String) -> Void)

    /// Feed the dead-man's-switch. `held` is false if there was no active boost to
    /// hold (client should stop heart-beating and refresh state).
    func fanHeartbeat(reply: @escaping (_ held: Bool) -> Void)

    /// Explicitly revert every fan to Apple auto (the client's "Auto" button and
    /// its teardown-on-close path).
    func revertFansToAuto(reply: @escaping (_ ok: Bool) -> Void)

    // ── DEFERRED — M4 root/other-user kill (owner chose "add later") ──────────
    //   func killPid(_ pid: Int, signal: Int32,
    //                reply: @escaping (_ ok: Bool, _ error: String?) -> Void)
    //   (see CommandGuard.isKillablePid + its ⚠️ resolve-comm-server-side note)
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
    public static let version = "0.0.2-m3-fan-boost"
}
