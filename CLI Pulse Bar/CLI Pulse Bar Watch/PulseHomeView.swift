import SwiftUI
import CLIPulseCore

/// Pulse home — the glance-first landing page of the redesign. Replaces
/// the standalone Overview list: the signature ECG waveform, a hero today
/// number, a row of stat chips that jump to the other pages, and the
/// Overview's unique data (server status, requests, top projects, risk
/// signals) folded in below as crown-scroll sections.
///
/// Presentation-only — reads `state.*`, never mutates the data layer.
/// Owns a single `ScrollView` so the Crown scrolls content and the page
/// only paginates at the scroll edge (review R1).
struct PulseHomeView: View {
    @EnvironmentObject var state: WatchAppState
    @Binding var selectedTab: WatchTab

    private var activity: Double {
        WatchPulseFormat.activityLevel(activeSessions: state.dashboard?.active_sessions ?? 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                header
                PulseWaveform(activityLevel: activity)

                if let dash = state.dashboard {
                    hero(dash)
                    chips(dash)
                    folded(dash)
                    if let last = state.lastRefresh {
                        HStack(spacing: 4) {
                            Image(systemName: "clock").font(.system(size: 9))
                            Text(last, style: .relative)
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 2)
                    }
                } else if state.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if let err = state.lastError {
                    errorState(err)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 2)
        }
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await state.refreshAll() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PulseTheme.accent)
            Text(L10n.auth.title)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Circle()
                .fill(state.serverOnline ? Color.green : Color.red)
                .frame(width: 7, height: 7)
                .accessibilityLabel(state.serverOnline ? L10n.dashboard.serverOnline : L10n.dashboard.serverOffline)
        }
    }

    // MARK: - Hero

    @ViewBuilder
    private func hero(_ dash: DashboardSummary) -> some View {
        Button {
            state.showCost.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if state.showCost {
                    BigMetric(
                        full: CostFormatter.format(dash.total_estimated_cost_today),
                        abbreviated: WatchPulseFormat.abbreviatedCost(dash.total_estimated_cost_today),
                        color: .green
                    )
                    Text(L10n.watch.todayTokens(CostFormatter.formatUsage(dash.total_usage_today)))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    let usage = CostFormatter.formatUsage(dash.total_usage_today)
                    BigMetric(full: usage, abbreviated: usage)
                    Text(L10n.dashboard.today)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.watch.toggleCostHint)
    }

    // MARK: - Stat chips

    private func chips(_ dash: DashboardSummary) -> some View {
        HStack(spacing: 6) {
            StatChip(
                icon: "terminal",
                value: "\(dash.active_sessions)",
                tint: .blue,
                accessibilityText: L10n.watch.sessionsCount(dash.active_sessions),
                action: { selectedTab = .live }
            )
            StatChip(
                icon: "desktopcomputer",
                value: "\(dash.online_devices)",
                tint: .cyan,
                accessibilityText: L10n.watch.devicesCount(dash.online_devices)
            )
            if dash.unresolved_alerts > 0 {
                StatChip(
                    icon: "bell.badge",
                    value: "\(dash.unresolved_alerts)",
                    tint: .red,
                    emphasized: true,
                    accessibilityText: L10n.watch.alertsCount(dash.unresolved_alerts),
                    action: { selectedTab = .alerts }
                )
            }
        }
    }

    // MARK: - Folded Overview data (crown-scroll)

    @ViewBuilder
    private func folded(_ dash: DashboardSummary) -> some View {
        // Requests.
        WatchCard {
            WatchMetricRow(
                label: L10n.dashboard.requests,
                value: "\(dash.total_requests_today)",
                icon: "arrow.up.arrow.down"
            )
        }

        if !dash.top_projects.isEmpty {
            WatchCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: L10n.dashboard.topProjects, icon: "folder")
                    ForEach(Array(dash.top_projects.prefix(3))) { proj in
                        HStack(spacing: 6) {
                            Text(proj.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(CostFormatter.formatUsage(proj.usage))
                                .font(.caption.weight(.semibold).monospacedDigit())
                        }
                    }
                }
            }
        }

        if !dash.risk_signals.isEmpty {
            WatchCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: L10n.dashboard.riskSignals, icon: "exclamationmark.triangle.fill")
                    ForEach(dash.risk_signals, id: \.self) { signal in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                            Text(signal)
                                .font(.caption2)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    // MARK: - States

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(L10n.watch.couldntLoadData)
                .font(.caption.weight(.semibold))
            Text(err)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button {
                Task { await state.refreshAll() }
            } label: {
                Label(L10n.watch.retry, systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(L10n.watch.pullToRefresh)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
