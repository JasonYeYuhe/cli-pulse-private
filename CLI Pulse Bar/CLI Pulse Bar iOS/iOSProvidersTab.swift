import SwiftUI
import CLIPulseCore

struct iOSProvidersTab: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showDisabled = false
    /// v1.10.7: kinds the user just toggled OFF in this view's lifetime.
    /// Without this, the filter below drops the card the moment the toggle
    /// flips, so the user can't tap it back on — they thought the control
    /// was broken. Sticky-visible until the user leaves the tab and returns.
    @State private var recentlyToggledOff: Set<ProviderKind> = []

    private var isIPad: Bool { horizontalSizeClass == .regular }

    private var visibleDetails: [ProviderDetail] {
        providerState.providerDetails.filter {
            showDisabled
                || $0.config.isEnabled
                || recentlyToggledOff.contains($0.config.kind)
        }
    }

    private func handleToggle(_ kind: ProviderKind, newValue: Bool) {
        if !newValue {
            recentlyToggledOff.insert(kind)
        } else {
            recentlyToggledOff.remove(kind)
        }
        state.setProviderEnabled(kind, isEnabled: newValue)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Cost bar
                    if state.showCost {
                        costBar
                            .padding(.horizontal)
                    }

                    if visibleDetails.isEmpty && providerState.providers.isEmpty {
                        if !authState.isPaired {
                            iOSSyncOnboardingCard()
                                .environmentObject(state)
                                .padding(.horizontal)
                                .padding(.vertical, 20)
                        } else {
                            ContentUnavailableView {
                                Label(L10n.providers.noProviders, systemImage: "cpu")
                            } description: {
                                Text(L10n.providers.emptyHint)
                            }
                            .padding(.vertical, 40)
                        }
                    } else if visibleDetails.isEmpty {
                        // v1.10.7: parity with macOS — when every provider is
                        // toggled off and the user hasn't hit "Show All", give
                        // them a clear path back instead of a blank screen.
                        ContentUnavailableView {
                            Label(L10n.providers.allHidden, systemImage: "eye.slash")
                        } description: {
                            Text(L10n.providers.showAllHint)
                        } actions: {
                            Button(L10n.providers.showAll) {
                                showDisabled = true
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 40)
                    } else if isIPad {
                        // iPad: two-column grid
                        LazyVGrid(columns: [
                            GridItem(.flexible(), spacing: 12),
                            GridItem(.flexible(), spacing: 12),
                        ], spacing: 12) {
                            ForEach(visibleDetails) { detail in
                                iOSEnhancedProviderCard(detail: detail, showCost: state.showCost) { newValue in
                                    handleToggle(detail.config.kind, newValue: newValue)
                                }
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        // iPhone: single column
                        ForEach(visibleDetails) { detail in
                            iOSEnhancedProviderCard(detail: detail, showCost: state.showCost) { newValue in
                                handleToggle(detail.config.kind, newValue: newValue)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle(L10n.tab.providers)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            showDisabled.toggle()
                        } label: {
                            Label(showDisabled ? L10n.providers.hideDisabled : L10n.providers.showAll, systemImage: showDisabled ? "eye.slash" : "eye")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Text("\(providerState.providers.count) \(L10n.providers.tracked)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .refreshable {
                await state.refreshAll()
            }
        }
    }

    private var costBar: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.dashboard.today)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(CostFormatter.format(providerState.costSummary.todayTotal))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.dashboard.thirtyDayEst)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(CostFormatter.format(providerState.costSummary.thirtyDayTotal))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.green)
            }
            Spacer()
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Enhanced Provider Card for iOS

struct iOSEnhancedProviderCard: View {
    let detail: ProviderDetail
    let showCost: Bool
    /// v1.10.7: receives the exact new toggle value instead of an implicit flip.
    /// Mirrors the macOS card contract and removes the last-write-wins race
    /// that made rapid double-taps appear to not re-enable a provider.
    let onToggle: (Bool) -> Void

    private var provider: ProviderUsage { detail.provider }
    private var config: ProviderConfig { detail.config }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: config.kind.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(providerColor)
                    .frame(width: 36, height: 36)
                    .background(providerColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(provider.provider)
                            .font(.headline)
                        Circle()
                            .fill(statusColor)
                            .frame(width: 6, height: 6)
                        if let plan = provider.plan_type, plan != "Unknown", plan != "Free" {
                            Text(plan)
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                        if let meta = provider.metadata {
                            CategoryBadge(category: meta.category)
                        }
                    }
                    HStack(spacing: 4) {
                        Text(provider.status_text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if showCost {
                            CostStatusBadge(status: provider.cost_status_today)
                        }
                        // Provider service-status (incident/maintenance) — renders
                        // nothing unless this provider's status page reports an issue.
                        if let kind = ProviderKind(rawValue: provider.provider) {
                            ServiceStatusBadge(provider: kind)
                        }
                    }
                }
                Spacer()

                Toggle("", isOn: Binding(
                    get: { config.isEnabled },
                    set: { newValue in onToggle(newValue) }
                ))
                .labelsHidden()
            }

            if config.isEnabled {
                // Usage stats
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.dashboard.today)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(CostFormatter.formatUsage(provider.today_usage))
                            .font(.title3.weight(.bold).monospacedDigit())
                        if showCost {
                            Text(CostFormatter.format(provider.estimated_cost_today))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.providers.thisWeek)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(CostFormatter.formatUsage(provider.week_usage))
                            .font(.title3.weight(.bold).monospacedDigit())
                        if showCost {
                            Text(CostFormatter.format(provider.estimated_cost_week))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.green)
                        }
                    }
                    Spacer()
                    quotaBadge
                }

                // Usage tiers (multiple bars when available)
                if !detail.tiers.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(detail.tiers) { tier in
                            UsageBar(
                                label: tier.name,
                                value: 1.0 - tier.usagePercent,
                                color: tierColor(tier),
                                detail: tierDetail(tier)
                            )
                        }
                    }
                } else if let quota = provider.quota, quota > 0 {
                    UsageBar(
                        label: L10n.providers.quota,
                        value: provider.usagePercent,
                        color: usageColor,
                        detail: remainingText
                    )
                }

                // v1.23 G4: CodexBar-parity usage-pace forecast,
                // mirroring the macOS providers card. Engine-gated to
                // Codex/Claude with a valid future reset anchor; nil ⇒
                // the row is absent (intentional ragged-row design
                // since v1.18.2 — Gemini R1 CRITICAL verified: no new
                // misalignment class introduced).
                if let paceSummary = provider.paceSummary() {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(paceSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(providerColor.opacity(config.isEnabled ? 0.2 : 0.05), lineWidth: 1)
        )
        .opacity(config.isEnabled ? 1.0 : 0.6)
        // v1.10 P3-3: card header summary for VoiceOver. Tiers/bars inside
        // keep their own accessibility so the user can drill in; this label
        // is a quick summary when the card is focused.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts: [String] = [provider.provider]
        parts.append(config.isEnabled ? "enabled" : "disabled")
        parts.append(provider.status_text)
        if let quota = provider.quota, quota > 0 {
            let pct = Int(round(provider.usagePercent * 100))
            parts.append("\(pct)% used")
        }
        return parts.joined(separator: ", ")
    }

    private var providerColor: Color { PulseTheme.providerColor(provider.provider) }

    private var statusColor: Color {
        switch detail.operationalStatus {
        case .operational: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }

    private var usageColor: Color {
        if provider.usagePercent > 0.9 { return .red }
        if provider.usagePercent > 0.7 { return .orange }
        return providerColor
    }

    private var remainingText: String? {
        guard let remaining = provider.remaining else { return nil }
        return L10n.detail.remainingValue(CostFormatter.formatUsage(remaining))
    }

    private func tierColor(_ tier: UsageTier) -> Color {
        if tier.usagePercent > 0.9 { return .red }
        if tier.usagePercent > 0.7 { return .orange }
        return providerColor
    }

    private func tierDetail(_ tier: UsageTier) -> String? {
        guard let remaining = tier.remaining, let quota = tier.quota, quota > 0 else { return nil }
        let pctLeft = Int(100.0 * Double(remaining) / Double(quota))
        var result = "\(pctLeft)% left"
        if let reset = tier.resetTime,
           let resetText = RelativeTime.formatReset(reset) {
            result += " · Resets \(resetText)"
        }
        return result
    }

    private var quotaBadge: some View {
        Group {
            if provider.usagePercent > 0.9 {
                StatusBadge(text: L10n.quota.low, color: .red)
            } else if provider.usagePercent > 0.7 {
                StatusBadge(text: L10n.quota.moderate, color: .orange)
            } else {
                StatusBadge(text: L10n.quota.ok, color: .green)
            }
        }
    }
}
