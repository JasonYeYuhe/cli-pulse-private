import Foundation

/// v1.10 P2-6: centralized date-window helpers. Eliminates the scattered
/// `cal.date(byAdding: .day, value: -6, to: now)` pattern that previously
/// lived in three places and was the root of an off-by-one regression
/// (the rolling-week window accidentally spanned 8 calendar days when
/// someone used `-7` thinking inclusive math).
///
/// Convention for every helper here:
/// - The **rolling week** is today + the previous 6 calendar days = 7 days.
/// - The **rolling month** is today + the previous 29 calendar days = 30 days.
/// - `rollingWeekStart` / `rollingMonthStart` return the same HH:MM:SS clock
///   moment as the supplied `now`, just shifted back in whole days. Callers
///   that only need a calendar-day key should use `rollingWeekStartYMD`,
///   which formats via `ymd(...)` and discards the time component. All
///   current production callers compare via YMD strings.
public enum DateRange {

    /// Calendar-day YMD string like "2026-04-21" used as scan-result keys.
    public static func ymd(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }

    /// Earliest inclusive date in a rolling-week window anchored at `now`.
    /// Returns `now - 6 days` (same calendar day moment as `now`). Equivalent
    /// to `now - 6 days` so a `>=` comparison against `ymd(cutoff)` yields 7
    /// calendar days total.
    public static func rollingWeekStart(from now: Date,
                                        calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -6, to: now)
    }

    /// YMD key of the rolling-week start (falls back to today's key if the
    /// calendar arithmetic fails, matching the pre-extraction behavior).
    public static func rollingWeekStartYMD(from now: Date,
                                           calendar: Calendar = .current) -> String {
        if let cutoff = rollingWeekStart(from: now, calendar: calendar) {
            return ymd(cutoff, calendar: calendar)
        }
        return ymd(now, calendar: calendar)
    }

    /// Earliest inclusive date in a rolling-month (30-day) window.
    public static func rollingMonthStart(from now: Date,
                                         calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .day, value: -29, to: now)
    }
}
