import SwiftUI

/// v1.10 P2-1: shared renderer for the Overview "Activity Timeline" card's
/// bars-and-labels body. Each platform wraps this in its own header /
/// background / padding, since those vary. Keeping the pure rendering
/// body in one place eliminates the ~20 lines of duplicated geometry
/// math + formatter calls that previously drifted between macOS and iOS.
public struct ActivityTimelineChart: View {

    public struct Style: Sendable {
        public var barSpacing: CGFloat
        public var barCornerRadius: CGFloat
        public var minBarHeight: CGFloat
        public var chartHeight: CGFloat
        public var labelFont: Font

        public init(
            barSpacing: CGFloat,
            barCornerRadius: CGFloat,
            minBarHeight: CGFloat,
            chartHeight: CGFloat,
            labelFont: Font
        ) {
            self.barSpacing = barSpacing
            self.barCornerRadius = barCornerRadius
            self.minBarHeight = minBarHeight
            self.chartHeight = chartHeight
            self.labelFont = labelFont
        }

        /// Tight, inline-menubar look: 1px bars, 40px chart.
        public static let macOS = Style(
            barSpacing: 1, barCornerRadius: 1,
            minBarHeight: 1, chartHeight: 40,
            labelFont: .system(size: 7)
        )

        /// Touch-target-friendly: 2px bars, 60px chart.
        public static let iOS = Style(
            barSpacing: 2, barCornerRadius: 2,
            minBarHeight: 2, chartHeight: 60,
            labelFont: .caption2
        )
    }

    private let trend: [UsagePoint]
    private let style: Style

    public init(trend: [UsagePoint], style: Style) {
        self.trend = trend
        self.style = style
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let maxValue = trend.map(\.value).max() ?? 1
            let barCount = trend.count

            GeometryReader { geometry in
                let totalSpacing = style.barSpacing * CGFloat(max(barCount - 1, 0))
                let barWidth = barCount > 0
                    ? (geometry.size.width - totalSpacing) / CGFloat(barCount)
                    : 0

                HStack(alignment: .bottom, spacing: style.barSpacing) {
                    ForEach(Array(trend.enumerated()), id: \.element.id) { _, point in
                        let fraction = maxValue > 0 ? CGFloat(point.value) / CGFloat(maxValue) : 0
                        RoundedRectangle(cornerRadius: style.barCornerRadius)
                            .fill(PulseTheme.accent.opacity(0.4 + 0.6 * fraction))
                            .frame(
                                width: max(barWidth, 1),
                                height: max(fraction * geometry.size.height, style.minBarHeight)
                            )
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: style.chartHeight)

            // Hour labels: first, optionally middle, last.
            if trend.count >= 2 {
                HStack {
                    Text(OverviewFormatters.hourLabel(trend.first?.timestamp ?? ""))
                        .font(style.labelFont)
                        .foregroundStyle(.quaternary)
                    Spacer()
                    if trend.count > 2 {
                        Text(OverviewFormatters.hourLabel(trend[trend.count / 2].timestamp))
                            .font(style.labelFont)
                            .foregroundStyle(.quaternary)
                        Spacer()
                    }
                    Text(OverviewFormatters.hourLabel(trend.last?.timestamp ?? ""))
                        .font(style.labelFont)
                        .foregroundStyle(.quaternary)
                }
            }
        }
    }
}
