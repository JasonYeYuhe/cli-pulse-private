// DailyUsageStats — pure, unit-testable derivations over DailyUsageArchive
// (v1.40 PR-4). Mirrors the ProviderUsageHistory idiom: static funcs, explicit
// clock inputs (todayKey), no stored state. Heatmap intensity is COST-keyed vs
// the peak day — the token-monitor formula (MIT) that makes the grids read like
// the screenshots the owner likes.
//
// Streaks/peak/activeDays are computed over the retained daily tier (`days`);
// lifetime totals add the uncapped monthly tier (`months`).

import Foundation

public enum DailyUsageStats {

    // MARK: - Lifetime totals (days + months, no overlap by construction)

    public static func totalTokens(_ a: DailyUsageArchive) -> Int {
        a.days.values.reduce(0) { $0 + $1.tokens } + a.months.values.reduce(0) { $0 + $1.tokens }
    }

    public static func totalCost(_ a: DailyUsageArchive) -> Double {
        a.days.values.reduce(0) { $0 + $1.cost } + a.months.values.reduce(0) { $0 + $1.cost }
    }

    public static func totalMessages(_ a: DailyUsageArchive) -> Int {
        a.days.values.reduce(0) { $0 + $1.messages } + a.months.values.reduce(0) { $0 + $1.messages }
    }

    // MARK: - Windowed (over retained `days`)

    /// Days with any token activity.
    public static func activeDays(_ a: DailyUsageArchive) -> Int {
        a.days.values.reduce(0) { $0 + ($1.tokens > 0 ? 1 : 0) }
    }

    /// (dayKey, tokens) of the highest-token day, or nil if none.
    public static func peakDay(_ a: DailyUsageArchive) -> (day: String, tokens: Int)? {
        var best: (String, Int)?
        for (k, v) in a.days where v.tokens > 0 {
            if best == nil || v.tokens > best!.1 || (v.tokens == best!.1 && k > best!.0) {
                best = (k, v.tokens)
            }
        }
        return best.map { (day: $0.0, tokens: $0.1) }
    }

    /// Highest single-day COST — the heatmap intensity denominator.
    public static func peakDayCost(_ a: DailyUsageArchive) -> Double {
        a.days.values.reduce(0) { max($0, $1.cost) }
    }

    /// Model with the most tokens across retained days (ties: lexical for determinism).
    public static func favoriteModel(_ a: DailyUsageArchive) -> String? {
        var totals: [String: Int] = [:]
        for day in a.days.values {
            for (model, slice) in day.perModel { totals[model, default: 0] += slice.tokens }
        }
        return totals
            .filter { $0.value > 0 }
            .max { l, r in l.value != r.value ? l.value < r.value : l.key > r.key }?
            .key
    }

    // MARK: - Streaks (calendar-adjacent active days)

    /// Consecutive active days ending today (or yesterday, if today is unused).
    /// Returns 0 if neither today nor yesterday is active.
    public static func currentStreak(_ a: DailyUsageArchive, todayKey: String) -> Int {
        let anchor: String
        if isActive(a, todayKey) {
            anchor = todayKey
        } else if let y = previousDay(todayKey), isActive(a, y) {
            anchor = y
        } else {
            return 0
        }
        var count = 0
        var key: String? = anchor
        while let k = key, isActive(a, k) {
            count += 1
            key = previousDay(k)
        }
        return count
    }

    /// Longest run of calendar-consecutive active days anywhere in `days`.
    public static func longestStreak(_ a: DailyUsageArchive) -> Int {
        let active = Set(a.days.filter { $0.value.tokens > 0 }.keys)
        guard !active.isEmpty else { return 0 }
        var longest = 0
        for start in active {
            // Only count from run starts (previous day inactive) — O(n) overall.
            if let prev = previousDay(start), active.contains(prev) { continue }
            var length = 0
            var key: String? = start
            while let k = key, active.contains(k) {
                length += 1
                key = nextDay(k)
            }
            longest = max(longest, length)
        }
        return longest
    }

    // MARK: - Heatmap intensity (COST-keyed vs peak day) — token-monitor formula

    /// 0–4 intensity bucket for a cost relative to the peak-day cost.
    public static func intensity(cost: Double, peakCost: Double) -> Int {
        guard cost > 0, peakCost > 0 else { return 0 }
        let ratio = cost / peakCost
        if ratio >= 0.75 { return 4 }
        if ratio >= 0.5 { return 3 }
        if ratio >= 0.25 { return 2 }
        return 1
    }

    public static func intensity(_ a: DailyUsageArchive, dayKey: String, peakCost: Double? = nil) -> Int {
        let cost = a.days[dayKey]?.cost ?? 0
        return intensity(cost: cost, peakCost: peakCost ?? peakDayCost(a))
    }

    // MARK: - Breakdowns (top rows for the by-model / by-provider bars)

