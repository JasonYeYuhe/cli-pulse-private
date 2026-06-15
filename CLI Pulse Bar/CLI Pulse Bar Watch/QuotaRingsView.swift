import SwiftUI
import CLIPulseCore

/// Quota page. Concentric rings show **remaining** headroom (countdown,
/// matching macOS/iOS and the watch-face complication) for the top-3
/// most-constrained providers; below, each provider gets per-window
/// quota bars (5h / Weekly / …) that also count down, reusing the shared
/// `UsageBar` so the watch reads identically to the phone & Mac.
///
/// Presentation-only — reads `state.*` (incl. the already-synced
/// `ProviderUsage.tiers`), never mutates the data layer. One `ScrollView`
/// (review R1).
struct QuotaRingsView: View {
    @EnvironmentObject var state: WatchAppState

    private var visibleProviders: [ProviderUsage] {
        state.providers.filter { state.enabledProviderNames.contains($0.provider) }
    }

    /// Per-provider cards, most-constrained (least headroom) first so the
    /// provider closest to running out sits at the top of the list.
    private var sortedProviders: [ProviderUsage] {
        visibleProviders.sorted { a, b in
            if a.usagePercent != b.usagePercent { return a.usagePercent > b.usagePercent }
            return a.provider < b.provider
        }
    }

    /// Concentric rings: metered providers, most-constrained first, capped
    /// at 3 for legibility. Shared math so rings can't diverge from the
    /// bars / complication.
    private var ringProviders: [ProviderUsage] {
        WatchRingMath.ringProviders(visibleProviders, limit: 3)
    }

    private var meteredCount: Int {
        visibleProviders.filter { $0.quota != nil }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
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
                    ForEach(sortedProviders) { provider in
                        NavigationLink {
                            WatchProviderDetailView(provider: provider, showCost: state.showCost)
                        } label: {
                            ProviderTierCard(provider: provider, showCost: state.showCost)
                        }
                        .buttonStyle(.plain)
                    }
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

// MARK: - Quota math/colour helpers (shared by the cards + detail)

enum QuotaTierStyle {
    /// Colour for a tier, red/amber when nearly exhausted (keyed on
    /// consumption like macOS `tierColor`, > 0.9 / > 0.7).
    static func color(quota: Int, remaining: Int, base: Color) -> Color {
        WatchTheme.tierColor(WatchRingMath.tier(usagePercent: WatchRingMath.usagePercent(quota: quota, remaining: remaining)), base: base)
    }
    /// "38% left" detail string for a tier.
    static func detail(quota: Int, remaining: Int) -> String {
        L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(quota: quota, remaining: remaining))
    }
}

// MARK: - Concentric ring cluster (remaining / countdown)

/// Activity-ring-style concentric rings. `providers` is already
/// `WatchRingMath.ringProviders` output (≤3, most-constrained first), so
/// the outermost ring and the centre label both key off `providers.first`.
/// Each ring's arc is the provider's **remaining** headroom and depletes
/// as quota is used (matching macOS/iOS and the complication).
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
        let remaining = WatchRingMath.remainingFraction(usagePercent: provider.usagePercent)
        // Inset each successive ring so it nests inside the previous one;
        // the +ringWidth/2 keeps the outermost stroke from clipping the edge.
        let inset = WatchTheme.ringWidth / 2
            + CGFloat(index) * (WatchTheme.ringWidth + WatchTheme.ringGap)
        return ZStack {
            Circle()
                .stroke(base.opacity(WatchTheme.ringTrackOpacity), lineWidth: WatchTheme.ringWidth)
            Circle()
                .trim(from: 0, to: remaining)
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
            // over the rings.
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

// MARK: - Per-provider tier card (5h / Weekly countdown bars)

/// One card per provider: name + its per-window quota bars (5h, Weekly, …)
/// shown as **remaining** (counting down). Caps at the first 2 windows for
/// the glance (collectors order the primary 5h + Weekly first); the full
/// set is on the detail view. Falls back to a single overall bar when the
/// provider reports no tiers, and to a plain "—" when it has no quota
/// window at all (matching macOS/iOS).
struct ProviderTierCard: View {
    let provider: ProviderUsage
    let showCost: Bool

    private var providerColor: Color { PulseTheme.providerColor(provider.provider) }

    /// Overall remaining %, same source of truth as the rings (R4).
    private var overallColor: Color {
        WatchTheme.tierColor(WatchRingMath.tier(usagePercent: provider.usagePercent), base: providerColor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: dot + name + overall "% left" (provider-level headline).
            HStack(spacing: 6) {
                Circle()
                    .fill(providerColor)
                    .frame(width: 8, height: 8)
                Text(provider.provider)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if provider.quota != nil {
                    Text(L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent)))
                        .font(WatchTheme.monoNumber(size: 12))
                        .foregroundStyle(overallColor)
                }
            }

            // Per-window quota bars (5h / Weekly …), or one overall bar.
            if !provider.tiers.isEmpty {
                ForEach(Array(provider.tiers.prefix(2).enumerated()), id: \.offset) { _, tier in
                    UsageBar(
                        label: tier.name,
                        value: WatchRingMath.remainingFraction(quota: tier.quota, remaining: tier.remaining),
                        color: QuotaTierStyle.color(quota: tier.quota, remaining: tier.remaining, base: providerColor),
                        detail: QuotaTierStyle.detail(quota: tier.quota, remaining: tier.remaining)
                    )
                }
            } else if provider.quota != nil {
                UsageBar(
                    label: L10n.providers.quota,
                    value: WatchRingMath.remainingFraction(usagePercent: provider.usagePercent),
                    color: overallColor,
                    detail: L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent))
                )
            }

            // Footer: cost (when shown) + today's token usage.
            HStack(spacing: 5) {
                if showCost && provider.estimated_cost_today > 0 {
                    Text(CostFormatter.format(provider.estimated_cost_today))
                        .foregroundStyle(.green)
                }
                Text(L10n.watch.tokensUsed(CostFormatter.formatUsage(provider.today_usage)))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption2.monospacedDigit())
        }
        .padding(8)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
        .accessibilityElement(children: .combine)
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
                            Text("\(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent))% \(L10n.watch.remaining)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Quota — per-window bars (remaining/countdown) like macOS/iOS,
            // or the overall gauge when the provider reports no tiers.
            if !provider.tiers.isEmpty {
                Section(L10n.providers.quota) {
                    ForEach(provider.tiers.indices, id: \.self) { i in
                        let tier = provider.tiers[i]
                        UsageBar(
                            label: tier.name,
                            value: WatchRingMath.remainingFraction(quota: tier.quota, remaining: tier.remaining),
                            color: QuotaTierStyle.color(quota: tier.quota, remaining: tier.remaining, base: providerColor),
                            detail: tierDetail(tier)
                        )
                    }
                }
            } else if provider.quota != nil {
                Section(L10n.providers.quota) {
                    Gauge(value: WatchRingMath.remainingFraction(usagePercent: provider.usagePercent)) {
                        Text(provider.provider)
                    } currentValueLabel: {
                        Text("\(WatchRingMath.remainingPercentInt(usagePercent: provider.usagePercent))%")
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

    /// "38% left · Resets in 2h" — mirrors the macOS `tierDetail`.
    private func tierDetail(_ tier: TierDTO) -> String {
        var s = L10n.watch.percentLeft(WatchRingMath.remainingPercentInt(quota: tier.quota, remaining: tier.remaining))
        if let reset = tier.reset_time, let resetText = RelativeTime.formatReset(reset) {
            s += " · \(resetText)"
        }
        return s
    }
}
