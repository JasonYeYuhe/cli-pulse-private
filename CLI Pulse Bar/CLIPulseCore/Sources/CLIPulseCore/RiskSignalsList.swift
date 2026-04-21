import SwiftUI

/// v1.10 P2-1 slice 4: shared renderer for the Overview "Risk Signals"
/// warning list. Platform wrappers supply header + background; rows and
/// empty-case gating (only render when signals non-empty) live here.
public struct RiskSignalsList: View {

    public struct Style: Sendable {
        public var iconFont: Font
        public var textFont: Font
        public var hSpacing: CGFloat

        public init(iconFont: Font, textFont: Font, hSpacing: CGFloat) {
            self.iconFont = iconFont
            self.textFont = textFont
            self.hSpacing = hSpacing
        }

        public static let macOS = Style(
            iconFont: .system(size: 9),
            textFont: .system(size: 10),
            hSpacing: 6
        )

        public static let iOS = Style(
            iconFont: .caption2,
            textFont: .caption,
            hSpacing: 8
        )
    }

    private let signals: [String]
    private let style: Style

    public init(signals: [String], style: Style) {
        self.signals = signals
        self.style = style
    }

    public var body: some View {
        ForEach(signals, id: \.self) { signal in
            HStack(spacing: style.hSpacing) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(style.iconFont)
                    .foregroundStyle(.orange)
                Text(signal)
                    .font(style.textFont)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
