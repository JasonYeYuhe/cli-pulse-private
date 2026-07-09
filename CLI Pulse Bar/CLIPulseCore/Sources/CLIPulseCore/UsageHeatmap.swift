// UsageHeatmap.swift — the reusable GitHub-style usage-activity heatmap.
//
// v1.41 (2026-07-09): extracted verbatim from the macOS-only UsageDashboardView
// so the iOS Overview can render the same year heatmap. The grid + palette have
// ZERO AppKit dependency — they were macOS-only purely by the enclosing
// `#if os(macOS)`, so they live here (un-gated) and both the macOS dashboard
// and the iOS heatmap card consume them. The intensity/column math is already
// cross-platform (DailyUsageStats), as is the archive (DailyUsageArchive).

import SwiftUI

// MARK: - Heatmap blue ramp (token-monitor palette)

public enum UsageHeatmapPalette {
    /// 0…4 intensity → the token-monitor blue ramp (lvl0 faint → lvl4 solid).
    public static func color(_ level: Int) -> Color {
        switch level {
        case 4: return Color(.sRGB, red: 180 / 255, green: 230 / 255, blue: 255 / 255, opacity: 1.0)
        case 3: return Color(.sRGB, red: 150 / 255, green: 210 / 255, blue: 255 / 255, opacity: 0.8)
        case 2: return Color(.sRGB, red: 120 / 255, green: 190 / 255, blue: 255 / 255, opacity: 0.45)
        case 1: return Color(.sRGB, red: 90 / 255, green: 170 / 255, blue: 255 / 255, opacity: 0.18)
        default: return Color.white.opacity(0.05)
        }
    }
}

// MARK: - Reusable heatmap grid

public struct UsageHeatmapGrid: View {
    let archive: DailyUsageArchive
    let weeks: Int
    var cell: CGFloat = 13
    var gap: CGFloat = 4
    var showMonthLabels: Bool = true

    public init(archive: DailyUsageArchive, weeks: Int, cell: CGFloat = 13, gap: CGFloat = 4,
                showMonthLabels: Bool = true) {
        self.archive = archive; self.weeks = weeks; self.cell = cell; self.gap = gap
        self.showMonthLabels = showMonthLabels
    }

    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()

    public var body: some View {
        let today = DailyUsageStats.localDayKey()
        let peak = DailyUsageStats.peakDayCost(archive)
        let columns = DailyUsageStats.heatmapColumns(todayKey: today, weeks: weeks)
        VStack(alignment: .leading, spacing: gap) {
            HStack(alignment: .top, spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: gap) {
                        ForEach(week, id: \.self) { dayKey in
                            cellView(dayKey, today: today, peak: peak)
                        }
                    }
                }
            }
            if showMonthLabels { monthLabels(columns) }
        }
    }

    @ViewBuilder
    private func cellView(_ dayKey: String, today: String, peak: Double) -> some View {
        let isFuture = dayKey > today
        let level = isFuture ? 0 : DailyUsageStats.intensity(archive, dayKey: dayKey, peakCost: peak)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(isFuture ? Color.clear : UsageHeatmapPalette.color(level))
            .frame(width: cell, height: cell)
            .help(tooltip(dayKey, isFuture: isFuture))
    }

    private func tooltip(_ dayKey: String, isFuture: Bool) -> String {
        guard !isFuture, let day = archive.days[dayKey], (day.tokens > 0 || day.messages > 0) else {
            return dayKey
        }
        return "\(dayKey): \(CostFormatter.formatUsage(day.tokens)) tokens · \(CostFormatter.format(day.cost))"
    }

    @ViewBuilder
    private func monthLabels(_ columns: [[String]]) -> some View {
        HStack(spacing: gap) {
            ForEach(Array(columns.enumerated()), id: \.offset) { idx, week in
                let label = monthLabel(forColumn: idx, columns: columns)
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                    .frame(width: cell + gap, alignment: .leading)
                    .fixedSize()
            }
        }
    }

    /// Show a short month name on the first column whose Sunday falls in a new month.
    private func monthLabel(forColumn idx: Int, columns: [[String]]) -> String {
        guard let month = monthComponent(columns[idx].first) else { return "" }
        if idx == 0 {
            return shortMonth(month)
        }
        guard let prev = monthComponent(columns[idx - 1].first) else { return shortMonth(month) }
        return month != prev ? shortMonth(month) : ""
    }

    private func monthComponent(_ dayKey: String?) -> Int? {
        guard let dayKey, let date = Self.monthFmt.date(from: dayKey) else { return nil }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal.component(.month, from: date)
    }

    private func shortMonth(_ month: Int) -> String {
        let symbols = DateFormatter().shortMonthSymbols ?? []
        guard month >= 1, month <= symbols.count else { return "" }
        return symbols[month - 1]
    }
}

// MARK: - Shared heatmap legend (Less ▁▂▃▄▅ More)

/// The 5-swatch intensity legend, extracted so iOS reuses it verbatim.
public struct UsageHeatmapLegend: View {
    var swatch: CGFloat = 11
    public init(swatch: CGFloat = 11) { self.swatch = swatch }
    public var body: some View {
        HStack(spacing: 4) {
            Text(L10n.usageDashboard.less).font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(UsageHeatmapPalette.color(level))
                    .frame(width: swatch, height: swatch)
            }
            Text(L10n.usageDashboard.more).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}
