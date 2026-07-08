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

    private var visibleProviders: [ProviderUsage] {
        state.providers.filter { state.enabledProviderNames.contains($0.provider) }
    }

    /// The most-active provider (most tokens used today) — drives the
    /// home "main provider quota" teaser.
    private var mainProvider: ProviderUsage? {
        WatchRingMath.mostActive(visibleProviders)
    }

    private var weekCost: Double {
        WatchPulseFormat.weekToDateCost(visibleProviders)
    }

    var body: some View {
        ScrollView {
            // Lazy: this glance has grown long (waveform + hero + sparkline +
            // chips + quota teaser + several cards) — defer off-screen rows.
            LazyVStack(spacing: 10) {
                header
                PulseWaveform(activityLevel: activity)

                if let dash = state.dashboard {
                    hero(dash)
                    sparkline(dash)
                    chips(dash)
                    tightestQuota()
                    folded(dash)
                    recentActivity(dash)
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
                    WatchLoadingState()
                } else if let err = state.lastError {
                    WatchErrorState(title: L10n.watch.couldntLoadData, message: err) {
                        Task { await state.refreshAll() }
                    }
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 2)
        }
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
            // Redact the spend/usage figure under Always-On / lock
            // (system applies .privacy redaction to privacySensitive views).
            .privacySensitive()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.watch.toggleCostHint)
    }

    // MARK: - Usage trend sparkline

    @ViewBuilder
    private func sparkline(_ dash: DashboardSummary) -> some View {
        if dash.trend.count >= 2 {
            ActivityTimelineChart(trend: dash.trend, style: .watch, showLabels: false)
                .accessibilityHidden(true) // decorative; the hero states the number
        }
    }

    // MARK: - Tightest quota teaser (jumps to Quota)

    @ViewBuilder
    private func tightestQuota() -> some View {
        if let p = mainProvider {
            let color = WatchTheme.tierColor(
                WatchRingMath.tier(usagePercent: WatchRingMath.weeklyUsagePercent(p)),
                base: PulseTheme.providerColor(p.provider)
            )
            Button {
                selectedTab = .quota
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: L10n.providers.quota, icon: "gauge.with.needle")
                    HStack(spacing: 6) {
                        Circle()
                            .fill(PulseTheme.providerColor(p.provider))
                            .frame(width: 8, height: 8)
                        Text(p.provider)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L10n.watch.percentLeft(WatchRingMath.weeklyRemainingPercentInt(p)))
                            .font(WatchTheme.monoNumber(size: 12))
                            .foregroundStyle(color)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Recent activity

    @ViewBuilder
    private func recentActivity(_ dash: DashboardSummary) -> some View {
        if !dash.recent_activity.isEmpty {
            WatchCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: L10n.dashboard.activity, icon: "clock.arrow.circlepath")
                    ForEach(Array(dash.recent_activity.prefix(3))) { item in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title)
                                .font(.caption)
                                .lineLimit(1)
                            if !item.subtitle.isEmpty {
                                Text(item.subtitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
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
        // Requests + this-week cost.
        WatchCard {
            VStack(spacing: 6) {
                WatchMetricRow(
                    label: L10n.dashboard.requests,
                    value: "\(dash.total_requests_today)",
                    icon: "arrow.up.arrow.down"
                )
                if state.showCost {
                    WatchMetricRow(
                        label: L10n.providers.thisWeek,
                        value: CostFormatter.format(weekCost),
                        icon: "calendar",
                        valueColor: .green
                    )
                }
            }
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

        // v1.41 Mobile Machine: read-only per-device Machine cards, each drilling
        // into a detail List. No controls on the watch (by design).
        if !state.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: L10n.machine.deviceHealth, icon: "desktopcomputer")
                ForEach(state.devices) { d in
                    NavigationLink {
                        WatchMachineDetailView(device: d)
                    } label: {
                        WatchMachineCard(device: d)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - States

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
