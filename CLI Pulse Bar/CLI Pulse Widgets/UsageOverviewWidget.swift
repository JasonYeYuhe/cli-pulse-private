import WidgetKit
import SwiftUI
import CLIPulseCore

// MARK: - Usage Overview Widget (Small + Medium + Large)

struct UsageOverviewWidget: Widget {
    let kind = "UsageOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CLIPulseTimelineProvider()) { entry in
            UsageOverviewWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(L10n.widget.overviewTitle)
        .description(L10n.widget.overviewDescription)
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Widget View

struct UsageOverviewWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: CLIPulseEntry

    var body: some View {
        // v1.30 — home-screen widgets are Pro-only. Fail-open: only an
        // explicit `false` locks (nil legacy payload / paid user → content).
        if entry.data.isPro == false {
            WidgetProLockedView()
        } else {
            switch family {
            case .systemSmall:
                smallView
            case .systemMedium:
                mediumView
            case .systemLarge:
                largeView
            default:
                smallView
            }
        }
    }

    // MARK: - Small: Total usage ring

    private var smallView: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 6)
                    .frame(width: 60, height: 60)

                let topProvider = entry.data.providers.first
                let percent = topProvider?.usagePercent ?? 0

                Circle()
                    .trim(from: 0, to: min(percent, 1.0))
                    .stroke(
                        WidgetTheme.providerGradient(topProvider?.name ?? ""),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .frame(width: 60, height: 60)
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    Text("\(Int(percent * 100))")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("%")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            Text(entry.data.providers.first?.name ?? L10n.widget.noData)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)

            Text(formatUsage(entry.data.totalUsageToday))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Medium: 3 provider bars

    private var mediumView: some View {
        HStack(spacing: 12) {
            // Left: summary
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WidgetTheme.accent)
                    Text(L10n.auth.title)
                        .font(.caption.weight(.bold))
                }

                Text(formatUsage(entry.data.totalUsageToday))
                    .font(.title2.weight(.bold).monospacedDigit())

                Text(formatCost(entry.data.totalCostToday))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.green)

                Spacer()

                HStack(spacing: 8) {
                    WidgetMiniStat(icon: "terminal", value: "\(entry.data.activeSessions)", color: .blue)
                    if entry.data.unresolvedAlerts > 0 {
                        WidgetMiniStat(icon: "bell.badge", value: "\(entry.data.unresolvedAlerts)", color: .red)
                    }
                    Spacer()
                    if #available(iOS 17.0, *) {
                        Button(intent: RefreshWidgetIntent()) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .tint(WidgetTheme.accent)
                    }
                }
            }

            Divider()

            // Right: provider bars
            VStack(alignment: .leading, spacing: 8) {
                // Dual countdown bars need more room than the old single bar,
                // so the medium column shows the top 2 providers to avoid
                // clipping (the large widget shows up to 5). Ordered by the
                // app's most-constrained-first provider sort.
                ForEach(Array(entry.data.providers.prefix(2))) { provider in
                    ProviderCountdownBars(provider: provider, compact: true)
                }

                if entry.data.providers.isEmpty {
                    Text(L10n.widget.noProviderData)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Large: Full dashboard

    private var largeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(WidgetTheme.accent)
                    Text(L10n.auth.title)
                        .font(.caption.weight(.bold))
                }
                Spacer()
                Text(entry.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if #available(iOS 17.0, *) {
                    Button(intent: RefreshWidgetIntent()) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .tint(WidgetTheme.accent)
                }
            }

            // Stats row
            HStack(spacing: 0) {
                WidgetMetricBox(title: L10n.widget.usageTitle, value: formatUsage(entry.data.totalUsageToday))
                WidgetMetricBox(title: L10n.dashboard.costToday, value: formatCost(entry.data.totalCostToday), color: .green)
                WidgetMetricBox(title: L10n.tab.sessions, value: "\(entry.data.activeSessions)")
                WidgetMetricBox(title: L10n.tab.alerts, value: "\(entry.data.unresolvedAlerts)", color: entry.data.unresolvedAlerts > 0 ? .red : .primary)
            }

            Divider()

            // Provider list
            Text(L10n.tab.providers)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(entry.data.providers.prefix(5))) { provider in
                ProviderCountdownBars(provider: provider, compact: false)
            }

            if entry.data.providers.isEmpty {
                Text(L10n.widget.noProviderData)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formatUsage(_ usage: Int) -> String {
        if usage >= 1_000_000 {
            return String(format: "%.1fM", Double(usage) / 1_000_000)
        } else if usage >= 1_000 {
            return String(format: "%.0fK", Double(usage) / 1_000)
        }
        return "\(usage)"
    }

    private func formatCost(_ cost: Double) -> String {
        String(format: "$%.2f", cost)
    }
}

// MARK: - Subviews

struct WidgetMiniStat: View {
    let icon: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(color)
            Text(value)
                .font(.caption2.weight(.bold).monospacedDigit())
        }
    }
}

/// Per-provider countdown bars: two depleting bars (5h/session + weekly),
/// each filled with REMAINING headroom and labelled with the remaining %.
/// Matches the watch + macOS Quota redesign (count down, red/amber as the
/// budget nears exhaustion). `compact` = the medium widget's tight column;
/// non-compact = the roomier large widget (adds today's cost).
struct ProviderCountdownBars: View {
    let provider: WidgetProviderData
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            HStack(spacing: 4) {
                Image(systemName: provider.iconName)
                    .font(.system(size: compact ? 9 : 11))
                    .foregroundStyle(WidgetTheme.providerColor(provider.name))
                Text(provider.name)
                    .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if !compact {
                    Text(provider.formattedCost)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.green)
                }
            }
            countdownRow(L10n.widget.window5h, used: provider.sessionUsed)
            countdownRow(L10n.widget.windowWeekly, used: provider.weeklyUsed)
        }
    }

    private func countdownRow(_ label: String, used: Double) -> some View {
        let remaining = max(0, min(1, 1 - used))
        return HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.gray.opacity(0.2))
                    Capsule()
                        .fill(WidgetTheme.countdownColor(
                            used: used,
                            base: WidgetTheme.providerColor(provider.name)))
                        .frame(width: max(2, geo.size.width * remaining))
                }
            }
            .frame(height: compact ? 4 : 5)
            Text("\(Int((remaining * 100).rounded()))%")
                .font(.system(size: compact ? 9 : 10, weight: .bold).monospacedDigit())
                .frame(width: 30, alignment: .trailing)
        }
    }
}

struct WidgetMetricBox: View {
    let title: String
    let value: String
    var color: Color = .primary

    var body: some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Preview

#Preview(as: .systemSmall) {
    UsageOverviewWidget()
} timeline: {
    CLIPulseEntry(date: .now, data: .preview)
}

#Preview(as: .systemMedium) {
    UsageOverviewWidget()
} timeline: {
    CLIPulseEntry(date: .now, data: .preview)
}

#Preview(as: .systemLarge) {
    UsageOverviewWidget()
} timeline: {
    CLIPulseEntry(date: .now, data: .preview)
}
