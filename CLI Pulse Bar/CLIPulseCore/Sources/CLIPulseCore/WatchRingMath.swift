import Foundation

/// Pure quota-window math for the watchOS redesign's Quota rings page and
/// Pulse-home glance. Lives in CLIPulseCore so it is exercised by
/// `swift test` (the watch app target cannot be built or run locally —
/// CI is the only compile path), keeping the app-target SwiftUI thin.
///
/// **Single source of truth (review R4).** The ring's *fill* is always
/// `ProviderUsage.usagePercent` — the exact property the watch-face
/// complication reads. This type never re-derives that percentage; it
/// only wraps the surrounding window-used / remaining helpers and the
/// colour-threshold tiers so the rings, the legacy gauges, and the
/// complication can never disagree.
///
/// **Window math (review R6).** "Used" is window consumption
/// (`quota - remaining`), NOT `today_usage` — `today_usage` is 0 when
/// the user hasn't run anything yet today even though the rolling window
/// may be 28% consumed. This mirrors the established
/// `WatchProviderCard.displayedUsage` / `WatchProviderGauge.windowUsed`
/// logic, extracted here so there is one definition instead of three.
public enum WatchRingMath {

    /// Window-consumption "used" count for a provider.
    ///
    /// When a quota window is present, this is `max(0, quota - remaining)`
    /// — what's been consumed in the current rolling window. With no
    /// quota window we fall back to `today_usage`, which is the only
    /// usage figure available for unmetered providers.
    public static func windowUsed(quota: Int?, remaining: Int?, todayUsage: Int) -> Int {
        if let quota, let remaining {
            return max(0, quota - remaining)
        }
        return todayUsage
    }

    /// Remaining fraction in `0...1`, derived from the canonical
    /// `usagePercent`. `usagePercent` is consumption; remaining is its
    /// complement. Clamped so a momentarily out-of-range input can never
    /// produce a negative arc.
    public static func remainingFraction(usagePercent: Double) -> Double {
        (1.0 - usagePercent).clamped(to: 0...1)
    }

    /// Remaining percent as an integer `0...100` for the ring centre
    /// label ("38%"). Uses the same rounding as the complication
    /// (`Int(remaining * 100)`, i.e. truncation) so the two surfaces
    /// always show the identical number for the same provider.
    public static func remainingPercentInt(usagePercent: Double) -> Int {
        Int(remainingFraction(usagePercent: usagePercent) * 100)
    }

    // MARK: - Threshold tiers

    /// Colour tier for a consumption fraction. The boundaries match the
    /// shipped gauge/card thresholds exactly (`> 0.9` red, `> 0.7`
    /// amber) so migrating the existing views onto this helper introduces
    /// zero behavioural change at the boundary (review R6 — reuse
    /// existing thresholds).
    public enum RingTier: String, Sendable, Equatable {
        case normal
        case warning
        case critical
    }

    public static func tier(usagePercent: Double) -> RingTier {
        if usagePercent > 0.9 { return .critical }
        if usagePercent > 0.7 { return .warning }
        return .normal
    }

    // MARK: - Ring selection

    /// The providers that earn a concentric ring on the Quota page.
    ///
    /// Only providers with a real quota window can render a meaningful
    /// ring (no quota → `usagePercent == 0` → an empty ring that says
    /// nothing), so unmetered providers are filtered out here and shown
    /// in the legend only. The survivors are ordered **most-constrained
    /// first** (highest `usagePercent`) and capped at `limit` (default 3)
    /// for legibility at 41/45/49 mm — the rest fall through to the
    /// legend (review note: cap concentric rings at 3).
    ///
    /// The sort is deterministic: ties on `usagePercent` break on
    /// `provider` name so the ring order is stable across refreshes.
    public static func ringProviders(_ providers: [ProviderUsage], limit: Int = 3) -> [ProviderUsage] {
        let metered = providers.filter { $0.quota != nil }
        let sorted = metered.sorted { a, b in
            if a.usagePercent != b.usagePercent {
                return a.usagePercent > b.usagePercent
            }
            return a.provider < b.provider
        }
        return Array(sorted.prefix(max(0, limit)))
    }

    /// Index of the most-constrained entry (highest `usagePercent`) in a
    /// list of consumption fractions, or `nil` for an empty list. Drives
    /// the ring-cluster centre label ("Claude left"). Ties resolve to the
    /// lowest index so the centre is stable when two providers are level.
    public static func indexOfMostConstrained(_ usagePercents: [Double]) -> Int? {
        guard !usagePercents.isEmpty else { return nil }
        var best = 0
        for i in usagePercents.indices where usagePercents[i] > usagePercents[best] {
            best = i
        }
        return best
    }
}
