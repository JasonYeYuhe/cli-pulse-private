import SwiftUI
import CLIPulseCore

struct WatchOverviewView: View {
    @EnvironmentObject var state: WatchAppState

    var body: some View {
        List {
            if let dash = state.dashboard {
                // Server status
                Section {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.serverOnline ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.serverOnline ? L10n.dashboard.serverOnline : L10n.dashboard.serverOffline)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(state.serverOnline ? .green : .red)
                        Spacer()
                        if let last = state.lastRefresh {
                            Text(last, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }

                // Key metrics row
                Section(L10n.dashboard.today) {
                    HStack(spacing: 0) {
                        WatchCompactMetric(
                            icon: "chart.bar.fill",
                            value: CostFormatter.formatUsage(dash.total_usage_today),
                            label: L10n.widget.usageTitle,
                            color: PulseTheme.accent
                        )
                        Spacer()
                        WatchCompactMetric(
                            icon: "terminal",
                            value: "\(dash.active_sessions)",
                            label: L10n.tab.sessions,
                            color: .blue
                        )
                        Spacer()
                        WatchCompactMetric(
                            icon: "desktopcomputer",
                            value: "\(dash.online_devices)",
                            label: L10n.dashboard.onlineDevices,
                            color: .cyan
                        )
                    }

                    if state.showCost {
                        HStack {
                            Image(systemName: "dollarsign.circle")
                                .font(.caption2)
                                .foregroundStyle(.green)
                            Text(L10n.dashboard.costToday)
                                .font(.caption)
                            Spacer()
                            HStack(alignment: .firstTextBaseline, spacing: 2) {
                                Text(CostFormatter.format(dash.total_estimated_cost_today))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.green)
                                if state.costSummary.todayTokens > 0 {
                                    Text("· \(TokenFormatter.format(state.costSummary.todayTokens))")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    HStack {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(L10n.dashboard.requests)
                            .font(.caption)
                        Spacer()
                        Text("\(dash.total_requests_today)")
                            .font(.caption.weight(.bold).monospacedDigit())
                    }

                    if dash.unresolved_alerts > 0 {
                        HStack {
                            Image(systemName: "bell.badge")
                                .font(.caption2)
                                .foregroundStyle(.red)
                            Text(L10n.tab.alerts)
                                .font(.caption)
                            Spacer()
                            Text("\(dash.unresolved_alerts)")
                                .font(.caption.weight(.bold).monospacedDigit())
                                .foregroundStyle(.red)
                        }
                    }
                }

                // Provider gauges. Use state.providers (ProviderUsage) rather
                // than dash.provider_breakdown — ProviderBreakdown's `usage`
                // field mirrors `today_usage` which is 0 when the user hasn't
                // run anything today, producing a 0% gauge even when the
                // provider's window is 28% consumed. ProviderUsage carries
                // the full quota/remaining/today_usage triad so we can render
                // the window-consumption ring correctly.
                let topProviders = state.providers
                    .filter { state.enabledProviderNames.contains($0.provider) }
                    .prefix(4)

                if !topProviders.isEmpty {
                    Section(L10n.providers.quota) {
                        ForEach(Array(topProviders)) { p in
                            WatchProviderGauge(provider: p, showCost: state.showCost)
                        }
                    }
                }

                // Top projects
                if !dash.top_projects.isEmpty {
                    Section(L10n.dashboard.topProjects) {
                        ForEach(Array(dash.top_projects.prefix(3))) { proj in
                            HStack {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
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

                // Risk signals
                if !dash.risk_signals.isEmpty {
                    Section(L10n.dashboard.riskSignals) {
                        ForEach(dash.risk_signals, id: \.self) { signal in
                            HStack(spacing: 6) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                                Text(signal)
                                    .font(.caption2)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            } else if state.isLoading {
                ProgressView("Loading...")
            } else if let err = state.lastError {
                // Surface the actual failure instead of hiding behind a
                // generic "Pull to refresh" — historically a silent 401
                // here looked identical to a first-launch empty state.
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
            } else {
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
        .navigationTitle(L10n.tab.overview)
        .refreshable {
            await state.refreshAll()
        }
    }
}

// MARK: - Compact Metric

struct WatchCompactMetric: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(color)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Provider Gauge

struct WatchProviderGauge: View {
    let provider: ProviderUsage
    let showCost: Bool

    private var usagePercent: Double { provider.usagePercent }

    private var hasQuota: Bool { provider.quota != nil }

    private var windowUsed: Int {
        if let quota = provider.quota, let remaining = provider.remaining {
            return max(0, quota - remaining)
        }
        return provider.today_usage
    }

    private var gaugeColor: Color {
        PulseTheme.providerColor(provider.provider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: ProviderKind(rawValue: provider.provider)?.iconName ?? "cpu")
                    .font(.caption2)
                    .foregroundStyle(gaugeColor)
                    .frame(width: 14)
                Text(provider.provider)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                if showCost && provider.estimated_cost_today > 0 {
                    Text(CostFormatter.format(provider.estimated_cost_today))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.green)
                }
            }

            if hasQuota {
                Gauge(value: usagePercent) {
                    EmptyView()
                } currentValueLabel: {
                    Text("\(Int(usagePercent * 100))%")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                }
                .gaugeStyle(.linearCapacity)
                .tint(gaugeGradient)
            }

            HStack {
                Text(CostFormatter.formatUsage(windowUsed))
                    .font(.caption2.weight(.bold).monospacedDigit())
                if let quota = provider.quota {
                    Text("/ \(CostFormatter.formatUsage(quota))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var gaugeGradient: Gradient {
        if usagePercent > 0.9 {
            return Gradient(colors: [.red, .red])
        } else if usagePercent > 0.7 {
            return Gradient(colors: [gaugeColor, .orange])
        } else {
            return Gradient(colors: [gaugeColor, gaugeColor])
        }
    }
}

// MARK: - Metric Row

struct WatchMetricRow: View {
    let label: String
    let value: String
    let icon: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(valueColor)
        }
    }
}
