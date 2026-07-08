import SwiftUI

// MARK: - Theme

public enum PulseTheme {
    public static let accent = Color(red: 0.36, green: 0.51, blue: 1.0)
    public static let secondaryAccent = Color(red: 0.58, green: 0.39, blue: 0.98)
    #if os(macOS)
    public static let background = Color(nsColor: .windowBackgroundColor)
    public static let cardBackground = Color(nsColor: .controlBackgroundColor)
    #elseif os(watchOS)
    public static let background = Color.black
    public static let cardBackground = Color(white: 0.15)
    #else
    public static let background = Color(uiColor: .systemBackground)
    public static let cardBackground = Color(uiColor: .secondarySystemBackground)
    #endif
    public static let dimText = Color.secondary

    /// Per-provider accent color. v1.40 PR-6: backfilled so NO provider falls to
    /// gray (was invisible on dark glass), key brands aligned to the token-monitor
    /// vendor table, and every color passed through a luminance-lift so near-black
    /// brands (Grok/Moonshot/etc.) stay visible on the frosted-glass panels.
    ///
    /// token-monitor (javis603/token-monitor, MIT) vendor palette + lift formula.
    public static func providerColor(_ provider: String) -> Color {
        liftForDarkGlass(rawProviderRGB(provider))
    }

    private static func rawProviderRGB(_ provider: String) -> (r: Double, g: Double, b: Double) {
        switch provider {
        // token-monitor canonical brands
        case "Claude": return rgb(0xCC7C5E)
        case "Codex": return rgb(0x49A3B0)
        case "Gemini", "Vertex AI": return rgb(0x4285F4)
        case "DeepSeek": return rgb(0x4D6BFE)
        case "Kiro": return rgb(0x9046FF)
        case "MiniMax": return rgb(0xF23F5D)
        case "Alibaba", "Alibaba Token Plan": return rgb(0x615CED)   // Qwen
        case "Volcano Engine": return rgb(0x006EFF)
        // Existing tuned brands (kept)
        case "Cursor": return rgb(0x66CC66)
        case "OpenCode", "OpenCode Go": return rgb(0x8080CC)
        case "Droid": return rgb(0xB366B3)
        case "Antigravity": return rgb(0xD9598C)
        case "Copilot": return rgb(0x4DB3E6)
        case "z.ai": return rgb(0xF29A1A)
        case "Augment": return rgb(0x40BF8C)
        case "JetBrains AI": return rgb(0xF24D80)
        case "Kimi", "Kimi K2": return rgb(0x5A8CF2)
        case "Amp": return rgb(0xE6BF33)
        case "Synthetic": return rgb(0x8C73D9)
        case "Warp": return rgb(0x33CCCC)
        case "Kilo": return rgb(0xBF8C59)
        case "OpenRouter": return rgb(0x33A6E6)
        case "Ollama": return rgb(0x4DCCA6)
        case "Crof": return rgb(0x73B3F2)
        case "ElevenLabs": return rgb(0x268C8C)
        case "Venice": return rgb(0xA659D9)
        case "Perplexity": return rgb(0x1AC0C0)
        // Backfilled (were gray)
        case "GLM": return rgb(0x3859FF)
        case "Grok": return rgb(0x1A1A1A)          // xAI black → lifted
        case "Moonshot", "MiMo": return rgb(0x16182D)   // dark navy → lifted
        case "Groq": return rgb(0xF55036)
        case "Mistral": return rgb(0xFA5310)
        case "Poe": return rgb(0x6B4EFF)
        case "CrossModel": return rgb(0x00B8A9)
        case "Chutes": return rgb(0x2ADB5C)
        case "Qoder": return rgb(0x7C5CFF)
        case "Sakana AI": return rgb(0x2B6CB0)
        case "Zed": return rgb(0x1E6FFF)
        case "OpenAI Admin": return rgb(0x10A37F)
        case "Azure OpenAI": return rgb(0x0078D4)
        case "Deepgram": return rgb(0x13EF93)
        case "AWS Bedrock": return rgb(0xFF9900)
        case "Windsurf": return rgb(0x58A65C)
        // Everything else → token-monitor default blue (never gray)
        default: return rgb(0x6AB4F0)
        }
    }

