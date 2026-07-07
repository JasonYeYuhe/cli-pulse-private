#if os(macOS)
import Foundation
import ServiceManagement

/// Install / uninstall the privileged fan-control root daemon via `SMAppService`
/// (macOS 13+). DEVID-only — a MAS/sandboxed build can neither bundle nor register
/// a privileged daemon, so callers gate on `#if DEVID_BUILD` (and the daemon is
/// simply absent from the MAS archive).
///
/// **macOS forces a user-approval step.** `register()` does NOT silently install a
/// root daemon — the OS puts it in "requires approval" and surfaces it in System
/// Settings ▸ Login Items & Extensions, where the user must enable it. There is no
/// way around this (by Apple's design, to stop apps installing root daemons
/// behind the user's back). So the UI flow is: Install → (System Settings opens) →
/// user enables → daemon runs → the Fan card's capability probe starts succeeding.
public enum FanDaemonInstallState: Equatable {
    case unsupported          // < macOS 13
    case notInstalled         // never registered / not found in the bundle
    case requiresApproval     // registered — user must enable it in System Settings
    case installed            // enabled + eligible to run
    case error(String)
}

public enum FanDaemonInstaller {
    /// Name of the LaunchDaemon plist embedded at
    /// `Contents/Library/LaunchDaemons/<plistName>` in the app bundle. Must match
    /// the daemon's Mach service (`RootHelperInterface.machServiceName`) contract.
    public static let plistName = "yyh.CLI-Pulse.machine-root-helper.plist"

    @available(macOS 13.0, *)
    private static var service: SMAppService { SMAppService.daemon(plistName: plistName) }

    public static func state() -> FanDaemonInstallState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        switch service.status {
        case .notRegistered: return .notInstalled
        case .enabled:       return .installed
        case .requiresApproval: return .requiresApproval
        case .notFound:      return .notInstalled
        @unknown default:    return .error("unknown SMAppService status \(service.status.rawValue)")
        }
    }

    /// Register the daemon. Triggers the OS approval flow — see the type doc.
    @discardableResult
    public static func install() -> FanDaemonInstallState {
        guard #available(macOS 13.0, *) else { return .unsupported }
        do {
            try service.register()
        } catch {
            // A common benign case: already registered → treat as current state.
            return state() == .notInstalled ? .error(error.localizedDescription) : state()
        }
        return state()
    }

    @discardableResult
    public static func uninstall() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        do { try service.unregister(); return true } catch { return false }
    }

    /// Open System Settings ▸ Login Items so the user can enable/approve the daemon.
    public static func openApprovalSettings() {
        guard #available(macOS 13.0, *) else { return }
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
