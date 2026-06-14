import SwiftUI
import CLIPulseCore

/// Live (sessions) page. Running sessions are featured as cards (provider
/// colour bar + project + provider·duration + a small activity spark);
/// non-running sessions are dimmed compact rows below. Drill-down to the
/// detail view is preserved.
///
/// Presentation-only — reads `state.*`, never mutates the data layer.
/// Owns one `ScrollView` (review R1).
struct WatchSessionsView: View {
    @EnvironmentObject var state: WatchAppState

    private var runningSessions: [SessionRecord] {
        state.sessions.filter { $0.status.caseInsensitiveCompare("running") == .orderedSame }
    }

    private var otherSessions: [SessionRecord] {
        state.sessions.filter { $0.status.caseInsensitiveCompare("running") != .orderedSame }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                header

                if state.sessions.isEmpty {
                    emptyState
                } else {
                    ForEach(runningSessions) { session in
                        NavigationLink {
                            WatchSessionDetailView(session: session, showCost: state.showCost)
                        } label: {
                            SessionCard(session: session, showCost: state.showCost)
                        }
                        .buttonStyle(.plain)
                    }
                    ForEach(otherSessions) { session in
                        NavigationLink {
                            WatchSessionDetailView(session: session, showCost: state.showCost)
                        } label: {
                            SessionCompactRow(session: session)
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
        HStack(spacing: 5) {
            LiveDot(size: 7)
            Text(L10n.watch.live)
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            if !runningSessions.isEmpty {
                Text(L10n.sessions.countRunning(runningSessions.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(L10n.sessions.noSessions)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}

// MARK: - Running session card (featured)

struct SessionCard: View {
    let session: SessionRecord
    let showCost: Bool

    private var color: Color { PulseTheme.providerColor(session.provider) }

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(session.project)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text("\(session.provider) · \(RelativeTime.format(session.started_at))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    ActivitySpark(seed: Self.stableSeed(session.id), color: color)
                }

                HStack(spacing: 4) {
                    Text(CostFormatter.formatUsage(session.total_usage))
                        .font(WatchTheme.monoNumber(size: 11))
                    if showCost && session.estimated_cost > 0 {
                        Text(CostFormatter.format(session.estimated_cost))
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.green)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(8)
        .background(WatchTheme.cardFillStrong, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
    }

    /// Launch-stable seed from the session id (UTF-8 byte sum) so the
    /// decorative spark is consistent per session and varies between them.
    static func stableSeed(_ id: String) -> Int {
        id.utf8.reduce(0) { $0 &+ Int($1) }
    }
}

// MARK: - Non-running session row (dimmed)

struct SessionCompactRow: View {
    let session: SessionRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: session.providerKind?.iconName ?? "terminal")
                .font(.caption2)
                .foregroundStyle(PulseTheme.providerColor(session.provider))
                .frame(width: 16)

            Text(session.project)
                .font(.caption)
                .lineLimit(1)

            Spacer(minLength: 4)

            StatusBadge(text: session.status, color: PulseTheme.statusColor(session.status))
                .scaleEffect(0.82)

            Text(CostFormatter.formatUsage(session.total_usage))
                .font(WatchTheme.monoNumber(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius))
        .opacity(0.7)
    }
}

// MARK: - Activity spark (decorative)

/// A small bar-spark motif beside a running session. Heights are derived
/// deterministically from `seed` — this is a *decorative* texture, not a
/// time series (SessionRecord carries no per-session trend), so it is
/// hidden from VoiceOver.
struct ActivitySpark: View {
    let seed: Int
    let color: Color
    var bars: Int = 5

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<bars, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: barHeight(i))
            }
        }
        .frame(height: 13, alignment: .bottom)
        .accessibilityHidden(true)
    }

    private func barHeight(_ i: Int) -> CGFloat {
        // Constant kept under Int32.max — watchOS is arm64_32 (32-bit Int),
        // where a larger literal would overflow at compile time. `&*`/`&+`
        // wrap safely; this is decorative so exact values don't matter.
        let h = abs((seed &* 1_103_515_245 &+ i &* 40_503) % 9) // 0...8
        return CGFloat(5 + h) // 5...13
    }
}

// MARK: - Session Detail

struct WatchSessionDetailView: View {
    let session: SessionRecord
    let showCost: Bool

    var body: some View {
        List {
            Section {
                HStack(spacing: 6) {
                    Image(systemName: session.providerKind?.iconName ?? "terminal")
                        .foregroundStyle(PulseTheme.providerColor(session.provider))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.name)
                            .font(.caption.weight(.bold))
                            .lineLimit(2)
                        StatusBadge(
                            text: session.status,
                            color: PulseTheme.statusColor(session.status)
                        )
                        .scaleEffect(0.85)
                    }
                }
            }

            Section(L10n.sessions.details) {
                WatchMetricRow(label: L10n.tab.providers, value: session.provider, icon: "cpu")
                WatchMetricRow(label: L10n.dashboard.topProjects, value: session.project, icon: "folder")
                WatchMetricRow(label: L10n.dashboard.onlineDevices, value: session.device_name, icon: "desktopcomputer")
                WatchMetricRow(label: L10n.alerts.created, value: RelativeTime.format(session.started_at), icon: "clock")
            }

            Section(L10n.dashboard.quickStats) {
                WatchMetricRow(
                    label: L10n.widget.usageTitle,
                    value: CostFormatter.formatUsage(session.total_usage),
                    icon: "chart.bar.fill"
                )
                if showCost {
                    WatchMetricRow(
                        label: L10n.dashboard.costToday,
                        value: CostFormatter.format(session.estimated_cost),
                        icon: "dollarsign.circle",
                        valueColor: .green
                    )
                }
                WatchMetricRow(
                    label: L10n.dashboard.requests,
                    value: "\(session.requests)",
                    icon: "arrow.up.arrow.down"
                )
                if session.error_count > 0 {
                    WatchMetricRow(
                        label: L10n.watch.errors,
                        value: "\(session.error_count)",
                        icon: "exclamationmark.triangle",
                        valueColor: .red
                    )
                }
            }
        }
        .navigationTitle(session.name)
    }
}