    /// Hex (0xRRGGBB) → normalized sRGB tuple.
    private static func rgb(_ hex: UInt) -> (r: Double, g: Double, b: Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    /// token-monitor's near-black lift: if perceived luminance < 42 (of 255),
    /// lift each channel 62% of the way toward 205 so the brand stays legible on
    /// the dark frosted-glass panels. A no-op for already-bright colors.
    static func liftForDarkGlass(_ c: (r: Double, g: Double, b: Double)) -> Color {
        let l = liftedRGB(c)
        return Color(.sRGB, red: l.r, green: l.g, blue: l.b, opacity: 1)
    }

    /// Pure lift math (0…1 sRGB in/out), extracted for testing.
    static func liftedRGB(_ c: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let r = c.r * 255, g = c.g * 255, b = c.b * 255
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        func adj(_ x: Double) -> Double { lum < 42 ? x + (205 - x) * 0.62 : x }
        return (adj(r) / 255, adj(g) / 255, adj(b) / 255)
    }

    /// Test seam: the raw (pre-lift) sRGB tuple for a provider.
    static func rawProviderRGBForTesting(_ provider: String) -> (r: Double, g: Double, b: Double) {
        rawProviderRGB(provider)
    }

    public static func severityColor(_ severity: String) -> Color {
        switch severity {
        case "Critical": return .red
        case "Warning": return .orange
        case "Info": return .blue
        default: return .gray
        }
    }

    public static func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running": return .green
        case "idle": return .orange
        case "failed": return .red
        case "syncing": return .blue
        case "online": return .green
        case "degraded": return .orange
        case "offline": return .red
        case "operational": return .green
        case "down": return .red
        default: return .gray
        }
    }
}

// MARK: - 毛玻璃 Glass (v1.40 PR-6)

/// The frosted-glass card recipe extracted from javis603/token-monitor (MIT):
/// `.ultraThinMaterial` base → tint → two gradient washes → hairline → top sheen
/// → soft shadow. Scheme-aware (the token-monitor constants are the dark theme;
/// a lighter tint is used in light mode so cards don't go dark-on-light).
///
/// Deliberately does NOT use the macOS 26 `glassEffect` Liquid Glass APIs — CI
/// runs macos-15 / Xcode 16 runners that cannot compile that SDK symbol.
public struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var cornerRadius: CGFloat = 14
    var elevated: Bool = true

    public init(cornerRadius: CGFloat = 14, elevated: Bool = true) {
        self.cornerRadius = cornerRadius
        self.elevated = elevated
    }

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var isDark: Bool { scheme == .dark }

    private var tint: Color {
        // v1.40: more transparent (owner: 更透明, token-monitor style) — lower the
        // tint opacity so more of the frosted backdrop shows through.
        isDark ? Color(.sRGB, red: 48 / 255, green: 52 / 255, blue: 56 / 255, opacity: 0.46)
               : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.34)
    }
    private var verticalWash: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(isDark ? 0.06 : 0.32),
                                Color.white.opacity(isDark ? 0.02 : 0.12)],
                       startPoint: .top, endPoint: .bottom)
    }
    private var diagonalWash: LinearGradient {
        LinearGradient(colors: [Color.white.opacity(isDark ? 0.035 : 0.12),
                                Color.black.opacity(isDark ? 0.09 : 0.05)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var hairline: Color { isDark ? Color.white.opacity(0.238) : Color.black.opacity(0.08) }
    private var sheen: Color { Color.white.opacity(isDark ? 0.08 : 0.5) }

    public func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(tint)
                    shape.fill(verticalWash)
                    shape.fill(diagonalWash)
                }
            )
            .overlay(alignment: .top) {
                shape.fill(
                    LinearGradient(colors: [sheen, .clear],
                                   startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.36)))
                    .allowsHitTesting(false)
            }
            .overlay(shape.strokeBorder(hairline, lineWidth: 1))
            .clipShape(shape)
            .shadow(color: Color.black.opacity(elevated ? 0.36 : 0.18),
                    radius: elevated ? 22 : 10, x: 0, y: elevated ? 16 : 6)
    }
}

public extension View {
    /// Applies the v1.40 毛玻璃 frosted-glass card treatment. See `GlassCardModifier`.
    func glassCard(cornerRadius: CGFloat = 14, elevated: Bool = true) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}

// MARK: - Count-up number (glass headline)

/// A number that animates up to `value` (Animatable drives the interpolation).
/// Used for the dashboard's 46pt en-US-grouped headline. Drive the reveal with a
/// `withAnimation(.timingCurve(...))` change of the bound value.
public struct CountUpNumber: View, Animatable {
    public var value: Double
    public var animatableData: Double {
        get { value }
        set { value = newValue }
    }
    private let font: Font

    public init(value: Double, font: Font) {
        self.value = value
        self.font = font
    }

    public var body: some View {
        Text(Self.grouped(Int(value.rounded())))
            .font(font)
            .monospacedDigit()
    }

    /// easeOutQuart timing curve (token-monitor's 2.2s count-up feel).
    public static let countUpAnimation: Animation = .timingCurve(0.165, 0.84, 0.44, 1.0, duration: 2.2)

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}

