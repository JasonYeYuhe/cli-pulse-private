// UsageDashboardView — the v1.40 PR-5 usage dashboard window content: 8 stat
// tiles, a full-year GitHub-style heatmap (7-row Sunday-start, cost-keyed blue
// ramp), by-model / by-provider capsule bars, and stacked daily-token trends.
// Reads the durable DailyUsageArchive (PR-4) via the actor snapshot on appear.
//
// Structural pass. The 毛玻璃 glass materials, count-up headline, and vendor-
// color backfill land in PR-6; this uses the current PulseTheme tokens.
//
// macOS-only (the archive is Mac-local; the window lives in the menu-bar app).

#if os(macOS)
import SwiftUI
import AppKit
#if canImport(Charts)
import Charts
#endif

// MARK: - HUD frosted-glass window background (token-monitor vibrancy:'hud')

/// `NSVisualEffectView(material:.hudWindow, blendingMode:.behindWindow)` — the
/// authentic frosted backdrop for the dashboard window. No macOS 26 APIs.
private struct HUDWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Heatmap blue ramp (token-monitor palette)

enum UsageHeatmapPalette {
    /// 0…4 intensity → the token-monitor blue ramp (lvl0 faint → lvl4 solid).
    static func color(_ level: Int) -> Color {
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

// MARK: - Stat strip

struct DashboardStatStrip: View {
    let archive: DailyUsageArchive

    private var tiles: [(label: String, value: String)] {
        let today = DailyUsageStats.localDayKey()
        return [
            (L10n.usageDashboard.totalTokens, CostFormatter.formatUsage(DailyUsageStats.totalTokens(archive))),
            (L10n.usageDashboard.totalCost, CostFormatter.format(DailyUsageStats.totalCost(archive))),
            (L10n.usageDashboard.activeDays, "\(DailyUsageStats.activeDays(archive))"),
            (L10n.usageDashboard.currentStreak, "\(DailyUsageStats.currentStreak(archive, todayKey: today))"),
            (L10n.usageDashboard.longestStreak, "\(DailyUsageStats.longestStreak(archive))"),
            (L10n.usageDashboard.peakDay, CostFormatter.formatUsage(DailyUsageStats.peakDay(archive)?.tokens ?? 0)),
            (L10n.usageDashboard.favoriteModel, DailyUsageStats.favoriteModel(archive) ?? "—"),
            (L10n.usageDashboard.messages, "\(DailyUsageStats.totalMessages(archive))"),
        ]
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                VStack(spacing: 3) {
                    Text(tile.value)
                        .font(.system(size: 19, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(tile.label.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(alignment: .leading) { Divider().opacity(0.4) }
            }
        }
        .glassCard(cornerRadius: 14, elevated: false)
    }
}

// MARK: - Breakdown bars

struct DashboardBreakdown: View {
    let title: String
    let rows: [DailyUsageStats.Breakdown]
    let useProviderColor: Bool

    private var grandTotal: Int { max(1, rows.reduce(0) { $0 + $1.tokens }) }
    private var maxTokens: Int { max(1, rows.map(\.tokens).max() ?? 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if rows.isEmpty {
                Text("—").foregroundStyle(.tertiary).font(.caption)
            } else {
                ForEach(Array(rows.prefix(5).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.key)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 110, alignment: .leading)
                        GeometryReader { geo in
                            let frac = min(1.0, Double(row.tokens) / Double(maxTokens))
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.06)).frame(height: 4)
                                Capsule().fill(barColor(row.key))
                                    .frame(width: max(2, geo.size.width * frac), height: 4)
                            }
                        }
                        .frame(height: 4)
                        Text(CostFormatter.formatUsage(row.tokens))
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                        Text("\(Int((Double(row.tokens) / Double(grandTotal) * 100).rounded()))%")
                            .font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func barColor(_ key: String) -> Color {
        useProviderColor ? PulseTheme.providerColor(key) : PulseTheme.accent
    }
}

// MARK: - Trends (stacked daily tokens)

struct DashboardTrends: View {
    let archive: DailyUsageArchive
    @State private var rangeDays: Int = 30   // -1 ⇒ all

    private let ranges: [(label: String, days: Int)] = [
        ("7D", 7), ("30D", 30), ("90D", 90), ("1Y", 365),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.usageDashboard.trends)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $rangeDays) {
                    ForEach(ranges, id: \.days) { Text($0.label).tag($0.days) }
                    Text(L10n.usageDashboard.all).tag(-1)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            chart
        }
    }

    @ViewBuilder
    private var chart: some View {
        #if canImport(Charts)
        let points = trendPoints()
        if points.isEmpty {
            Text(L10n.usageDashboard.empty)
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Chart(points) { p in
                BarMark(x: .value("Day", p.day), y: .value("Tokens", p.tokens))
                    .foregroundStyle(by: .value("Provider", p.provider))
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    if let tokens = value.as(Double.self) {
                        AxisValueLabel {
                            Text(CostFormatter.formatUsage(Int(tokens)))
                                .font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: 6)
            .frame(height: 150)
        }
        #else
        Text(L10n.usageDashboard.empty).font(.caption).foregroundStyle(.secondary)
        #endif
    }

    private struct TrendPoint: Identifiable {
        let day: String
        let provider: String
        let tokens: Int
        // Deterministic id (one bar per day×provider) so Charts diffs stably
        // across re-renders instead of treating every bar as removed+inserted.
        var id: String { "\(day)|\(provider)" }
    }

    private func trendPoints() -> [TrendPoint] {
        let sortedDays = archive.days.keys.sorted()
        let window = rangeDays < 0 ? sortedDays : Array(sortedDays.suffix(rangeDays))
        var points: [TrendPoint] = []
        for dayKey in window {
            guard let day = archive.days[dayKey] else { continue }
            for (provider, slice) in day.perProvider where slice.tokens > 0 {
                points.append(TrendPoint(day: dayKey, provider: provider, tokens: slice.tokens))
            }
        }
        return points
    }
}

// MARK: - Dashboard window content

public struct UsageDashboardView: View {
    /// Shared window id — used by both the Window scene (app target) and the
    /// OverviewTab entry card's `openWindow(id:)` call. Keep them in lockstep.
    public static let windowID = "usage-dashboard"

    @State private var archive: DailyUsageArchive?
    @State private var animatedTokens: Double = 0
    private let providedArchive: DailyUsageArchive?

    /// Live window (loads the archive snapshot on appear).
    public init() { self.providedArchive = nil }
    /// Preview/testing with an explicit archive.
    public init(archive: DailyUsageArchive) { self.providedArchive = archive }

    public var body: some View {
        ScrollView {
            content
                .padding(20)
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(HUDWindowBackground().ignoresSafeArea())
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .dailyUsageArchiveDidChange)) { _ in
            Task { await reload() }
        }
    }

    @MainActor
    private func reload() async {
        let a: DailyUsageArchive
        if let providedArchive {
            a = providedArchive
        } else {
            a = await DailyUsageArchiveManager.shared.snapshot()
            archive = a
        }
        withAnimation(CountUpNumber.countUpAnimation) {
            animatedTokens = Double(DailyUsageStats.totalTokens(a))
        }
    }

    @ViewBuilder
    private var content: some View {
        let a = providedArchive ?? archive
        if let a, !a.days.isEmpty {
            loaded(a)
        } else if a == nil {
            ProgressView().frame(maxWidth: .infinity, minHeight: 400)
        } else {
            EmptyStateView(
                icon: "chart.bar.xaxis",
                title: L10n.usageDashboard.empty,
                subtitle: L10n.usageDashboard.scope)
                .frame(maxWidth: .infinity, minHeight: 400)
        }
    }

    @ViewBuilder
    private func loaded(_ a: DailyUsageArchive) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            header(a)
            DashboardStatStrip(archive: a)
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.usageDashboard.activity)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    UsageHeatmapGrid(archive: a, weeks: 53)
                }
                heatmapLegend
            }
            .padding(14)
            .glassCard(elevated: false)
            HStack(alignment: .top, spacing: 16) {
                DashboardBreakdown(title: L10n.usageDashboard.byModel,
                                   rows: DailyUsageStats.byModel(a), useProviderColor: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCard(elevated: false)
                DashboardBreakdown(title: L10n.usageDashboard.byProvider,
                                   rows: DailyUsageStats.byProvider(a), useProviderColor: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .glassCard(elevated: false)
            }
            DashboardTrends(archive: a)
                .padding(14)
                .glassCard(elevated: false)
        }
    }

