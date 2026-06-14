import SwiftUI
import CLIPulseCore

/// Design tokens for the watchOS "vital-signs monitor" redesign.
///
/// These are *presentation* constants only — radii, ring widths, fonts,
/// and the brand-chrome colours pulled from the mockup. Colour *sources*
/// (provider colours, severity, accent) stay in `PulseTheme` inside
/// CLIPulseCore so there is a single source of truth; this enum only
/// references them and never forks the palette.
enum WatchTheme {

    // MARK: - Canvas

    /// True-black OLED canvas (power + contrast). Mirrors
    /// `PulseTheme.background` on watchOS, named here for call-site clarity.
    static let canvas = Color.black

    // MARK: - Cards

    /// Card fill — `rgba(255,255,255,0.06)` from the mockup. Subtle lift
    /// off the true-black canvas without a visible border.
    static let cardFill = Color.white.opacity(0.06)
    /// Slightly brighter fill for the featured (running / critical) card.
    static let cardFillStrong = Color.white.opacity(0.09)
    static let cardRadius: CGFloat = 12
    static let chipRadius: CGFloat = 11

    // MARK: - Rings

    /// Concentric quota-ring stroke width and inter-ring gap (45 mm base;
    /// scales acceptably to 41/49 mm because the cluster sizes off the
    /// available width, never a fixed height — review R1).
    static let ringWidth: CGFloat = 9
    static let ringGap: CGFloat = 4
    /// Opacity of a ring's unfilled track.
    static let ringTrackOpacity: Double = 0.18

    // MARK: - Waveform (signature ECG pulse)

    /// Dim baseline trace drawn under the bright animated stroke (and the
    /// *only* trace shown under reduce-motion / Always-On — review R3).
    static let waveformBaseOpacity: Double = 0.28
    static let waveformBaseWidth: CGFloat = 1.5
    static let waveformGlowWidth: CGFloat = 2.4
    /// Brighter blue for the moving stroke, a touch lighter than `accent`.
    static let waveformGlow = Color(red: 0.48, green: 0.63, blue: 1.0) // #7BA0FF

    // MARK: - Typography

    /// Hero metric — large rounded monospaced digits. The view wraps this
    /// in `ViewThatFits` (review R2) so verbose locales / big numbers
    /// abbreviate or wrap instead of truncating.
    static func heroFont(size: CGFloat = 34) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }
    /// Secondary numbers — monospaced for column alignment.
    static func monoNumber(size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }

    // MARK: - Tier → colour

    /// Map a `WatchRingMath.RingTier` to its semantic colour, layered over
    /// the provider's own colour. Centralised here so rings, gauges, and
    /// percent labels share one mapping.
    static func tierColor(_ tier: WatchRingMath.RingTier, base: Color) -> Color {
        switch tier {
        case .critical: return .red
        case .warning: return .orange
        case .normal: return base
        }
    }
}
