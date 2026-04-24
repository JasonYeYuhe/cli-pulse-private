import SwiftUI
import CLIPulseCore

struct iOSOverviewTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isIPad: Bool { horizontalSizeClass == .regular }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Server status
                    HStack {
                        Circle()
                            .fill(state.serverOnline ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.serverOnline ? L10n.dashboard.serverOnline : L10n.dashboard.serverOffline)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let lastRefresh = state.lastRefresh {
                            Text(L10n.dashboard.updated(RelativeTime.format(ISO8601DateFormatter().string(from: lastRefresh))))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal)

                    if let dash = state.dashboard {
                        metricsGrid(dash)

                        // Activity timeline sparkline
                        if !dash.trend.isEmpty {
                            activityTimeline(dash.trend)
                        }

                        if state.showCost {
                            costSection
                        }

                        providerBreakdown(dash)
                        topProjects(dash)
                        riskSignals(dash)
                    } else if state.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 60)
                    } else {
                        iOSSyncOnboardingCard()
                            .environmentObject(state)
                            .padding(.horizontal)
                            .padding(.vertical, 20)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(L10n.dashboard.title)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        state.requestRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(state.isLoading)
                    .accessibilityLabel(L10n.common.refresh)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        if let url = ExportService.exportCostReportCSV(
                            dashboard: state.dashboard, providers: providerState.providers, sessions: state.sessions
                        ) {
                            ShareLink(item: url) { Label("Export Cost Report", systemImage: "doc.text") }
                        }
                        if let url = ExportService.exportSessionsCSV(sessions: state.sessions) {
                            ShareLink(item: url) { Label("Export Sessions", systemImage: "list.bullet") }
                        }
                        if let url = ExportService.exportProviderSummaryCSV(providers: providerState.providers) {
                            ShareLink(item: url) { Label("Export Providers", systemImage: "chart.bar") }
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .refreshable {
                await state.refreshAll()
            }
        }
    }

    // MARK: - Metrics Grid

    private func metricsGrid(_ dash: DashboardSummary) -> some View {
        let columns = isIPad ? [
            GridItem(.adaptive(minimum: 180), spacing: 10),
        ] : [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10),
        ]

        return LazyVGrid(columns: columns, spacing: 10) {
            iOSMetricCard(title: L10n.dashboard.usageToday, value: CostFormatter.formatUsage(dash.total_usage_today), icon: "chart.bar.fill", color: PulseTheme.accent)
            iOSMetricCard(title: L10n.dashboard.estCost, value: CostFormatter.format(dash.total_estimated_cost_today), icon: "dollarsign.circle", color: .green, badge: dash.cost_status)
            iOSMetricCard(title: L10n.dashboard.requests, value: "\(dash.total_requests_today)", icon: "arrow.up.arrow.down", color: .purple)
            iOSMetricCard(title: L10n.tab.sessions, value: "\(dash.active_sessions)", icon: "terminal", color: .cyan)
            iOSMetricCard(title: L10n.dashboard.onlineDevices, value: "\(dash.online_devices)", icon: "desktopcomputer", color: .blue)
            iOSMetricCard(title: L10n.tab.alerts, value: "\(dash.unresolved_alerts)", icon: "bell.badge", color: dash.unresolved_alerts > 0 ? .orange : .gray)
        }
        .padding(.horizontal)
    }

    // MARK: - Cost Section

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "dollarsign.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                Text(L10n.dashboard.costSummary)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(providerState.costSummary.isPrecise ? "Exact" : "Estimated")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(providerState.costSummary.isPrecise ? .green : .orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((providerState.costSummary.isPrecise ? Color.green : Color.orange).opacity(0.15))
                    .clipShape(Capsule())
            }

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.dashboard.today)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(CostFormatter.format(providerState.costSummary.todayTotal))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.green)
                        if providerState.costSummary.todayTokens > 0 {
                            Text("· \(TokenFormatter.format(providerState.costSummary.todayTokens))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerState.costSummary.isPrecise ? "30 Day" : L10n.dashboard.thirtyDayEst)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(CostFormatter.format(providerState.costSummary.thirtyDayTotal))
                            .font(.title3.weight(.bold).monospacedDigit())
                            .foregroundStyle(.green)
                        if providerState.costSummary.thirtyDayTokens > 0 {
                            Text("· \(TokenFormatter.format(providerState.costSummary.thirtyDayTokens))")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }

            // Per-provider breakdown — always use 30-day to match the header.
            // v1.10.6: prior code fell back to `todayByProvider` when not precise,
            // which rendered all-zero rows under the "30 Day Est." label because
            // the server didn't emit per-provider today cost. The new
            // `provider_summary` RPC returns a real 30-day sum, so clients
            // without a local scan can show consistent numbers here.
            let breakdownData = providerState.costSummary.thirtyDayByProvider
            ForEach(Array(breakdownData.sorted(by: { $0.cost > $1.cost }).prefix(5)), id: \.provider) { item in
                HStack {
                    Circle()
                        .fill(PulseTheme.providerColor(item.provider))
                        .frame(width: 8, height: 8)
                    Text(item.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let sub = providerState.costSummary.subscriptionByProvider.first(where: { $0.provider == item.provider }) {
                        Text(sub.plan)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    Spacer()
                    Text(CostFormatter.format(item.cost))
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.green)
                }
            }

            // Subscriptions
            if !providerState.costSummary.subscriptionByProvider.isEmpty {
                Divider()
                HStack {
                    Image(systemName: "creditcard")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Subscriptions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(CostFormatter.format(providerState.costSummary.subscriptionTotal) + "/mo")
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.orange)
                }

                ForEach(providerState.costSummary.subscriptionByProvider, id: \.provider) { item in
                    HStack {
                        Text("\(item.provider) \(item.plan)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(CostFormatter.format(item.monthlyCost))
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }

            // Subscription Utilization
            if !providerState.costSummary.utilization.isEmpty {
                Divider()
                HStack {
                    Image(systemName: "chart.bar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Subscription Utilization")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ForEach(providerState.costSummary.utilization.prefix(2), id: \.provider) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(item.provider) \(item.plan)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(CostFormatter.format(item.apiEquivCost) + " / " + CostFormatter.format(item.subscriptionCost))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        GeometryReader { geo in
                            let fraction = min(item.utilizationPercent / 100.0, 1.0)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.gray.opacity(0.2))
                                    .frame(height: 6)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(iOSUtilizationColor(item.utilizationPercent))
                                    .frame(width: geo.size.width * CGFloat(fraction), height: 6)
                            }
                        }
                        .frame(height: 6)
                        HStack {
                            Text(String(format: "%.0f%% utilized", item.utilizationPercent))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            if !item.valueMultiplier.isEmpty {
                                Text("· \(item.valueMultiplier) value")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(iOSUtilizationColor(item.utilizationPercent))
                            }
                            Spacer()
                        }
                    }
                }
            }

            // Grand total
            if !providerState.costSummary.subscriptionByProvider.isEmpty {
                Divider()
                HStack {
                    Text("Total Monthly")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("~" + CostFormatter.format(providerState.costSummary.grandTotal))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(.primary)
                }
            }
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private func iOSUtilizationColor(_ percent: Double) -> Color {
        OverviewFormatters.utilizationColor(percent)
    }

    // MARK: - Provider Breakdown

    private func providerBreakdown(_ dash: DashboardSummary) -> some View {
        let enabledProviders = dash.provider_breakdown.filter { p in
            providerState.enabledProviderNames.contains(p.provider)
        }

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PulseTheme.accent)
                Text(L10n.dashboard.providerUsage)
                    .font(.subheadline.weight(.semibold))
            }

            ForEach(enabledProviders) { provider in
                let maxUsage = enabledProviders.map(\.usage).max() ?? 1
                let fraction = maxUsage > 0 ? Double(provider.usage) / Double(maxUsage) : 0

                UsageBar(
                    label: provider.provider,
                    value: fraction,
                    color: PulseTheme.providerColor(provider.provider),
                    detail: "\(CostFormatter.formatUsage(provider.usage)) \u{00B7} \(CostFormatter.format(provider.estimated_cost))"
                )
            }
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Top Projects

    private func topProjects(_ dash: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PulseTheme.accent)
                Text(L10n.dashboard.topProjects)
                    .font(.subheadline.weight(.semibold))
            }
            TopProjectsList(
                projects: dash.top_projects,
                emptyText: L10n.dashboard.noProjects,
                style: .iOS
            )
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    // MARK: - Risk Signals

    @ViewBuilder
    private func riskSignals(_ dash: DashboardSummary) -> some View {
        if !dash.risk_signals.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(L10n.dashboard.riskSignals)
                        .font(.subheadline.weight(.semibold))
                }
                RiskSignalsList(signals: dash.risk_signals, style: .iOS)
            }
            .padding()
            .background(Color.orange.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)
        }
    }

    // MARK: - Activity Timeline

    private func activityTimeline(_ trend: [UsagePoint]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "chart.bar.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PulseTheme.accent)
                Text(L10n.dashboard.activity)
                    .font(.subheadline.weight(.semibold))
            }
            ActivityTimelineChart(trend: trend, style: .iOS)
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}