    @ViewBuilder
    private func header(_ a: DailyUsageArchive) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.usageDashboard.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CountUpNumber(value: animatedTokens,
                              font: .system(size: 46, weight: .medium, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text("tokens")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Text(L10n.usageDashboard.scope)
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heatmapLegend: some View {
        HStack(spacing: 4) {
            Text(L10n.usageDashboard.less).font(.system(size: 9)).foregroundStyle(.secondary)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(UsageHeatmapPalette.color(level))
                    .frame(width: 11, height: 11)
            }
            Text(L10n.usageDashboard.more).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Compact OverviewTab entry card

/// A ~12-week heatmap card for the Overview tab that opens the full dashboard.
public struct CompactUsageCard: View {
    @Environment(\.openWindow) private var openWindow
    @State private var archive: DailyUsageArchive?

    public init() {}

    public var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: UsageDashboardView.windowID)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.usageDashboard.activity)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let a = archive, !a.days.isEmpty {
                    UsageHeatmapGrid(archive: a, weeks: 12, cell: 10, gap: 3, showMonthLabels: false)
                    HStack(spacing: 14) {
                        miniStat(CostFormatter.formatUsage(DailyUsageStats.totalTokens(a)),
                                 L10n.usageDashboard.totalTokens)
                        miniStat("\(DailyUsageStats.currentStreak(a, todayKey: DailyUsageStats.localDayKey()))",
                                 L10n.usageDashboard.currentStreak)
                        miniStat("\(DailyUsageStats.activeDays(a))", L10n.usageDashboard.activeDays)
                    }
                } else {
                    Text(L10n.usageDashboard.scope)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 10, elevated: false)
        }
        .buttonStyle(.plain)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .dailyUsageArchiveDidChange)) { _ in
            Task { await reload() }
        }
    }

    @MainActor
    private func reload() async {
        archive = await DailyUsageArchiveManager.shared.snapshot()
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            Text(label.uppercased()).font(.system(size: 8)).foregroundStyle(.secondary)
        }
    }
}
#endif
