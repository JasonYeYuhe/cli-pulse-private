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
