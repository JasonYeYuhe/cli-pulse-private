import Foundation

/// Phase 4E Slice 4: argv parsing for the `cli_pulse_helper daemon`
/// subcommand. Lifted out of `main.swift` so it has a unit-test
/// seam — the daemon body itself is procedural with launchd / GCD
/// signal sources and is exercised end-to-end via `daemon --help`
/// + the macOS app's HelperLifecycleManager.
public struct DaemonConfig: Equatable, Sendable {
    /// `--legacy-python` opt-out flag. When set, the Swift daemon
    /// exits cleanly with a diagnostic so the user can manually
    /// run the Python helper via `python3 helper/cli_pulse_helper.py
    /// daemon` instead. Cutover safety net for one release cycle.
    public var legacyPython: Bool

    /// `--interval N` — heartbeat / sync cadence in seconds. Kept
    /// for parity with the Python CLI; in v1.13 the LaunchAgent
    /// daemon does NOT drive heartbeat / sync (those live in the
    /// macOS app's HelperDaemon), so this value is informational.
    /// Floor is 60 s to match the Python helper.
    public var intervalSeconds: Int

    /// `--cloud-tick-seconds N` — cadence for `RemoteAgentCloud.tick()`.
    /// Default 1 s, floor 0.1 s.
    public var cloudTickSeconds: TimeInterval

    /// `--cloud-pull-max N` — max queued commands fetched per pull
    /// from `remote_helper_pull_commands`. Default 10, floor 1.
    public var cloudPullMax: Int

    public init(
        legacyPython: Bool = false,
        intervalSeconds: Int = 120,
        cloudTickSeconds: TimeInterval = 1.0,
        cloudPullMax: Int = 10
    ) {
        self.legacyPython = legacyPython
        self.intervalSeconds = max(60, intervalSeconds)
        self.cloudTickSeconds = max(0.1, cloudTickSeconds)
        self.cloudPullMax = max(1, cloudPullMax)
    }

    /// Parse `cli_pulse_helper daemon …` argv tail. Skips the
    /// subcommand itself — caller should pass everything AFTER the
    /// `daemon` token. Unknown flags are silently ignored to keep
    /// forward-compat for future flag additions.
    public static func parse(_ argv: [String]) -> DaemonConfig {
        var legacy = false
        var interval = 120
        var tick: TimeInterval = 1.0
        var pullMax = 10
        var i = 0
        while i < argv.count {
            let arg = argv[i]
            switch arg {
            case "--legacy-python":
                legacy = true
                i += 1
            case "--interval":
                if i + 1 < argv.count, let n = Int(argv[i + 1]) {
                    interval = n
                }
                i += 2
            case "--cloud-pull-max":
                if i + 1 < argv.count, let n = Int(argv[i + 1]) {
                    pullMax = n
                }
                i += 2
            case "--cloud-tick-seconds":
                if i + 1 < argv.count, let v = Double(argv[i + 1]) {
                    tick = v
                }
                i += 2
            default:
                i += 1
            }
        }
        return DaemonConfig(
            legacyPython: legacy,
            intervalSeconds: interval,
            cloudTickSeconds: tick,
            cloudPullMax: pullMax
        )
    }
}
