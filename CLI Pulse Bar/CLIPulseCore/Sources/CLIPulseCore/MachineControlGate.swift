import Foundation

/// Machine controls M1: pure runtime gate for the Machine tab's
/// "End Process" affordance. Extracted from `MachineHealthView` so the
/// gating logic is unit-testable without SwiftUI / AppState.
///
/// This covers the RUNTIME gates only. The BUILD gate (`#if DEVID_BUILD`)
/// and the sandbox gate (`MASSandboxGate`) are compile/host-level and are
/// applied by the view around every call site — a MAS build never even
/// compiles the affordance, so this predicate is only ever reached in a
/// Developer-ID build talking to an unsandboxed helper.
///
/// All four runtime conditions must hold to offer a kill on a given row:
///   1. the owner opted in (`machineControlsEnabled` Settings toggle),
///   2. the helper reports it can kill (`capability["kill_process"]`),
///   3. the process is owned by the current user (same-UID only — M1
///      cannot kill root/other-user pids), and
///   4. the owner uid is a real value (≥ 0; the helper sends -1 when it
///      couldn't read it, and we must not offer a kill on an unknown owner).
public enum MachineControlGate {

    /// Whether the "End Process" affordance should be offered for a process
    /// with `processUID`, given the settings toggle, the helper capability,
    /// and the current user's uid.
    public static func canOfferKill(
        machineControlsEnabled: Bool,
        capabilityKillProcess: Bool,
        processUID: Int,
        currentUID: Int
    ) -> Bool {
        guard machineControlsEnabled, capabilityKillProcess else { return false }
        guard processUID >= 0 else { return false }
        return processUID == currentUID
    }
}
