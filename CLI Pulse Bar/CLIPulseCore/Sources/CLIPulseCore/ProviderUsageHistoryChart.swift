#if !os(watchOS)
import Charts
import SwiftUI

/// v1.30 F3 — per-provider daily usage history (I/O tokens) as a bar chart.
/// macOS + iOS only (Swift `Charts`; the watch has no daily-scan data). Feed it
/// the output of `ProviderUsageHistory.series(...)` (already gap-filled +
/// bounded); the view stays dumb and just renders. Empty/zero history shows a
/// compact "no data" state rather than a flat zero axis.
@available(iOS 16.0, macOS 13.0, *)
public struct ProviderUsageHistoryChart: View {
    public let points: [ProviderUsageHistory.DayPoint]
    public let accent: Color

    public init(points: [ProviderUsageHistory.DayPoint], accent: Color) {
        self.points = points
        self.accent = accent
    }

    private var hasData: Bool { points.contains { $0.ioTokens > 0 } }

    public var body: some View {
        if !hasData {
            Text(L10n.widget.noData)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
        } else {
            Chart(points) { p in
                BarMark(
                    x: .value("Day", p.dateKey),
                    y: .value("Tokens", p.ioTokens)
                )
                .foregroundStyle(accent.gradient)
                .cornerRadius(1.5)
            }
            // 30 daily buckets → hide the dense x-axis; the surrounding section
            // header conveys the "last N days" range. Keep a sparse, abbreviated
            // token y-axis (K/M) so magnitudes stay legible.
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine()
                    // Charts numeric axes are Double-backed even for Int data,
                    // so read Double then abbreviate (K/M) — reading Int can be nil.
                    if let tokens = value.as(Double.self) {
                        AxisValueLabel {
                            Text(CostFormatter.formatUsage(Int(tokens)))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 90)
        }
    }
}
#endif
