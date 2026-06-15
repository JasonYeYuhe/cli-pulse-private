import SwiftUI
import CLIPulseCore

// MARK: - Pulse Waveform (signature ECG)

/// The signature animated ECG pulse — the one memorable element of the
/// redesign. A `Canvas` draws a static ECG curve once; a brighter dashed
/// stroke flows along it (mirroring the mockup's `stroke-dashoffset`
/// animation) so a pulse appears to travel down the line. The shape's
/// geometry is constant per frame — only the dash phase changes — keeping
/// the per-frame draw cheap (review §7 — battery/perf).
///
/// **Degradation (review R3).** Motion runs ONLY when
/// `scenePhase == .active && !reduceMotion && !isLuminanceReduced`.
/// Under Always-On (`isLuminanceReduced`) or reduce-motion we render a
/// representative *still* low-opacity ECG curve — not a frozen animation
/// frame — and no `TimelineView` is installed, so nothing ticks.
struct PulseWaveform: View {
    /// 0 (idle) … 1 (busy) — modulates beat amplitude and flow speed.
    var activityLevel: Double

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var shouldAnimate: Bool {
        scenePhase == .active && !reduceMotion && !isLuminanceReduced
    }

    private var amplitude: CGFloat {
        0.55 + 0.45 * CGFloat(activityLevel.clamped(to: 0...1))
    }

    var body: some View {
        // GeometryReader computes the ECG path ONCE per layout/amplitude —
        // not per animation frame. The TimelineView nested below re-runs only
        // its Canvas closure each tick (changing the dash phase), capturing
        // the already-built `path`, so there is no per-frame path allocation.
        GeometryReader { geo in
            let path = Self.ecgPath(in: geo.size, amplitude: amplitude)
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: 0.08, paused: false)) { context in
                    Canvas { ctx, _ in
                        // Dim baseline trace.
                        ctx.stroke(
                            path,
                            with: .color(PulseTheme.accent.opacity(WatchTheme.waveformBaseOpacity)),
                            style: StrokeStyle(lineWidth: WatchTheme.waveformBaseWidth, lineCap: .round, lineJoin: .round)
                        )
                        // Bright pulse segment flowing along the same path.
                        let dashOn = geo.size.width * 0.18
                        let gap = geo.size.width * 1.30
                        let period = 2.2 / (0.6 + 0.8 * activityLevel.clamped(to: 0...1))
                        let frac = (context.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
                        let phase = CGFloat(frac) * (dashOn + gap)
                        ctx.stroke(
                            path,
                            with: .color(WatchTheme.waveformGlow),
                            style: StrokeStyle(
                                lineWidth: WatchTheme.waveformGlowWidth,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: [dashOn, gap],
                                dashPhase: -phase
                            )
                        )
                    }
                }
            } else {
                // Representative still curve — visible but calm (review R3).
                Canvas { ctx, _ in
                    ctx.stroke(
                        path,
                        with: .color(PulseTheme.accent.opacity(0.45)),
                        style: StrokeStyle(lineWidth: WatchTheme.waveformBaseWidth, lineCap: .round, lineJoin: .round)
                    )
                }
            }
        }
        .frame(height: 38)
        .accessibilityElement()
        .accessibilityLabel(L10n.watch.pulseLabel)
    }

    /// One ECG beat scaled into `size`. Vertices are fractions of width;
    /// deviations are fractions of half-height (+ = up), scaled by
    /// `amplitude`. Derived from the mockup path
    /// `M0 23 H40 l5 0 l4 -16 l6 32 l5 -22 l4 6 H184` (viewBox 184×46).
    static func ecgPath(in size: CGSize, amplitude: CGFloat) -> Path {
        let w = size.width
        let h = size.height
        let mid = h / 2
        let half = h / 2
        // (fractional-x, deviation-from-baseline in half-height units, +up)
        let vertices: [(CGFloat, CGFloat)] = [
            (0.0000, 0),
            (0.2174, 0),
            (0.2446, 0),
            (0.2663, 0.696),
            (0.2989, -0.696),
            (0.3261, 0.261),
            (0.3478, 0),
            (1.0000, 0),
        ]
        var path = Path()
        for (i, v) in vertices.enumerated() {
            let pt = CGPoint(x: v.0 * w, y: mid - v.1 * half * amplitude)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }
}

