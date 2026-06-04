// UI layer for the Remote Control health engine (slice 2a).
//
// The engine ([RemoteControlHealth]) returns stable CheckIDs + statuses; this
// file binds them to localized strings and renders a compact diagnostics view
// shared by the macOS + iOS Settings screens. Kept separate from the engine so
// that layer stays pure. The `localizedTitle`/`localizedRemediation` mapping
// and the `supportText` export are plain Foundation (no SwiftUI) and unit-
// tested; the SwiftUI view compiles via `swift build` but its render is only
// verifiable on-device.

import Foundation
import UserNotifications

// MARK: - CheckID → localized strings (no SwiftUI)

public extension RemoteControlHealth.CheckID {
    /// Localized row title for this diagnostic.
    var localizedTitle: String {
        switch self {
        case .paired: return L10n.diagnostics.checkPaired
        case .remoteControl: return L10n.diagnostics.checkRemoteControl
        case .mac: return L10n.diagnostics.checkMac
        case .helper: return L10n.diagnostics.checkHelper
        case .notifications: return L10n.diagnostics.checkNotifications
        case .realtime: return L10n.diagnostics.checkRealtime
        }
    }

    /// Localized "here's how to fix it" line, shown for warn/fail rows.
    var localizedRemediation: String {
        switch self {
        case .paired: return L10n.diagnostics.fixPaired
        case .remoteControl: return L10n.diagnostics.fixRemoteControl
        case .mac: return L10n.diagnostics.fixMac
        case .helper: return L10n.diagnostics.fixHelper
        case .notifications: return L10n.diagnostics.fixNotifications
        case .realtime: return L10n.diagnostics.fixRealtime
        }
    }
}

// MARK: - Support export (locale-independent)

public extension RemoteControlHealth.Report {
    /// Stable plain-text summary for the "copy for support" action. Uses the
    /// raw check ids + statuses (NOT localized) so pasted support logs read the
    /// same regardless of the user's language.
    func supportText() -> String {
        var lines = ["CLI Pulse — Remote Control diagnostics", "overall: \(overall.rawValue)"]
        for check in checks {
            let detail = check.detail.map { " (\($0))" } ?? ""
            lines.append("- \(check.id.rawValue): \(check.status.rawValue)\(detail)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Inputs builders (plumbing for the Settings hosts)

public extension RemoteControlHealth.Inputs {
    /// Build inputs from live app state. The mac/helper checks use the
    /// most-recently-synced Mac among `devices` as the representative device.
    static func from(
        isPaired: Bool,
        remoteControlEnabled: Bool,
        devices: [DeviceRecord],
        notificationsAuthorized: Bool?,
        realtimeConnected: Bool? = nil,
        now: Date = Date()
    ) -> RemoteControlHealth.Inputs {
        let macs = devices.filter { $0.type.caseInsensitiveCompare("Mac") == .orderedSame }
        let target = macs.max {
            (sharedISO8601Parse($0.last_sync_at ?? "") ?? .distantPast)
                < (sharedISO8601Parse($1.last_sync_at ?? "") ?? .distantPast)
        }
        return RemoteControlHealth.Inputs(
            isPaired: isPaired,
            remoteControlEnabled: remoteControlEnabled,
            hasMac: target != nil,
            macLastSyncAt: target.flatMap { sharedISO8601Parse($0.last_sync_at ?? "") },
            helperVersion: target?.helper_version,
            notificationsAuthorized: notificationsAuthorized,
            realtimeConnected: realtimeConnected,
            now: now
        )
    }
}

public extension RemoteControlHealth {
    /// Current notification authorization for the `notifications` check
    /// (true = authorized). Called from the Settings host's `.task`.
    static func currentNotificationAuthorization() async -> Bool? {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool?, Never>) in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                cont.resume(returning: settings.authorizationStatus == .authorized)
            }
        }
    }
}

#if canImport(SwiftUI)
import SwiftUI

public extension RemoteControlHealth.Status {
    /// SF Symbol for the status icon.
    var iconName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        case .notApplicable: return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .ok: return .green
        case .warn: return .orange
        case .fail: return .red
        case .notApplicable: return .gray
        }
    }
}

/// Compact diagnostics list: an overall header + one row per applicable check
/// (notApplicable rows are hidden — they only mean a precondition above isn't
/// met yet). Warn/fail rows show their remediation. Pure presentation over a
/// [RemoteControlHealth.Report]; the host owns fetching inputs + the copy action.
public struct RemoteControlHealthView: View {
    private let report: RemoteControlHealth.Report

    public init(report: RemoteControlHealth.Report) {
        self.report = report
    }

    private var visibleChecks: [RemoteControlHealth.Check] {
        report.checks.filter { $0.status != .notApplicable }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: report.overall.iconName)
                    .foregroundStyle(report.overall.tint)
                Text(report.overall == .ok
                     ? L10n.diagnostics.overallOk
                     : L10n.diagnostics.overallAttention)
                    .font(.system(size: 13, weight: .semibold))
            }

            ForEach(visibleChecks, id: \.id) { check in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: check.status.iconName)
                        .foregroundStyle(check.status.tint)
                        .font(.system(size: 12))
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(check.id.localizedTitle)
                                .font(.system(size: 12, weight: .medium))
                            if let detail = check.detail, check.status == .ok {
                                Text(detail)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if check.status == .warn || check.status == .fail {
                            Text(check.id.localizedRemediation)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
#endif
