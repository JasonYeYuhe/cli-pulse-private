// Remote Control health / diagnostics engine.
//
// Remote control of a Mac is CLI Pulse's differentiator, and connection /
// activation problems ("why is my session blank?") are the top churn driver
// for remote-control apps. This pure engine evaluates the current pairing /
// remote-control / helper / connection state into an ordered list of
// pass/warn/fail checks, so a diagnostics panel can tell the user (and support)
// exactly what is wrong and what to do about it.
//
// The engine returns stable `CheckID`s + a `Status` only — the UI owns the
// localized titles and remediation text keyed by id, so this layer stays pure
// Foundation (shared macOS/iOS/watchOS) and fully unit-testable without UI/L10n.

import Foundation

public enum RemoteControlHealth {

    /// Stable identity for each diagnostic row. The UI maps these to localized
    /// title + remediation strings.
    public enum CheckID: String, Sendable, CaseIterable {
        case paired           // signed in + a Mac paired
        case remoteControl    // Remote Control toggle enabled
        case mac              // a Mac is connected and syncing
        case helper           // the CLI Pulse helper is installed on the Mac
        case notifications    // notifications allowed (for approval prompts)
        case realtime         // live realtime channel connected
    }

    public enum Status: String, Sendable {
        case ok
        case warn
        case fail
        case notApplicable    // precondition unmet — don't show as a problem

        /// Severity for the "overall = worst check" reduction. `notApplicable`
        /// is neutral (below `ok`) so it never drives the overall status.
        var severity: Int {
            switch self {
            case .notApplicable: return -1
            case .ok: return 0
            case .warn: return 1
            case .fail: return 2
            }
        }
    }

    public struct Check: Sendable, Equatable {
        public let id: CheckID
        public let status: Status
        /// Optional dynamic data for the UI (e.g. the detected helper version) —
        /// NOT a localized sentence.
        public let detail: String?

        public init(id: CheckID, status: Status, detail: String? = nil) {
            self.id = id
            self.status = status
            self.detail = detail
        }
    }

    public struct Report: Sendable, Equatable {
        public let checks: [Check]
        public let overall: Status

        public init(checks: [Check], overall: Status) {
            self.checks = checks
            self.overall = overall
        }

        /// The checks worth drawing attention to (warn/fail), in order.
        public var actionableChecks: [Check] {
            checks.filter { $0.status == .warn || $0.status == .fail }
        }
    }

    public struct Inputs: Sendable {
        public var isPaired: Bool
        public var remoteControlEnabled: Bool
        public var hasMac: Bool
        public var macLastSyncAt: Date?
        public var helperVersion: String?
        /// nil = unknown / not yet queried → reported as notApplicable.
        public var notificationsAuthorized: Bool?
        /// nil = not currently subscribing → notApplicable (not a failure).
        public var realtimeConnected: Bool?
        public var now: Date

        public init(
            isPaired: Bool,
            remoteControlEnabled: Bool,
            hasMac: Bool = false,
            macLastSyncAt: Date? = nil,
            helperVersion: String? = nil,
            notificationsAuthorized: Bool? = nil,
            realtimeConnected: Bool? = nil,
            now: Date = Date()
        ) {
            self.isPaired = isPaired
            self.remoteControlEnabled = remoteControlEnabled
            self.hasMac = hasMac
            self.macLastSyncAt = macLastSyncAt
            self.helperVersion = helperVersion
            self.notificationsAuthorized = notificationsAuthorized
            self.realtimeConnected = realtimeConnected
            self.now = now
        }
    }

    /// A Mac whose last sync is older than this is "stale" (warn).
    public static let macSyncStaleAfter: TimeInterval = 600 // 10 min

    public static func evaluate(_ input: Inputs) -> Report {
        var checks: [Check] = []

        // 1. Paired — the root precondition.
        checks.append(Check(id: .paired, status: input.isPaired ? .ok : .fail))

        // 2. Remote Control enabled — needs pairing first. Off is a warn, not a
        //    fail (it's the user's toggle, but it gates everything below).
        let rcStatus: Status = !input.isPaired
            ? .notApplicable
            : (input.remoteControlEnabled ? .ok : .warn)
        checks.append(Check(id: .remoteControl, status: rcStatus))

        let rcActive = input.isPaired && input.remoteControlEnabled

        // 3. Mac reachable — only meaningful once RC is active.
        let macCheck: Check
        if !rcActive {
            macCheck = Check(id: .mac, status: .notApplicable)
        } else if !input.hasMac {
            macCheck = Check(id: .mac, status: .fail)
        } else if let sync = input.macLastSyncAt,
                  input.now.timeIntervalSince(sync) > macSyncStaleAfter {
            macCheck = Check(id: .mac, status: .warn, detail: "stale")
        } else {
            macCheck = Check(id: .mac, status: .ok)
        }
        checks.append(macCheck)

        // 4. Helper installed on that Mac.
        let helperCheck: Check
        if !rcActive || !input.hasMac {
            helperCheck = Check(id: .helper, status: .notApplicable)
        } else if let v = input.helperVersion, !v.trimmingCharacters(in: .whitespaces).isEmpty {
            helperCheck = Check(id: .helper, status: .ok, detail: v)
        } else {
            helperCheck = Check(id: .helper, status: .warn)
        }
        checks.append(helperCheck)

        // 5. Notifications — independent of RC (drives approval prompts).
        let notifStatus: Status
        switch input.notificationsAuthorized {
        case .none: notifStatus = .notApplicable
        case .some(true): notifStatus = .ok
        case .some(false): notifStatus = .warn
        }
        checks.append(Check(id: .notifications, status: notifStatus))

        // 6. Realtime connection — only when RC is active and we're subscribing.
        let realtimeStatus: Status
        if !rcActive {
            realtimeStatus = .notApplicable
        } else {
            switch input.realtimeConnected {
            case .none: realtimeStatus = .notApplicable
            case .some(true): realtimeStatus = .ok
            case .some(false): realtimeStatus = .warn
            }
        }
        checks.append(Check(id: .realtime, status: realtimeStatus))

        return Report(checks: checks, overall: overallStatus(of: checks))
    }

    /// Overall = the worst non-`notApplicable` check (fail > warn > ok). All
    /// `notApplicable` (impossible in practice — `paired` is always ok/fail)
    /// degrades to `ok`.
    static func overallStatus(of checks: [Check]) -> Status {
        let worst = checks.map { $0.status.severity }.max() ?? -1
        switch worst {
        case 2: return .fail
        case 1: return .warn
        default: return .ok
        }
    }
}
