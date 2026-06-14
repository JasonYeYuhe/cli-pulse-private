import Foundation

/// Pure helpers for the watchOS Pulse-home glance. Lives in CLIPulseCore
/// so `swift test` exercises it (the watch app target is CI-only), keeping
/// the app-target SwiftUI thin per the redesign's testing strategy.
public enum WatchPulseFormat {

    /// Activity level in `0...1` that drives the signature ECG waveform's
    /// beat-rate and amplitude. Zero running sessions → a calm, slow
    /// baseline; the curve saturates at `saturateAt` running sessions so a
    /// busy fleet reads as a lively trace without growing unbounded.
    public static func activityLevel(activeSessions: Int, saturateAt: Int = 5) -> Double {
        guard saturateAt > 0 else { return activeSessions > 0 ? 1 : 0 }
        return (Double(max(0, activeSessions)) / Double(saturateAt)).clamped(to: 0...1)
    }

    /// Abbreviated cost string for the hero metric's `ViewThatFits` middle
    /// rung (review R2). Once the dollar figure is large enough that the
    /// cents no longer add glance value — and where the full `$146.03`
    /// would overflow a 41 mm width — we drop to a whole-dollar `$146`.
    /// Below `$10` the full two-decimal string is kept (cents matter at
    /// small amounts), delegating to `CostFormatter.format` so the
    /// `<$0.01` / 2-dp conventions stay identical to every other surface.
    public static func abbreviatedCost(_ cost: Double) -> String {
        if cost >= 10 {
            return "$\(Int(cost.rounded()))"
        }
        return CostFormatter.format(cost)
    }
}
