import SwiftUI
import CLIPulseCore

struct OverviewTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.dashboard.title)
                            .font(.system(size: 14, weight: .bold))
                        if let lastRefresh = state.lastRefresh {
                            Text(L10n.dashboard.updated(RelativeTime.format(ISO8601DateFormatter().string(from: lastRefresh))))
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    exportMenu
                    serverStatus
                    refreshButton
                }

                // iter18 (2026-04-29): when the user is in unauthenticated
                // local mode, show the LocalModeGuideCard at the TOP of
                // the Overview content — regardless of whether
                // collector data has populated `dashboard` yet. iter17
                // had only an empty-state replacement, so once data
                // started flowing the guide disappeared and the user
                // had no reminder they were in local-only mode (or that
                // they could sign in to sync to iPhone). The card is
                // compact (~80–100pt) and slots above the metrics grid
                // without crowding it.
                if state.isLocalMode && !state.isAuthenticated {
                    LocalModeGuideCard()
                        .environmentObject(state)
                }

                // Metric Grid
                if let dash = state.dashboard {
                    metricsGrid(dash)

                    // Activity timeline sparkline
                    if !dash.trend.isEmpty {
                        activityTimeline(dash.trend)
                    }

                    // Cost summary
                    if state.showCost {
                        costSection

                        // Cost forecast
                        if let forecast = state.costForecast {
                            forecastCard(forecast)
                        }

                        // Yield score (cost-to-code)
                        YieldScoreCard()
                    }

                    providerBreakdown(dash)
                    topProjects(dash)
                    riskSignals(dash)
                } else if state.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 30)
                } else if state.isLocalMode && !state.isAuthenticated {
                    // iter18: the LocalModeGuideCard above already
                    // explains "what now" via its three actionable
                    // bullets, so no separate empty-state card is
                    // needed for the local-mode no-data case. Show a
                    // minimal "waiting…" placeholder so the screen
                    // doesn't feel completely blank below the guide.
                    Text(L10n.dashboard.noData)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 20)
                } else {
                    EmptyStateView(
                        icon: "chart.bar.xaxis",
                        title: L10n.dashboard.noData,
                        subtitle: L10n.dashboard.connectHelper
                    )
                }
            }
            .padding(12)
        }
    }

    // MARK: - Server Status

    private var serverStatus: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.serverOnline ? .green : .red)
                .frame(width: 6, height: 6)
            Text(state.serverOnline ? L10n.common.online : L10n.common.offline)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
    }

    private var exportMenu: some View {
        Menu {
            Button {
                if let url = ExportService.exportCostReportCSV(
                    dashboard: state.dashboard,
                    providers: providerState.providers,
                    sessions: state.sessions
                ) {
                    #if os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    #endif
                }
            } label: {
                Label("Export Cost Report", systemImage: "doc.text")
            }
            Button {
                if let url = ExportService.exportSessionsCSV(sessions: state.sessions) {
                    #if os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    #endif
                }
            } label: {
                Label("Export Sessions", systemImage: "list.bullet")
            }
            Button {
                if let url = ExportService.exportProviderSummaryCSV(providers: providerState.providers) {
                    #if os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    #endif
                }
            } label: {
                Label("Export Providers", systemImage: "chart.bar")
            }

            Divider()

            #if canImport(PDFKit) && !os(watchOS)
            Button {
                if let url = ExportService.exportPDFReport(
                    dashboard: state.dashboard,
                    providers: providerState.providers,
                    sessions: state.sessions,
                    dailyUsage: state.dailyUsage,
                    costForecast: state.costForecast
                ) {
                    #if os(macOS)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    #endif
                }
            } label: {
                Label("Export PDF Report", systemImage: "doc.richtext")
            }
            #endif
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 10))
        }
        .accessibilityLabel("Export")
        .menuStyle(.borderlessButton)
    }

    private var refreshButton: some View {
        Button {
            state.requestRefresh()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
        }
        .accessibilityLabel(L10n.common.refresh)
        .buttonStyle(.plain)
        .disabled(state.isLoading)
    }

    // MARK: - Metrics Grid

    private func metricsGrid(_ dash: DashboardSummary) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
        ], spacing: 6) {
            MetricCard(
                title: L10n.dashboard.usageToday,
                value: CostFormatter.formatUsage(dash.total_usage_today),
                icon: "chart.bar.fill",
                color: PulseTheme.accent
            )
            MetricCard(
                title: L10n.dashboard.estCost,
                value: CostFormatter.format(dash.total_estimated_cost_today),
                subtitle: dash.cost_status,
                icon: "dollarsign.circle",
                color: .green
            )
            MetricCard(
                title: L10n.dashboard.requests,
                value: "\(dash.total_requests_today)",
                icon: "arrow.up.arrow.down",
                color: .purple
            )
            MetricCard(
                title: L10n.tab.sessions,
                value: "\(dash.active_sessions)",
                icon: "terminal",
                color: .cyan
            )
            MetricCard(
                title: L10n.dashboard.onlineDevices,
                value: "\(dash.online_devices)",
                icon: "desktopcomputer",
                color: .blue
            )
            MetricCard(
                title: L10n.dashboard.unresolvedAlerts,
                value: "\(dash.unresolved_alerts)",
                icon: "bell.badge",
                color: dash.unresolved_alerts > 0 ? .orange : .gray
            )
        }
    }

    // MARK: - Cost Section

    private var costSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: L10n.dashboard.costSummary, icon: "dollarsign.circle")
                Spacer()
                Text(providerState.costSummary.isPrecise ? "Exact" : "Estimated")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(providerState.costSummary.isPrecise ? .green : .orange)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background((providerState.costSummary.isPrecise ? Color.green : Color.orange).opacity(0.15))
                    .clipShape(Capsule())
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.dashboard.today)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(CostFormatter.format(providerState.costSummary.todayTotal))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        if providerState.costSummary.todayTokens > 0 {
                            Text("· \(TokenFormatter.format(providerState.costSummary.todayTokens)) tokens")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(providerState.costSummary.isPrecise ? "30 Day" : L10n.dashboard.thirtyDayEst)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(CostFormatter.format(providerState.costSummary.thirtyDayTotal))
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.green)
                        if providerState.costSummary.thirtyDayTokens > 0 {
                            Text("· \(TokenFormatter.format(providerState.costSummary.thirtyDayTokens)) tokens")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                Spacer()
            }

            // Per-provider breakdown (use 30-day data for richer view when precise)
            let breakdownData = providerState.costSummary.isPrecise
                ? providerState.costSummary.thirtyDayByProvider
                : providerState.costSummary.todayByProvider
            if !breakdownData.isEmpty {
                ForEach(Array(breakdownData.sorted(by: { $0.cost > $1.cost }).prefix(5)), id: \.provider) { item in
                    HStack {
                        Circle()
                            .fill(PulseTheme.providerColor(item.provider))
                            .frame(width: 6, height: 6)
                        Text(item.provider)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        if let sub = providerState.costSummary.subscriptionByProvider.first(where: { $0.provider == item.provider }) {
                            Text(sub.plan)
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 3)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        Spacer()
                        Text(CostFormatter.format(item.cost))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
            }

            // Subscriptions section
            if !providerState.costSummary.subscriptionByProvider.isEmpty {
                Divider().padding(.vertical, 2)

                HStack {
                    Image(systemName: "creditcard")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("Subscriptions")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(CostFormatter.format(providerState.costSummary.subscriptionTotal) + "/mo")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }

                ForEach(providerState.costSummary.subscriptionByProvider, id: \.provider) { item in
                    HStack {
                        Text("\(item.provider) \(item.plan)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Text(CostFormatter.format(item.monthlyCost))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                }

                // Subscription Utilization (API equivalent cost vs subscription price)
                if !providerState.costSummary.utilization.isEmpty {
                    Divider().padding(.vertical, 2)

                    HStack {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text("Subscription Utilization")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }

                    ForEach(providerState.costSummary.utilization, id: \.provider) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("\(item.provider) \(item.plan)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(CostFormatter.format(item.apiEquivCost) + " / " + CostFormatter.format(item.subscriptionCost))
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            GeometryReader { geo in
                                let fraction = min(item.utilizationPercent / 100.0, 1.0)
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(height: 4)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(utilizationColor(item.utilizationPercent))
                                        .frame(width: geo.size.width * CGFloat(fraction), height: 4)
                                }
                            }
                            .frame(height: 4)
                            HStack {
                                Text(String(format: "%.0f%% utilized", item.utilizationPercent))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                if !item.valueMultiplier.isEmpty {
                                    Text("· \(item.valueMultiplier) value")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(utilizationColor(item.utilizationPercent))
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Divider().padding(.vertical, 2)

                HStack {
                    Text("Total Monthly")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("~" + CostFormatter.format(providerState.costSummary.grandTotal))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                }
            }

            // Model-level cost breakdown with bar chart
            if !providerState.costSummary.costByModel.isEmpty {
                DisclosureGroup("By Model") {
                    let sorted = providerState.costSummary.costByModel.sorted { $0.cost > $1.cost }
                    let maxCost = sorted.first?.cost ?? 1
                    ForEach(sorted.prefix(10)) { item in
                        VStack(spacing: 2) {
                            HStack {
                                Text(item.model)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                Text("\(TokenFormatter.format(item.totalTokens)) tokens")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(CostFormatter.format(item.cost))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.green)
                                    .frame(width: 55, alignment: .trailing)
                            }
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Color.green.opacity(0.3))
                                    .frame(width: maxCost > 0 ? geo.size.width * CGFloat(item.cost / maxCost) : 0, height: 3)
                            }
                            .frame(height: 3)
                        }
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func utilizationColor(_ percent: Double) -> Color {
        OverviewFormatters.utilizationColor(percent)
    }

    // MARK: - Provider Breakdown

    // MARK: - Cost Forecast

    private func forecastCard(_ forecast: CostForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionHeader(title: L10n.forecast.title, icon: "chart.line.uptrend.xyaxis")
                Spacer()
                Text(L10n.forecast.estimate)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.forecast.monthEnd)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(CostFormatter.format(forecast.predictedMonthTotal))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.blue)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.forecast.soFar)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text(CostFormatter.format(forecast.actualToDate))
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                }
                Spacer()
            }

            // Confidence range
            if forecast.isReliable {
                HStack(spacing: 4) {
                    Text(L10n.forecast.confidence)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(CostFormatter.format(forecast.lowerBound)) – \(CostFormatter.format(forecast.upperBound))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(L10n.forecast.insufficientData)
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }

            // Progress bar: days elapsed
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.blue.opacity(0.1))
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(forecast.currentDayOfMonth) / CGFloat(forecast.daysInMonth), height: 4)
                }
            }
            .frame(height: 4)

            Text("\(forecast.currentDayOfMonth)/\(forecast.daysInMonth) days")
                .font(.system(size: 8))
                .foregroundStyle(.quaternary)
        }
        .padding(10)
        .background(.background.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func providerBreakdown(_ dash: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.dashboard.providerUsage, icon: "cpu")

            // v1.10.7: shared ranking + cost-scaled bars (see iOS counterpart).
            let enabledProviders = OverviewFormatters.rankedProviderBreakdown(
                dash.provider_breakdown,
                enabledNames: providerState.enabledProviderNames)

            ForEach(enabledProviders) { provider in
                let fraction = OverviewFormatters.providerUsageBarFraction(
                    provider, in: enabledProviders)

                UsageBar(
                    label: provider.provider,
                    value: fraction,
                    color: PulseTheme.providerColor(provider.provider),
                    detail: "\(CostFormatter.formatUsage(provider.usage)) · \(CostFormatter.format(provider.estimated_cost))"
                )
            }

            if enabledProviders.isEmpty {
                Text("No enabled providers with data")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Top Projects

    private func topProjects(_ dash: DashboardSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.dashboard.topProjects, icon: "folder")
            TopProjectsList(
                projects: dash.top_projects,
                emptyText: L10n.dashboard.noProjects,
                style: .macOS
            )
        }
        .padding(10)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Activity Timeline

    private func activityTimeline(_ trend: [UsagePoint]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.dashboard.activity, icon: "chart.bar.fill")
            ActivityTimelineChart(trend: trend, style: .macOS)
        }
        .padding(10)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Risk Signals

    @ViewBuilder
    private func riskSignals(_ dash: DashboardSummary) -> some View {
        if !dash.risk_signals.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: L10n.dashboard.riskSignals, icon: "exclamationmark.shield")
                RiskSignalsList(signals: dash.risk_signals, style: .macOS)
            }
            .padding(10)
            .background(Color.orange.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}
