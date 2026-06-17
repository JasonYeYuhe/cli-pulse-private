import Foundation

/// v1.30 F3 — shapes raw `[DailyUsage]` rows (per provider / date / model,
/// from `APIClient.fetchDailyUsage`) into a per-provider, per-day series for
/// the usage-history chart.
///
/// Aggregates across models, fills missing days with zero so the chart is a
/// contiguous histogram, and bounds to the most recent N days. Pure
/// Foundation + `Calendar` (swift-testable); the chart view (iOS/macOS,
/// CI-only) just renders the result. Day keys are local `"yyyy-MM-dd"` strings,
/// matching `APIClient.localTodayKey`. Cross-platform: the cloud `[DailyUsage]`
/// is the source on every platform; the macOS local scan can enrich the same
/// shape but isn't required (the review's C5 fix — the macOS-only
/// `CostUsageScanResult` is NOT the chart's data source).
public enum ProviderUsageHistory {

    public struct DayPoint: Identifiable, Sendable, Equatable {
        public let dateKey: String      // local "yyyy-MM-dd"
        public let inputTokens: Int
        public let outputTokens: Int
        public let cachedTokens: Int
        public let cost: Double

        public var id: String { dateKey }
        /// Input + output, excluding cache reads — matches the "I/O" figure the
        /// provider cards already display.
        public var ioTokens: Int { inputTokens + outputTokens }
        public var totalTokens: Int { inputTokens + outputTokens + cachedTokens }

        public init(dateKey: String, inputTokens: Int, outputTokens: Int, cachedTokens: Int, cost: Double) {
            self.dateKey = dateKey
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cachedTokens = cachedTokens
            self.cost = cost
        }
    }

    /// Build the series for `provider` over the most recent `days` calendar days
    /// ending at `todayKey` (inclusive), oldest → newest. Days with no data are
    /// emitted as all-zero points so the histogram stays contiguous.
    public static func series(
        from daily: [DailyUsage],
        provider: String,
        days: Int = 30,
        todayKey: String,
        calendar: Calendar = .current) -> [DayPoint]
    {
        guard days > 0 else { return [] }

        // 1) aggregate this provider's rows by date key (across all models)
        var byDay: [String: Agg] = [:]
        for row in daily where row.provider == provider {
            var agg = byDay[row.date] ?? Agg()
            agg.input  += row.inputTokens
            agg.output += row.outputTokens
            agg.cached += row.cachedTokens
            agg.cost   += row.cost
            byDay[row.date] = agg
        }

        // 2) contiguous day window ending at todayKey
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.timeZone = calendar.timeZone
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd"

        guard let today = fmt.date(from: todayKey) else {
            // Unparseable today key: degrade to the present rows in date order,
            // no gap fill (still correct, just not contiguous).
            return byDay.keys.sorted().map { point($0, byDay[$0]) }
        }

        var points: [DayPoint] = []
        points.reserveCapacity(days)
        for offset in stride(from: days - 1, through: 0, by: -1) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = fmt.string(from: day)
            points.append(point(key, byDay[key]))
        }
        return points
    }

    private struct Agg { var input = 0; var output = 0; var cached = 0; var cost = 0.0 }

    private static func point(_ key: String, _ agg: Agg?) -> DayPoint {
        DayPoint(dateKey: key,
                 inputTokens: agg?.input ?? 0,
                 outputTokens: agg?.output ?? 0,
                 cachedTokens: agg?.cached ?? 0,
                 cost: agg?.cost ?? 0)
    }
}
