import Foundation

/// Pure, server-side validation for the (future) privileged commands. The root
/// helper NEVER trusts the client: a fan target is clamped to the firmware's own
/// [min,max] and refused if the range is unknown; a root/other-user kill (M4)
/// still honours a deny-list of never-signal targets.
///
/// **None of this is reachable in M2** — there is no `setFan`/`killPid` command
/// yet. It lives here, fully unit-tested, so M3/M4 wire validated logic instead
/// of inventing it under time pressure. Mirrors the user-helper's
/// `machine_actions` deny-list so the two tiers stay consistent.
public enum CommandGuard {

    // ── M3 fan clamp ─────────────────────────────────────────────────────────

    public enum FanTargetError: Error, Equatable {
        case rangeUnavailable          // min/max couldn't be read → refuse (don't guess)
        case invalidRange              // max <= 0 or max < min → refuse
    }

    /// Clamp a requested RPM into the firmware's own [min,max]. Refuses (rather
    /// than guessing) if the range is missing or nonsensical — a fan target with
    /// no known floor is exactly how you cook a machine.
    public static func clampFanTarget(requestedRPM: Double,
                                      minRPM: Double?,
                                      maxRPM: Double?) -> Result<Double, FanTargetError> {
        guard let mn = minRPM, let mx = maxRPM else { return .failure(.rangeUnavailable) }
        guard mx > 0, mx >= mn else { return .failure(.invalidRange) }
        return .success(min(max(requestedRPM, mn), mx))
    }

    /// Valid fan mode values: 0 = Apple auto, 1 = manual. Anything else refused.
    public static func isValidFanMode(_ mode: Int) -> Bool { mode == 0 || mode == 1 }

    // ── M4 kill deny-list (root/other-user kill via the root helper) ──────────

    /// comm basenames the root helper must NEVER signal, even as root. Superset
    /// of the user-helper's list — critical system processes whose death would
    /// panic or lock out the machine. Matched case-insensitively on the basename.
    public static let protectedComm: Set<String> = [
        "kernel_task", "launchd", "windowserver", "loginwindow", "logind",
        "securityd", "opendirectoryd", "configd", "syslogd", "notifyd",
        "cli_pulse_helper", "cli pulse bar", "machine-root-helper",
    ]

    /// Whether a (pid, comm) is a legal M4 kill target. pid ≤ 1 and any protected
    /// comm are refused regardless of the caller. (Same-UID vs root/other-user is
    /// an M4 policy layer above this; this is the hard floor.)
    ///
    /// ⚠️ M4 SECURITY (security-review note): the root helper MUST resolve `comm`
    /// ITSELF from the pid at signal time (via `ps`/`proc_pidpath`), NEVER trust a
    /// client-supplied comm — otherwise a caller could pass pid=<launchd> with
    /// comm="python3" and defeat the deny-list. Same TOCTOU discipline as the
    /// user-helper's `machine_actions._ps_proc_info`.
    public static func isKillablePid(_ pid: Int, comm: String) -> Bool {
        guard pid > 1 else { return false }
        let base = (comm as NSString).lastPathComponent.lowercased()
        return !protectedComm.contains(base)
    }
}