// MARK: - Usage Bar

/// A reference tick drawn on a `UsageBar`, positioned in the SAME fill
/// coordinate as the bar's `value` (0 = left/empty end, 1 = right/full end).
/// Callers orient the position via `QuotaBarMarkers.place(_:onRemainingBar:)`
/// so a "90% used" marker lands at the empty end of a remaining/countdown bar.
public struct BarMarker: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable { case pace, threshold }
    public let position: Double   // 0...1, bar fill coordinate
    public let kind: Kind
    public var id: String { "\(kind)-\(position)" }
    public init(position: Double, kind: Kind) {
        self.position = min(1, max(0, position))
        self.kind = kind
    }
}

public struct UsageBar: View {
    public let label: String
    public let value: Double
    public let color: Color
    public let detail: String?
    public let markers: [BarMarker]

    public init(label: String, value: Double, color: Color, detail: String? = nil, markers: [BarMarker] = []) {
        self.label = label
        self.value = min(1.0, max(0, value))
        self.color = color
        self.detail = detail
        self.markers = markers
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if let detail {
                    Text(detail)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * value), height: 6)
                    // v1.30 F2 — reference ticks (expected pace / warning
                    // thresholds). Positions are already in this bar's fill
                    // coordinate (oriented by QuotaBarMarkers.place).
                    ForEach(markers) { m in
                        let w: CGFloat = m.kind == .pace ? 2 : 1
                        Rectangle()
                            .fill(m.kind == .pace ? Color.primary.opacity(0.6) : Color.secondary.opacity(0.4))
                            .frame(width: w, height: 6)
                            // Centre on the position, then clamp so an extreme
                            // (≈0 or ≈1) marker stays fully inside the bar
                            // instead of being half-clipped at an edge.
                            .offset(x: min(max(0, geo.size.width * m.position - w / 2), max(0, geo.size.width - w)))
                    }
                }
            }
            .frame(height: 6)
        }
        // v1.10 P3-3: entirely replace VoiceOver readout with label + detail
        // rather than letting SwiftUI read the two overlay rectangles + two
        // text runs separately. Use `.ignore` (not `.combine`) because we're
        // fully specifying label and value — combining would be redundant.
        // The numeric `value` parameter has inconsistent semantics across
        // call sites (some pass "remaining" 0..1, others pass "used" 0..1),
        // so we do NOT compute a percentage from it — `detail` already
        // carries the caller-formatted summary (e.g. "15% left" or
        // "17k remaining").
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(detail ?? "")
    }
}

// MARK: - Metric Card

public struct MetricCard: View {
    public let title: String
    public let value: String
    public let subtitle: String?
    public let icon: String
    public let color: Color

