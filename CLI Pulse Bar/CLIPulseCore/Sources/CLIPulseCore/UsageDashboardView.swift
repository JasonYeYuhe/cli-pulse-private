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

/// Frosted `NSVisualEffectView` backdrop for the dashboard window — the token-
/// monitor `vibrancy:'hud'` look. Scheme-ADAPTIVE: `.hudWindow` (dark) forced to
/// darkAqua in dark mode, a light `.underWindowBackground` forced to aqua in
/// light mode — so the backdrop, the `.glassCard()` tint (which reads the same
/// colorScheme), and the system title bar all agree (no light-mode seam). No
/// macOS 26 APIs.
private struct HUDWindowBackground: NSViewRepresentable {
    var isDark: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        apply(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { apply(view) }

    private func apply(_ view: NSVisualEffectView) {
        view.material = isDark ? .hudWindow : .underWindowBackground
        view.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
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
                VStack(spacing: 2) {
                    Text(tile.value)
                        .font(.system(size: 15, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(tile.label.uppercased())
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
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

    @Environment(\.colorScheme) private var colorScheme
    @State private var archive: DailyUsageArchive?
    @State private var animatedTokens: Double = 0
    @State private var didAnimateCountUp = false
    private let providedArchive: DailyUsageArchive?
    /// When false, the content is laid out at its natural height with no
    /// ScrollView — the slide-out panel sizes its window to this height so
    /// everything fits on one page (no vertical scrollbar). The resizable
    /// standalone Window keeps `scrollable: true`.
    private let scrollable: Bool

    /// Live window (loads the archive snapshot on appear).
    public init(scrollable: Bool = true) { self.providedArchive = nil; self.scrollable = scrollable }
    /// Preview/testing with an explicit archive.
    public init(archive: DailyUsageArchive, scrollable: Bool = true) {
        self.providedArchive = archive; self.scrollable = scrollable
    }

    public var body: some View {
        Group {
            if scrollable {
                ScrollView { paddedContent }
            } else {
                paddedContent
            }
        }
        .frame(minWidth: 380, minHeight: scrollable ? 500 : nil)
        .background(HUDWindowBackground(isDark: colorScheme == .dark).ignoresSafeArea())
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .dailyUsageArchiveDidChange)) { _ in
            Task { await reload() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .displayCurrencyDidChange)) { _ in
            Task { await reload() }   // re-render cost figures in the new currency
        }
    }

    private var paddedContent: some View {
        content
            .padding(.horizontal, 26)
            .padding(.vertical, 22)
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
        let target = Double(DailyUsageStats.totalTokens(a))
        // Count-up is a ONE-TIME reveal — background refreshes update the value
        // without replaying the 2.2s sweep every ~2 min.
        if didAnimateCountUp {
            animatedTokens = target
        } else {
            didAnimateCountUp = true
            withAnimation(CountUpNumber.countUpAnimation) { animatedTokens = target }
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
                // Fill the card width with as many trailing weeks as fit, ending
                // in TODAY's column (heatmapColumns anchors on `localDayKey()`), so
                // "now" is always the rightmost column. The old fixed 53-week grid
                // sat in a horizontal ScrollView that defaulted to the left
                // (oldest) edge, hiding recent activity off-screen to the right.
                let cell: CGFloat = 11, gap: CGFloat = 3
                GeometryReader { geo in
                    let weeks = max(12, Int((geo.size.width + gap) / (cell + gap)))
                    UsageHeatmapGrid(archive: a, weeks: weeks, cell: cell, gap: gap,
                                     showMonthLabels: true)
                }
                .frame(height: cell * 7 + gap * 6 + 18)   // 7 day-rows + month labels
                heatmapLegend
            }
            .padding(14)
            .glassCard(elevated: false)
            breakdowns(a)
            DashboardTrends(archive: a)
                .padding(14)
                .glassCard(elevated: false)
        }
    }

    // By-Model / By-Provider breakdowns. Side-by-side when there's room (the
    // standalone dashboard window), stacked when narrow (the slide-out companion
    // panel) — otherwise the two cards' fixed-width columns force a min width
    // wider than the panel, which swallows the content padding on both edges.
    @ViewBuilder
    private func breakdowns(_ a: DailyUsageArchive) -> some View {
        let byModel = DashboardBreakdown(title: L10n.usageDashboard.byModel,
                                         rows: DailyUsageStats.byModel(a), useProviderColor: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard(elevated: false)
        let byProvider = DashboardBreakdown(title: L10n.usageDashboard.byProvider,
                                            rows: DailyUsageStats.byProvider(a), useProviderColor: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .glassCard(elevated: false)
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { byModel; byProvider }
            VStack(spacing: 12) { byModel; byProvider }
        }
    }

    @ViewBuilder
    private func header(_ a: DailyUsageArchive) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.usageDashboard.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                CountUpNumber(value: animatedTokens,
                              font: .system(size: 33, weight: .medium, design: .default))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                Text("tokens")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(L10n.usageDashboard.scope)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
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
    @State private var archive: DailyUsageArchive?

    public init() {}

    // Heatmap cell metrics for the compact card; weeks are computed to fill width.
    private let cell: CGFloat = 11
    private let gap: CGFloat = 3
    private var rowHeight: CGFloat { 7 * cell + 6 * gap }

    public var body: some View {
        Button {
            // Slide the dashboard out to the LEFT of the popover (not a new window).
            DashboardPanelController.shared.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.usageDashboard.activity)
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let a = archive, !a.days.isEmpty {
                    // Fill the whole card width: pick as many weeks as fit.
                    GeometryReader { geo in
                        let weeks = max(12, Int((geo.size.width + gap) / (cell + gap)))
                        UsageHeatmapGrid(archive: a, weeks: weeks, cell: cell, gap: gap, showMonthLabels: false)
                    }
                    .frame(height: rowHeight)
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
