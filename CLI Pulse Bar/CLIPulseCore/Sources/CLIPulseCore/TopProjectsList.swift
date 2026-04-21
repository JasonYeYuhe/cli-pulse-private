import SwiftUI

/// v1.10 P2-1 slice 3: shared renderer for the Overview "Top Projects"
/// card body. Each platform wraps this in its own header + background;
/// the rows, empty state, and divider logic live here.
public struct TopProjectsList: View {

    public struct Style: Sendable {
        public var nameFont: Font
        public var amountFont: Font
        public var emptyFont: Font
        public var rowSpacing: CGFloat

        public init(nameFont: Font, amountFont: Font, emptyFont: Font, rowSpacing: CGFloat) {
            self.nameFont = nameFont
            self.amountFont = amountFont
            self.emptyFont = emptyFont
            self.rowSpacing = rowSpacing
        }

        /// Tight menubar typography: 11/10/10, monospaced digits in rows.
        public static let macOS = Style(
            nameFont: .system(size: 11, weight: .medium),
            amountFont: .system(size: 10, weight: .medium, design: .monospaced),
            emptyFont: .system(size: 10),
            rowSpacing: 2
        )

        /// iOS uses Dynamic Type sizes with monospaced digits for numbers.
        public static let iOS = Style(
            nameFont: .subheadline.weight(.medium),
            amountFont: .caption.monospacedDigit(),
            emptyFont: .caption,
            rowSpacing: 2
        )
    }

    private let projects: [TopProject]
    private let emptyText: String
    private let style: Style

    public init(projects: [TopProject], emptyText: String, style: Style) {
        self.projects = projects
        self.emptyText = emptyText
        self.style = style
    }

    public var body: some View {
        if projects.isEmpty {
            Text(emptyText)
                .font(style.emptyFont)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(projects) { project in
                HStack {
                    Text(project.name)
                        .font(style.nameFont)
                        .lineLimit(1)
                    Spacer()
                    Text(CostFormatter.formatUsage(project.usage))
                        .font(style.amountFont)
                        .foregroundStyle(.secondary)
                    Text(CostFormatter.format(project.estimated_cost))
                        .font(style.amountFont)
                        .foregroundStyle(.green)
                }
                .padding(.vertical, style.rowSpacing)
                if project.id != projects.last?.id {
                    Divider()
                }
            }
        }
    }
}
