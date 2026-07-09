// iOSUsageHeatmapView.swift — v1.41 (2026-07-09)
//
// The iOS port of the macOS usage-activity heatmap (UsageDashboardView). The
// grid + palette + intensity/column math are all cross-platform (moved to
// UsageHeatmap.swift); the only iOS-specific pieces are the data hydration
// (cloud-only via AppState.refreshUsageArchive — no local JSONL scan on iOS)
// and the presentation (a compact Overview card that pushes a full drill-in via
// the existing NavigationStack, instead of the macOS floating panel/window).

import SwiftUI
import CLIPulseCore

// MARK: - Compact Overview card

/// A width-filling ~year heatmap card for the iOS Overview tab. Taps push the
/// full usage dashboard. Reads `state.usageArchive` (cloud-hydrated).
struct iOSUsageHeatmapCard: View {
    @EnvironmentObject var state: AppState
    @State private var loading = true

    // Compact cell metrics; weeks computed to fill the card width.
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private var rowHeight: CGFloat { 7 * cell + 6 * gap }

    private var archive: DailyUsageArchive { state.usageArchive }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.usageDashboard.activity, icon: "square.grid.3x3.fill")
            NavigationLink {
                iOSUsageDashboardView()
                    .environmentObject(state)
            } label: {
                cardBody
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .task {
            await state.refreshUsageArchive()
            loading = false
        }
    }

    @ViewBuilder
    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if archive.days.isEmpty {
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .frame(height: rowHeight)
                } else {
                    Text(L10n.usageDashboard.scope)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(height: rowHeight, alignment: .center)
                        .frame(maxWidth: .infinity)
                }
            } else {
                GeometryReader { geo in
                    let weeks = max(12, Int((geo.size.width + gap) / (cell + gap)))
                    UsageHeatmapGrid(archive: archive, weeks: weeks, cell: cell, gap: gap,
                                     showMonthLabels: false)
                }
                .frame(height: rowHeight)
                HStack(spacing: 18) {
                    miniStat(CostFormatter.formatUsage(DailyUsageStats.totalTokens(archive)),
                             L10n.usageDashboard.totalTokens)
                    miniStat("\(DailyUsageStats.currentStreak(archive, todayKey: DailyUsageStats.localDayKey()))",
                             L10n.usageDashboard.currentStreak)
                    miniStat("\(DailyUsageStats.activeDays(archive))", L10n.usageDashboard.activeDays)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 12, elevated: false)
        .contentShape(Rectangle())
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 14, weight: .semibold)).monospacedDigit()
            Text(label.uppercased())
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Full drill-in dashboard

/// The full-screen usage-activity view: header totals, stat tiles, the year
/// heatmap with month labels + legend, and by-provider / by-model breakdowns.
/// Pushed onto the Overview's NavigationStack (no new stack of its own).
struct iOSUsageDashboardView: View {
    @EnvironmentObject var state: AppState
    @State private var loading = true

    private var archive: DailyUsageArchive { state.usageArchive }

    // Full heatmap cell metrics (a touch larger than the compact card).
    private let cell: CGFloat = 13
    private let gap: CGFloat = 4
    private var rowHeight: CGFloat { cell * 7 + gap * 6 + 18 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if archive.days.isEmpty {
                    emptyState
                } else {
                    header
                    statTiles
                    heatmapCard
                    breakdown(L10n.usageDashboard.byProvider,
                              rows: DailyUsageStats.byProvider(archive), useProviderColor: true)
                    breakdown(L10n.usageDashboard.byModel,
                              rows: DailyUsageStats.byModel(archive), useProviderColor: false)
                }
            }
            .padding()
        }
        .navigationTitle(L10n.usageDashboard.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await state.refreshUsageArchive()
            loading = false
        }
        .refreshable { await state.refreshUsageArchive(force: true) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(CostFormatter.formatUsage(DailyUsageStats.totalTokens(archive)))
                        .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text("tokens · \(L10n.usageDashboard.scope)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(CostFormatter.format(DailyUsageStats.totalCost(archive)))
                        .font(.system(size: 20, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(PulseTheme.accent)
                    Text(L10n.usageDashboard.totalCost.uppercased())
                        .font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Stat tiles

    private var statTiles: some View {
        let today = DailyUsageStats.localDayKey()
        let tiles: [(String, String)] = [
            (L10n.usageDashboard.activeDays, "\(DailyUsageStats.activeDays(archive))"),
            (L10n.usageDashboard.currentStreak, "\(DailyUsageStats.currentStreak(archive, todayKey: today))"),
            (L10n.usageDashboard.longestStreak, "\(DailyUsageStats.longestStreak(archive))"),
            (L10n.usageDashboard.peakDay, CostFormatter.formatUsage(DailyUsageStats.peakDay(archive)?.tokens ?? 0)),
        ]
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.1).font(.system(size: 18, weight: .semibold)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text(t.0.uppercased()).font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .glassCard(cornerRadius: 12, elevated: false)
            }
        }
    }

    // MARK: Heatmap

    private var heatmapCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.usageDashboard.activity)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            GeometryReader { geo in
                let weeks = max(12, Int((geo.size.width + gap) / (cell + gap)))
                UsageHeatmapGrid(archive: archive, weeks: weeks, cell: cell, gap: gap, showMonthLabels: true)
            }
            .frame(height: rowHeight)
            UsageHeatmapLegend()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(elevated: false)
    }

    // MARK: Breakdown

    @ViewBuilder
    private func breakdown(_ title: String, rows: [DailyUsageStats.Breakdown], useProviderColor: Bool) -> some View {
        if !rows.isEmpty {
            let maxTokens = max(1, rows.map(\.tokens).max() ?? 1)
            let grand = max(1, rows.reduce(0) { $0 + $1.tokens })
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(Array(rows.prefix(6).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        Text(row.key).font(.system(size: 12))
                            .lineLimit(1).truncationMode(.middle)
                            .frame(width: 96, alignment: .leading)
                        GeometryReader { geo in
                            let frac = min(1.0, Double(row.tokens) / Double(maxTokens))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.secondary.opacity(0.12)).frame(height: 5)
                                Capsule().fill(useProviderColor ? PulseTheme.providerColor(row.key) : PulseTheme.accent)
                                    .frame(width: max(3, geo.size.width * frac), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text(CostFormatter.formatUsage(row.tokens))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 54, alignment: .trailing)
                        Text("\(Int((Double(row.tokens) / Double(grand) * 100).rounded()))%")
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.tertiary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(elevated: false)
        }
    }

    // MARK: Empty / loading

    private var emptyState: some View {
        VStack(spacing: 12) {
            if loading {
                ProgressView()
            } else {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 34)).foregroundStyle(.tertiary)
                Text(L10n.usageDashboard.empty).font(.headline)
                Text(L10n.usageDashboard.scope).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
}
