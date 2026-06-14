import SwiftUI
import CLIPulseCore
#if os(watchOS)
import WatchKit
#endif

/// Alerts page. Open alerts are severity-sorted cards (severity colour bar
/// + title + message + relative time); the most-severe Critical card is
/// tinted and carries a gated pulsing dot. Resolved alerts are dimmed
/// below. The critical-alert haptic, ack/resolve/snooze actions, and the
/// all-clear state are preserved.
///
/// Presentation-only — reads `state.*`, never mutates the data layer.
/// Owns one `ScrollView` (review R1).
struct WatchAlertsView: View {
    @EnvironmentObject var state: WatchAppState

    private var openAlerts: [AlertRecord] {
        WatchAlertSort.bySeverity(state.alerts.filter { !$0.is_resolved })
    }

    private var resolvedAlerts: [AlertRecord] {
        state.alerts.filter { $0.is_resolved }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                header

                if openAlerts.isEmpty && resolvedAlerts.isEmpty {
                    allClearState
                } else {
                    ForEach(openAlerts) { alert in
                        NavigationLink {
                            WatchAlertDetailView(alert: alert)
                                .environmentObject(state)
                        } label: {
                            AlertCard(alert: alert)
                        }
                        .buttonStyle(.plain)
                    }

                    if !resolvedAlerts.isEmpty {
                        Text(L10n.alerts.resolved)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                        ForEach(Array(resolvedAlerts.prefix(5))) { alert in
                            AlertCard(alert: alert)
                        }
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .refreshable { await state.refreshAll() }
        .task {
            triggerHapticForCritical()
        }
    }

    private var header: some View {
        HStack {
            Text(L10n.tab.alerts)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !openAlerts.isEmpty {
                Text("\(openAlerts.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.red))
            }
        }
    }

    private var allClearState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(L10n.alerts.allClear)
                .font(.caption.weight(.semibold))
            Text(L10n.alerts.noAlerts)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    private func triggerHapticForCritical() {
        let critical = openAlerts.filter { $0.alertSeverity == .critical }
        if !critical.isEmpty {
            #if os(watchOS)
            WKInterfaceDevice.current().play(.failure)
            #endif
        }
    }
}

// MARK: - Alert Card

struct AlertCard: View {
    let alert: AlertRecord

    private var severityColor: Color {
        PulseTheme.severityColor(alert.severity)
    }

    /// The single most-severe open alert gets the tinted + pulsing
    /// treatment. We only emphasize unresolved Criticals.
    private var isCritical: Bool {
        alert.alertSeverity == .critical && !alert.is_resolved
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(severityColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isCritical {
                        LiveDot(size: 6, color: severityColor)
                    } else if !alert.is_read && !alert.is_resolved {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                    }
                    Text(alert.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                }

                Text(alert.message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(alert.severity)
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(severityColor.opacity(0.2))
                        .foregroundStyle(severityColor)
                        .clipShape(Capsule())
                    if alert.is_resolved {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                    Text(RelativeTime.format(alert.created_at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(
            isCritical ? severityColor.opacity(0.12) : WatchTheme.cardFill,
            in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius)
        )
        .opacity(alert.is_resolved ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Alert Detail

struct WatchAlertDetailView: View {
    let alert: AlertRecord
    @EnvironmentObject var state: WatchAppState

    private var severityColor: Color {
        PulseTheme.severityColor(alert.severity)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(severityColor)
                            .frame(width: 3, height: 20)
                        Text(alert.severity)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(severityColor)
                    }
                    Text(alert.title)
                        .font(.caption.weight(.semibold))
                    Text(alert.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if alert.related_provider != nil || alert.related_project_name != nil || alert.related_device_name != nil {
                Section(L10n.alerts.related) {
                    if let provider = alert.related_provider {
                        HStack {
                            Image(systemName: "cpu")
                                .font(.caption2)
                            Text(provider)
                                .font(.caption)
                        }
                    }
                    if let project = alert.related_project_name {
                        HStack {
                            Image(systemName: "folder")
                                .font(.caption2)
                            Text(project)
                                .font(.caption)
                        }
                    }
                    if let device = alert.related_device_name {
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .font(.caption2)
                            Text(device)
                                .font(.caption)
                        }
                    }
                }
            }

            if !alert.is_resolved {
                Section(L10n.alerts.actions) {
                    if !alert.is_read {
                        Button {
                            Task { await state.acknowledgeAlert(alert) }
                        } label: {
                            HStack {
                                Image(systemName: "eye")
                                    .font(.caption)
                                Text(L10n.alerts.acknowledge)
                                    .font(.caption)
                            }
                        }
                        .foregroundStyle(.blue)
                    }

                    Button {
                        Task { await state.resolveAlert(alert) }
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                            Text(L10n.alerts.resolve)
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.green)

                    NavigationLink {
                        List {
                            Button(L10n.watch.snooze15) {
                                Task { await state.snoozeAlert(alert, minutes: 15) }
                            }
                            Button(L10n.watch.snooze30) {
                                Task { await state.snoozeAlert(alert, minutes: 30) }
                            }
                            Button(L10n.watch.snooze60) {
                                Task { await state.snoozeAlert(alert, minutes: 60) }
                            }
                        }
                        .navigationTitle(L10n.alerts.snooze)
                    } label: {
                        HStack {
                            Image(systemName: "moon.zzz")
                                .font(.caption)
                            Text(L10n.alerts.snooze)
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(.orange)
                }
            }

            Section {
                HStack {
                    Text(L10n.alerts.created)
                        .font(.caption)
                    Spacer()
                    Text(RelativeTime.format(alert.created_at))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(L10n.tab.alerts)
    }
}
