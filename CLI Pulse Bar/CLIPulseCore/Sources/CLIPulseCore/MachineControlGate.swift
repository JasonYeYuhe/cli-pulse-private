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
/// All four runtime conditions must hold to offer an action on a given row:
///   1. the owner opted in (`machineControlsEnabled` Settings toggle),
///   2. the helper reports it can do THIS action — `capability["kill_process"]`
///      for End Process, `capability["suspend_process"]` for Suspend/Resume.
///      Gating each affordance on its OWN capability (rather than reusing
///      kill_process for both) means a helper that advertises one but not the
///      other correctly shows only the supported control — and honours the
///      helper's design that "a key is absent on older helpers, so a new app
///      naturally hides the affordance",
///   3. the process is owned by the current user (same-UID only — we cannot
///      signal root/other-user pids without the future root helper), and
///   4. the owner uid is a real value (≥ 0; the helper sends -1 when it
///      couldn't read it, and we must not offer an action on an unknown owner).
public enum MachineControlGate {

    /// Shared core: opt-in + this-action capability + real same-UID owner.
    static func canOffer(
        machineControlsEnabled: Bool,
        capability: Bool,
        processUID: Int,
        currentUID: Int
    ) -> Bool {
        guard machineControlsEnabled, capability else { return false }
        guard processUID >= 0 else { return false }
        return processUID == currentUID
    }

    /// Whether the "End Process" affordance should be offered for a process
    /// with `processUID`, given the settings toggle, the helper's
    /// `kill_process` capability, and the current user's uid.
    public static func canOfferKill(
        machineControlsEnabled: Bool,
        capabilityKillProcess: Bool,
        processUID: Int,
        currentUID: Int
    ) -> Bool {
        canOffer(machineControlsEnabled: machineControlsEnabled,
                 capability: capabilityKillProcess,
                 processUID: processUID, currentUID: currentUID)
    }

    /// v1.38.1: whether the Suspend/Resume affordance should be offered, gated
    /// on the helper's DISTINCT `suspend_process` capability. An M1-era helper
    /// that advertises `kill_process` but not `suspend_process` (and has no
    /// `signal_process` verb) therefore shows End Process but NOT Suspend —
    /// instead of a Suspend button that would fail with `not_implemented`.
    public static func canOfferSuspend(
        machineControlsEnabled: Bool,
        capabilitySuspendProcess: Bool,
        processUID: Int,
        currentUID: Int
    ) -> Bool {
        canOffer(machineControlsEnabled: machineControlsEnabled,
                 capability: capabilitySuspendProcess,
                 processUID: processUID, currentUID: currentUID)
    }
}