    public struct Breakdown: Sendable, Equatable {
        public let key: String
        public let tokens: Int
        public let cost: Double
        public init(key: String, tokens: Int, cost: Double) {
            self.key = key; self.tokens = tokens; self.cost = cost
        }
    }

    /// Per-model totals across retained days, sorted by tokens desc (ties: lexical).
    public static func byModel(_ a: DailyUsageArchive) -> [Breakdown] {
        var tok: [String: Int] = [:]
        var cst: [String: Double] = [:]
        for day in a.days.values {
            for (model, slice) in day.perModel { tok[model, default: 0] += slice.tokens; cst[model, default: 0] += slice.cost }
        }
        return sortedBreakdowns(tokens: tok, costs: cst)
    }

    /// Per-provider totals across retained days, sorted by tokens desc.
    public static func byProvider(_ a: DailyUsageArchive) -> [Breakdown] {
        var tok: [String: Int] = [:]
        var cst: [String: Double] = [:]
        for day in a.days.values {
            for (prov, slice) in day.perProvider { tok[prov, default: 0] += slice.tokens; cst[prov, default: 0] += slice.cost }
        }
        return sortedBreakdowns(tokens: tok, costs: cst)
    }

    private static func sortedBreakdowns(tokens: [String: Int], costs: [String: Double]) -> [Breakdown] {
        tokens.keys.map { Breakdown(key: $0, tokens: tokens[$0] ?? 0, cost: costs[$0] ?? 0) }
            .filter { $0.tokens > 0 || $0.cost > 0 }
            .sorted { l, r in l.tokens != r.tokens ? l.tokens > r.tokens : l.key < r.key }
    }

    // MARK: - Day-key calendar helpers (UTC, deterministic)

    private static func isActive(_ a: DailyUsageArchive, _ dayKey: String) -> Bool {
        (a.days[dayKey]?.tokens ?? 0) > 0
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The previous calendar day's key ("yyyy-MM-dd" → "yyyy-MM-dd"), or nil if unparseable.
    public static func previousDay(_ dayKey: String) -> String? { shift(dayKey, byDays: -1) }
    /// The next calendar day's key.
    public static func nextDay(_ dayKey: String) -> String? { shift(dayKey, byDays: 1) }

    /// Shifts a "yyyy-MM-dd" key by a whole number of days (TZ-agnostic string
    /// date-math: parse+format use the same fixed UTC calendar, so the result is
    /// purely a date-portion decrement/increment). nil if the key is unparseable.
    public static func shift(_ dayKey: String, byDays days: Int) -> String? {
        guard let date = keyFormatter.date(from: dayKey),
              let shifted = utcCalendar.date(byAdding: .day, value: days, to: date, wrappingComponents: false)
        else { return nil }
        return keyFormatter.string(from: shifted)
    }

    private static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    // MARK: - Heatmap grid helpers

    /// Today's key in the LOCAL calendar — matches the scanner's day-key basis
    /// (CostUsageScanner buckets by Calendar.current), so archive lookups line up.
    public static func localDayKey(_ date: Date = Date(), calendar: Calendar = .current) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    /// Weekday index of a key: 0 = Sunday … 6 = Saturday. nil if unparseable.
    public static func weekdayIndex(_ dayKey: String) -> Int? {
        guard let date = keyFormatter.date(from: dayKey) else { return nil }
        return utcCalendar.component(.weekday, from: date) - 1   // Calendar weekday is 1...7 (Sun=1)
    }

    /// `count` consecutive day keys starting at `start` (inclusive), ascending.
    public static func daySequence(startingAt start: String, count: Int) -> [String] {
        guard count > 0, keyFormatter.date(from: start) != nil else { return [] }
        var result: [String] = [start]
        result.reserveCapacity(count)
        var cur = start
        while result.count < count, let next = nextDay(cur) { result.append(next); cur = next }
        return result
    }

    /// GitHub-style heatmap columns for the `weeks` weeks ending in the week that
    /// contains `todayKey` (Sunday-start). Each inner array is one week of 7 keys
    /// (index 0 = Sunday). Keys AFTER `todayKey` are still returned (future cells)
    /// — the view renders them faint/empty. Empty if inputs are unparseable.
    public static func heatmapColumns(todayKey: String, weeks: Int) -> [[String]] {
        guard weeks > 0, let todayWeekday = weekdayIndex(todayKey) else { return [] }
        guard let lastSunday = shift(todayKey, byDays: -todayWeekday),
              let gridStart = shift(lastSunday, byDays: -(weeks - 1) * 7) else { return [] }
        let flat = daySequence(startingAt: gridStart, count: weeks * 7)
        guard flat.count == weeks * 7 else { return [] }
        return stride(from: 0, to: flat.count, by: 7).map { Array(flat[$0 ..< $0 + 7]) }
    }
}
