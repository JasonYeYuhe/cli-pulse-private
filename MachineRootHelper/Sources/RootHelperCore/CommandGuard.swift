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

    /// BOOST-ONLY clamp — the core safety rule for fan control on hardware whose
    /// firmware does NOT self-revert after a controller crash (M0 finding,
    /// 2026-07-07: `kill -9` left the fan stuck at the manual target). The manual
    /// target may only ever be >= the fan's CURRENT auto RPM, so a fan that gets
    /// stuck in manual is always at least as cool as Apple auto would be right now
    /// — stuck-HIGH (loud, safe), never stuck-LOW (under-cooled). Clamps into
    /// [max(autoFloorRPM, minRPM), maxRPM]; refuses if the range is unknown.
    ///
    /// Residual risk (documented; mitigated by the LAYERED dead-man's-switch, NOT
    /// by this clamp alone): if load rises AFTER a set and the daemon has died,
    /// the stuck target may be below the NEW auto demand. That window is bounded
    /// by heartbeat-revert + launchd relaunch-reverts-to-auto + TjMax throttle. A
    /// full-blast boost (target == maxRPM) has NO residual — it can never be under
    /// any future auto demand — and is the unconditionally-safe default.
    public static func clampBoostTarget(requestedRPM: Double,
                                        autoFloorRPM: Double?,
                                        minRPM: Double?,
                                        maxRPM: Double?) -> Result<Double, FanTargetError> {
        guard let mn = minRPM, let mx = maxRPM, let floor = autoFloorRPM else {
            return .failure(.rangeUnavailable)
        }
        guard mx > 0, mx >= mn, floor >= 0 else { return .failure(.invalidRange) }
        // Never below the current auto floor; the floor is itself clamped into the
        // hardware range so a bogus-high auto reading can't push us past max.
        let lowerBound = min(max(floor, mn), mx)
        return .success(min(max(requestedRPM, lowerBound), mx))
    }

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