// MARK: - Big Metric (hero number, R2 ViewThatFits)

/// The hero metric in large rounded-mono digits. Uses `ViewThatFits`
/// (review R2) — full string → abbreviated → smaller — so big numbers and
/// verbose locales abbreviate instead of truncating. `minimumScaleFactor`
/// is only a last-resort safety on the final rung, never the primary
/// mechanism.
struct BigMetric: View {
    let full: String
    let abbreviated: String
    var color: Color = .primary

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(full)
                .font(WatchTheme.heroFont(size: 34))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(abbreviated)
                .font(WatchTheme.heroFont(size: 34))
                .foregroundStyle(color)
                .lineLimit(1)
            Text(abbreviated)
                .font(WatchTheme.heroFont(size: 26))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityLabel(full)
    }
}

// MARK: - Stat Chip

/// A compact, optionally-tappable stat pill (icon + mono value). When
/// `action` is set the chip jumps to another glance page; otherwise it is
/// a non-interactive stat (e.g. Devices, which has no dedicated page).
struct StatChip: View {
    let icon: String
    let value: String
    let tint: Color
    var emphasized: Bool = false
    let accessibilityText: String
    var action: (() -> Void)? = nil

    private var chipBody: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
            Text(value)
                .font(WatchTheme.monoNumber(size: 15))
                .foregroundStyle(emphasized ? tint : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(WatchTheme.cardFill, in: RoundedRectangle(cornerRadius: WatchTheme.chipRadius))
    }

    var body: some View {
        if let action {
            Button(action: action) { chipBody }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityText)
        } else {
            chipBody
                .accessibilityElement()
                .accessibilityLabel(accessibilityText)
        }
    }
}

// MARK: - Card container

/// True-black-friendly card surface (subtle white fill, rounded corners,
/// no border) used by the folded Pulse-home sections and elsewhere.
struct WatchCard<Content: View>: View {
    let strong: Bool
    let content: Content

    init(strong: Bool = false, @ViewBuilder content: () -> Content) {
        self.strong = strong
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                strong ? WatchTheme.cardFillStrong : WatchTheme.cardFill,
                in: RoundedRectangle(cornerRadius: WatchTheme.cardRadius)
            )
    }
}

// MARK: - Metric Row (shared by detail views)

/// Label / value row used by the provider & session detail views. Moved
/// here from the retired `WatchOverviewView` so it survives that file's
/// removal (P1 folds Overview into Pulse home).
struct WatchMetricRow: View {
    let label: String
    let value: String
    let icon: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true) // decorative; label+value carry it
            Text(label)
                .font(.caption)
            Spacer()
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(valueColor)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared load / error states

/// First-load spinner used by every glance page.
struct WatchLoadingState: View {
    var body: some View {
        ProgressView()
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
    }
}

/// Error + retry block shared by every glance page — surfaces the real
/// `lastError` (the silent-401 lesson) with a retry button.
struct WatchErrorState: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(message)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            Button(action: retry) {
                Label(L10n.watch.retry, systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Live Dot

/// A small "live" status dot. When motion is allowed it pulses via the
/// system `symbolEffect(.pulse)` — which is battery-managed and already
/// respects Reduce Motion — and we additionally gate `isActive` on
/// scene-active + not-Always-On so nothing pulses off-screen (review R3).
struct LiveDot: View {
    var size: CGFloat = 7
    var color: Color = .green

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var active: Bool {
        scenePhase == .active && !reduceMotion && !isLuminanceReduced
    }

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .symbolEffect(.pulse, isActive: active)
            .accessibilityHidden(true) // decorative; adjacent text carries the meaning
    }
}
