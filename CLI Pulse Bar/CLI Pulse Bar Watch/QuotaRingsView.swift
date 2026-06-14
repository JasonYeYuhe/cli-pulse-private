import SwiftUI
import CLIPulseCore

/// Quota page — Activity-ring-style concentric rings, one per most-
/// constrained provider, with a legend of every visible provider below.
/// Replaces the old `WatchProvidersView` card list; the per-provider
/// detail view lives here too (drill-down from a legend row).
///
/// Presentation-only — reads `state.*`, never mutates the data layer.
/// Owns one `ScrollView` so the Crown scrolls content (review R1).
struct QuotaRingsView: View {
    @EnvironmentObject var state: WatchAppState

    private var visibleProviders: [ProviderUsage] {
        state.providers.filter { state.enabledProviderNames.contains($0.provider) }
    }

    /// Concentric rings: metered providers, most-constrained first, capped
    /// at 3 for legibility (review note). Reuses the shared math so the
    /// rings can't diverge from the legend / complication.
    private var ringProviders: [ProviderUsage] {
        WatchRingMath.ringProviders(visibleProviders, limit: 3)
    }

    private var meteredCount: Int {
        visibleProviders.filter { $0.quota != nil }.count
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                header

                if visibleProviders.isEmpty {
                    if let err = state.lastError {
                        errorState(err)
                    } else {
                        emptyState
                    }
                } else {
                    if !ringProviders.isEmpty {
                        ProviderRingCluster(providers: ringProviders)
                            .frame(height: 142)
                            .padding(.vertical, 2)
                    }
                    legend
                }
            }
            .padding(.horizontal, 2)
        }
        .refreshable { await state.refreshAll() }
    }

    private var header: some View {
        HStack {
            Text(L10n.providers.quota)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if meteredCount > 0 {
                Text(L10n.watch.activeCount(meteredCount))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var legend: some View {
        VStack(spacing: 4) {
            ForEach(visibleProviders) { provider in
                NavigationLink {
                    WatchProviderDetailView(provider: provider, showCost: state.showCost)
                } label: {
                    QuotaLegendRow(provider: provider, showCost: state.showCost)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(L10n.watch.couldntLoadProviders)
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
            Image(systemName: "cpu")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(L10n.providers.noData)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Concentric ring cluster

/// Activity-ring-style concentric rings. `providers` is already
/// `WatchRingMath.ringProviders` output (≤3, most-constrained first), so
/// the outermost ring and the centre label both key off `providers.first`.
struct ProviderRingCluster: View {
    let providers: [ProviderUsage]

    var body: some View {
        ZStack {
            ForEach(Array(providers.enumerated()), id: \.element.id) { idx, provider in
                ring(for: provider, index: idx)
            }
            centerLabel
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func ring(for provider: ProviderUsage, index: Int) -> some View {
        let base = PulseTheme.providerColor(provider.provider)
        let tier = WatchRingMath.tier(usagePercent: provider.usagePercent)
        let fill = WatchTheme.tierColor(tier, base: base)
        // Inset each successive ring so it nests inside the previous one;
        // the +ringWidth/2 keeps the outermost stroke from clipping the edge.
        let inset = WatchTheme.ringWidth / 2
            + CGFloat(index) * (WatchTheme.ringWidth + WatchTheme.ringGap)
        return ZStack {
            Circle()
                .stroke(base.opacity(WatchTheme.ringTrackOpacity), lineWidth: WatchTheme.ringWidth)
            Circle()
                .trim(from: 0, to: provider.usagePercent)
                .stroke(fill, style: StrokeStyle(lineWidth: WatchTheme.ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(inset)
    }

    @ViewBuilder
    private var centerLabel: some View {
        if let top = providers.first {
            // Constrained to the innermost ring's ~72pt opening so a long or
            // localized provider name shrinks/truncates instead of spilling
            // over the rings (Codex review).
            VStack(spacing: 0) {
                Text("\(WatchRingMath.remainingPercentInt(usagePercent: top.usagePercent))%")
                    .font(WatchTheme.monoNumber(size: 22))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(L10n.watch.providerLeft(top.provider))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: 76)
            .padding(.horizontal, 2)
        }
    }

    private var accessibilitySummary: String {
        providers
            .map { L10n.widget.percentLeft($0.provider, WatchRingMath.remainingPercentInt(usagePercent: $0.usagePercent)) }
            .joined(separator: ", ")
    }
}

// MARK: - Legend row

struct QuotaLegendRow: View {
    let provider: ProviderUsage
    let showCost: Bool

    private var remainingColor: Color {
        WatchTheme.tierColor(WatchRingMath.tier(usagePercent: provider.usagePercent),
                             base: PulseTheme.providerColor(provider.provider))
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(PulseTheme.providerColor(provider.provider))
                .frame(width: 8, height: 8)
            Text(provider.provider)
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            if showCost && provider.estimated_cost_today > 0 {
                Text(CostFormatter.format(provider.estimated_cost_today))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.green)
            }
            if provider.quota != nil {
                Text("\(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent))%")
                    .font(WatchTheme.monoNumber(size: 13))
                    .foregroundStyle(remainingColor)
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
    }
}

// MARK: - Provider Detail (relocated from the retired WatchProvidersView)

struct WatchProviderDetailView: View {
    let provider: ProviderUsage
    let showCost: Bool

    private var providerColor: Color {
        PulseTheme.providerColor(provider.provider)
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: provider.providerKind?.iconName ?? "cpu")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(providerColor)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(provider.provider)
                            .font(.headline)
                        if provider.quota != nil {
                            // "38% Remaining" — uses the dedicated remaining
                            // label, not the ring centre's "{name} left" key.
                            Text("\(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent))% \(L10n.watch.remaining)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if provider.quota != nil {
                Section(L10n.providers.quota) {
                    Gauge(value: provider.usagePercent) {
                        Text(provider.provider)
                    } currentValueLabel: {
                        Text("\(Int(provider.usagePercent * 100))%")
                            .font(.caption.weight(.bold))
                    } minimumValueLabel: {
                        Text("0")
                            .font(.system(size: 8))
                    } maximumValueLabel: {
                        Text("100")
                            .font(.system(size: 8))
                    }
                    .gaugeStyle(.linearCapacity)
                    .tint(WatchTheme.tierColor(WatchRingMath.tier(usagePercent: provider.usagePercent), base: providerColor))
                }
            }

            Section(L10n.dashboard.today) {
                WatchMetricRow(
                    label: L10n.widget.usageTitle,
                    value: CostFormatter.formatUsage(provider.today_usage),
                    icon: "chart.bar.fill"
                )
                if showCost {
                    WatchMetricRow(
                        label: L10n.dashboard.costToday,
                        value: CostFormatter.format(provider.estimated_cost_today),
                        icon: "dollarsign.circle",
                        valueColor: .green
                    )
                }
                if let quota = provider.quota {
                    WatchMetricRow(
                        label: L10n.providers.quota,
                        value: CostFormatter.formatUsage(quota),
                        icon: "gauge.with.needle"
                    )
                }
                if let remaining = provider.remaining {
                    WatchMetricRow(
                        label: L10n.watch.remaining,
                        value: CostFormatter.formatUsage(remaining),
                        icon: "hourglass",
                        valueColor: remaining < (provider.quota ?? Int.max) / 5 ? .red : .primary
                    )
                }
            }

            Section(L10n.providers.thisWeek) {
                WatchMetricRow(
                    label: L10n.widget.usageTitle,
                    value: CostFormatter.formatUsage(provider.week_usage),
                    icon: "calendar"
                )
                if showCost {
                    WatchMetricRow(
                        label: L10n.dashboard.costToday,
                        value: CostFormatter.format(provider.estimated_cost_week),
                        icon: "dollarsign.circle",
                        valueColor: .green
                    )
                }
            }

            Section(L10n.dashboard.activity) {
                WatchMetricRow(
                    label: L10n.tab.sessions,
                    value: "\(provider.recent_sessions.count)",
                    icon: "terminal"
                )
                if !provider.recent_errors.isEmpty {
                    WatchMetricRow(
                        label: L10n.watch.errors,
                        value: "\(provider.recent_errors.count)",
                        icon: "exclamationmark.triangle",
                        valueColor: .red
                    )
                }
                if !provider.status_text.isEmpty {
                    HStack {
                        Text(L10n.providers.status)
                            .font(.caption)
                        Spacer()
                        Text(provider.status_text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(provider.provider)
    }
}
