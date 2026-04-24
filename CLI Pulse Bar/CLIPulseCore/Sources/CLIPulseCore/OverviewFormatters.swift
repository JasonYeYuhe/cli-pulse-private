import Foundation
import SwiftUI

/// v1.9.7 P2-1: shared pure helpers for the Overview tab, extracted so iOS
/// and macOS don't drift. Logic lives here; platform-specific styling stays
/// in each tab view.
public enum OverviewFormatters {

    /// Map a utilization percentage (0-200+) to the card/ring color used
    /// across both Overview tabs. Reference thresholds:
    /// - ≥ 200%: purple (wildly over-quota)
    /// - ≥ 100%: blue   (at or past quota — subscription tier resetting)
    /// - ≥  50%: green  (healthy-busy)
    /// -  < 50%: gray   (idle / low)
    public static func utilizationColor(_ percent: Double) -> Color {
        switch percent {
        case 200...: return .purple
        case 100...: return .blue
        case 50...:  return .green
        default:     return .gray
        }
    }

    // Cached formatters — avoid allocating per call from a 12-cell timeline.
    //
    // `nonisolated(unsafe)` is safe here ONLY because each instance is
    // configuration-immutable after the initializer closure runs (no
    // subsequent property mutation anywhere), and Foundation's
    // `ISO8601DateFormatter.date(from:)` + `DateFormatter.string(from:)`
    // have been documented thread-safe for reads since iOS 7 / macOS 10.9.
    // Do not mutate `formatOptions` / `dateFormat` / timezone on these
    // statics post-init — if you need different settings, add another
    // `static let`, don't reconfigure these.
    nonisolated(unsafe) private static let isoFormatterFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoFormatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    nonisolated(unsafe) private static let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "ha"
        return f
    }()

    /// v1.10.7: minimum bar fraction given to providers with nonzero token
    /// usage but zero cost (free tiers, promo periods, or providers whose
    /// `estimated_cost_today` hasn't rolled up server-side yet). Keeps them
    /// visible in the cost-scaled Provider Usage bar without implying
    /// meaningful dollar activity. Raised here if the bar width changes.
    public static let minVisibleCostBarFraction: Double = 0.04

    /// v1.10.7: rank + filter the Provider Usage bars for the Overview card.
    ///
    /// Shared between iOS `iOSOverviewTab` and macOS `OverviewTab` to keep
    /// the two platforms' cards in sync. Behavior:
    ///
    /// 1. Drop rows where the provider is not in `enabledNames` (user-disabled
    ///    providers don't belong on the Overview).
    /// 2. Drop rows where both `usage == 0` and `estimated_cost == 0` — those
    ///    are "enabled but inactive today" and only contribute an empty track
    ///    to the card. The Providers tab still shows them.
    /// 3. Sort by `estimated_cost` descending, tie-break by `usage` descending,
    ///    then by provider name ascending so refresh cycles don't jitter ties.
    public static func rankedProviderBreakdown(
        _ breakdown: [ProviderBreakdown],
        enabledNames: Set<String>
    ) -> [ProviderBreakdown] {
        breakdown
            .filter { enabledNames.contains($0.provider) }
            .filter { $0.usage != 0 || $0.estimated_cost != 0 }
            .sorted { lhs, rhs in
                if lhs.estimated_cost != rhs.estimated_cost {
                    return lhs.estimated_cost > rhs.estimated_cost
                }
                if lhs.usage != rhs.usage {
                    return lhs.usage > rhs.usage
                }
                return lhs.provider < rhs.provider
            }
    }

    /// v1.10.7: compute the Provider Usage bar fraction for `provider`
    /// relative to the max cost in `ranked` (caller passes the already-
    /// filtered+sorted list from `rankedProviderBreakdown`).
    ///
    /// Scaling by cost is more honest than scaling by `usage` because
    /// `usage` semantics vary across providers (quota %, billable tokens,
    /// server-aggregated cache reads — see v1.10.7 investigation). Cost is
    /// the one cross-provider comparable metric.
    ///
    /// A provider with nonzero `usage` but zero `estimated_cost` (free tier,
    /// unreliable server cost) is given `minVisibleCostBarFraction` so it
    /// still renders — hiding it would misrepresent activity, but letting
    /// it compute to 0 would drop it behind the background track.
    public static func providerUsageBarFraction(
        _ provider: ProviderBreakdown,
        in ranked: [ProviderBreakdown]
    ) -> Double {
        let maxCost = ranked.map(\.estimated_cost).max() ?? 0
        if maxCost > 0, provider.estimated_cost > 0 {
            return min(1.0, provider.estimated_cost / maxCost)
        }
        if provider.usage > 0 {
            return minVisibleCostBarFraction
        }
        return 0
    }

    /// Convert an ISO-8601 timestamp to a short hour label like "3pm".
    /// Falls back to extracting the HH substring if parsing fails, then
    /// to the raw timestamp as last resort. Matches the behavior both
    /// macOS `OverviewTab.hourLabel` and iOS `iOSOverviewTab.hourLabel`
    /// were duplicating before v1.9.7.
    public static func hourLabel(_ timestamp: String) -> String {
        if let date = isoFormatterFractional.date(from: timestamp) {
            return hourFormatter.string(from: date).lowercased()
        }
        if let date = isoFormatterBasic.date(from: timestamp) {
            return hourFormatter.string(from: date).lowercased()
        }
        if timestamp.count >= 13 {
            let hourStart = timestamp.index(timestamp.startIndex, offsetBy: 11)
            let hourEnd = timestamp.index(hourStart, offsetBy: 2)
            return String(timestamp[hourStart..<hourEnd]) + "h"
        }
        return timestamp
    }
}