// MARK: - Sync Onboarding Card

struct iOSSyncOnboardingCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "cloud")
                    .font(.title2)
                    .foregroundStyle(PulseTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.onboarding.iosWaiting)
                        .font(.headline)
                    Text(L10n.onboarding.iosWaitingDesc)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // How it works explanation
            Text(L10n.onboarding.howItWorks)
                .font(.subheadline.weight(.semibold))

            Text(L10n.onboarding.cloudSyncDesc)
                .font(.caption)
                .foregroundStyle(.secondary)

            // Steps
            VStack(alignment: .leading, spacing: 10) {
                iOSSetupStepRow(number: 1, icon: "desktopcomputer", text: L10n.onboarding.step1Mac)
                iOSSetupStepRow(number: 2, icon: "terminal", text: L10n.onboarding.step2Helper)
                iOSSetupStepRow(number: 3, icon: "iphone", text: L10n.onboarding.step3Phone)
            }

            Text(L10n.onboarding.notBluetooth)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .italic()

            // Refresh button
            Button {
                state.requestRefresh()
            } label: {
                HStack {
                    if state.isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Image(systemName: "arrow.clockwise")
                    Text(L10n.onboarding.checkSync)
                        .font(.subheadline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(state.isLoading)
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(PulseTheme.accent.opacity(0.2), lineWidth: 1)
        )
    }
}

// MARK: - iOS Metric Card

struct iOSMetricCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                if let badge {
                    CostStatusBadge(status: badge)
                }
            }
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