    public init(title: String, value: String, subtitle: String? = nil, icon: String, color: Color = PulseTheme.accent) {
        self.title = title
        self.value = value
        self.subtitle = subtitle
        self.icon = icon
        self.color = color
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Status Badge

public struct StatusBadge: View {
    public let text: String
    public let color: Color

    public init(text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Severity Dot

public struct SeverityDot: View {
    public let severity: String

    public init(severity: String) {
        self.severity = severity
    }

    public var body: some View {
        Circle()
            .fill(PulseTheme.severityColor(severity))
            .frame(width: 8, height: 8)
    }
}

// MARK: - Section Header

public struct SectionHeader: View {
    public let title: String
    public let icon: String

    public init(title: String, icon: String) {
        self.title = title
        self.icon = icon
    }

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PulseTheme.accent)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
        .padding(.bottom, 2)
    }
}

// MARK: - Empty State

public struct EmptyStateView: View {
    public let icon: String
    public let title: String
    public let subtitle: String

    public init(icon: String, title: String, subtitle: String) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

// MARK: - Subscription Badge

public struct SubscriptionBadge: View {
    public let tier: SubscriptionTier

    public init(tier: SubscriptionTier) {
        self.tier = tier
    }

    private var label: String {
        switch tier {
        case .free: return L10n.badge.free
        case .pro: return L10n.badge.pro
        case .team: return L10n.badge.team
        }
    }

    private var color: Color {
        switch tier {
        case .free: return .gray
        case .pro: return PulseTheme.accent
        case .team: return PulseTheme.secondaryAccent
        }
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Cost Status Badge

public struct CostStatusBadge: View {
    public let status: String

    public init(status: String) {
        self.status = status
    }

    private var label: String {
        switch status {
        case "Exact": return L10n.badge.exact
        case "Estimated": return L10n.badge.estimated
        case "Unavailable": return L10n.badge.unavailable
        default: return status.uppercased()
        }
    }

    private var color: Color {
        switch status {
        case "Exact": return .green
        case "Estimated": return .orange
        case "Unavailable": return .gray
        default: return .gray
        }
    }

    public var body: some View {
        Text(label)
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Collection Confidence Badge

public struct ConfidenceBadge: View {
    public let confidence: String

    public init(confidence: String) {
        self.confidence = confidence
    }

    private var icon: String {
        switch confidence {
        case "high": return "checkmark.shield.fill"
        case "medium": return "shield.lefthalf.filled"
        case "low": return "questionmark.diamond"
        default: return "questionmark.diamond"
        }
    }

    private var color: Color {
        switch confidence {
        case "high": return .green
        case "medium": return .orange
        case "low": return .red
        default: return .gray
        }
    }

    private var localizedConfidence: String {
        switch confidence {
        case "high": return L10n.badge.high
        case "medium": return L10n.badge.medium
        case "low": return L10n.badge.low
        default: return confidence.capitalized
        }
    }

    public var body: some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(localizedConfidence)
                .font(.system(size: 8, weight: .medium))
        }
        .foregroundStyle(color)
    }
}

// MARK: - Category Badge

public struct CategoryBadge: View {
    public let category: String

    public init(category: String) {
        self.category = category
    }

    private var icon: String {
        switch category {
        case "cloud": return "cloud"
        case "local": return "desktopcomputer"
        case "aggregator": return "arrow.triangle.branch"
        case "ide": return "hammer"
        default: return "questionmark"
        }
    }

    private var label: String {
        switch category {
        case "cloud": return L10n.badge.cloud
        case "local": return L10n.badge.local
        case "aggregator": return L10n.badge.aggregator
        case "ide": return L10n.badge.ide
        default: return category.uppercased()
        }
    }

    public var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 8))
            Text(label)
                .font(.system(size: 7, weight: .semibold))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(PulseTheme.dimText.opacity(0.1))
        .foregroundStyle(.secondary)
        .clipShape(Capsule())
    }
}

// MARK: - Cost Formatter

public enum CostFormatter {
    /// Formats a USD cost in the user's chosen DISPLAY currency (v1.40 PR-7).
    /// Storage stays USD everywhere; conversion happens only here, at display
    /// time. Defaults to USD "$X.XX" / "<$0.01" when no other currency is chosen.
    public static func format(_ cost: Double) -> String {
        CurrencyConverter.shared.format(cost)
    }

    public static func formatUsage(_ usage: Int) -> String {
        if usage >= 1_000_000 { return String(format: "%.1fM", Double(usage) / 1_000_000) }
        if usage >= 1_000 { return String(format: "%.1fK", Double(usage) / 1_000) }
        return "\(usage)"
    }
}

// MARK: - Relative Time

public enum RelativeTime {
    // Dedicated formatters — must NOT use sharedISO8601Formatter because
    // mutating formatOptions on a shared instance causes nondeterministic parsing.
    nonisolated(unsafe) private static let formatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let formatterBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func format(_ isoString: String) -> String {
        guard let date = formatterWithFractional.date(from: isoString) ?? formatterBasic.date(from: isoString) else {
            return isoString
        }
        let interval = Date().timeIntervalSince(date)
        if interval >= 0 {
            // Past
            if interval < 60 { return L10n.time.justNow }
            let ago = L10n.time.ago
            if interval < 3600 { return "\(Int(interval / 60))m \(ago)" }
            if interval < 86400 { return "\(Int(interval / 3600))h \(ago)" }
            return "\(Int(interval / 86400))d \(ago)"
        } else {
            // Future (for reset times)
            let remaining = -interval
            if remaining < 60 { return "in <1m" }
            if remaining < 3600 { return "in \(Int(remaining / 60))m" }
            let hours = Int(remaining / 3600)
            let mins = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)
            if remaining < 86400 { return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h" }
            let days = Int(remaining / 86400)
            let remHours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
            return remHours > 0 ? "in \(days)d \(remHours)h" : "in \(days)d"
        }
    }

    /// Format reset times for quota windows.
    /// Reset timestamps should only be shown when they are in the future.
    public static func formatReset(_ isoString: String) -> String? {
        guard let date = formatterWithFractional.date(from: isoString) ?? formatterBasic.date(from: isoString) else {
            return nil
        }

        let interval = Date().timeIntervalSince(date)
        guard interval < 0 else { return nil }

        let totalMinutes = max(1, Int(ceil((-interval) / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let mins = totalMinutes % 60

        if days > 0 {
            return hours > 0 ? "in \(days)d \(hours)h" : "in \(days)d"
        }
        if hours > 0 {
            return mins > 0 ? "in \(hours)h \(mins)m" : "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }
}
