import Foundation

/// v1.30 F2 — reference markers overlaid on a quota bar:
///   • the **expected-pace** position (where an even burn rate would put you,
///     from the shared `UsagePace` engine), and
///   • the configured **warning thresholds** (e.g. 80% / 95%).
///
/// All fractions are returned in **as-used orientation** (0 = empty, 1 = fully
/// used). CLI Pulse quota bars render *remaining* (they deplete as used), so a
/// renderer MUST convert via `place(_:onRemainingBar:)` — an as-used fraction
/// sits at `1 − f` on a remaining bar. Per the Codex/Gemini v1.30 review, the
/// macOS/iOS tier bars are remaining-oriented while the overall fallback bar is
/// used-oriented, so orientation is decided per call site and never assumed.
public enum QuotaBarMarkers {

    /// Expected-pace fraction (0...1, as-used) for one tier, or `nil` when the
    /// tier has no usable future reset anchor (no quota, no/!future
    /// `reset_time`) or the pace engine can't derive a position.
    ///
    /// Builds a **per-tier** `RateWindow` from the tier's own `windowMinutes`
    /// and `reset_time`, so a 5-hour session marker and a weekly marker land on
    /// their respective bars instead of sharing the provider-level/default
    /// window (the review's C3 fix).
    public static func expectedPaceFraction(tier: TierDTO, now: Date = .init()) -> Double? {
        guard tier.quota > 0,
              let resetRaw = tier.reset_time,
              let resetsAt = sharedISO8601Parse(resetRaw),
              resetsAt > now else { return nil }
        let usedPercent = WatchRingMath.usagePercent(quota: tier.quota, remaining: tier.remaining) * 100
        let window = RateWindow(
            usedPercent: usedPercent,
            windowMinutes: tier.windowMinutes,
            resetsAt: resetsAt,
            resetDescription: resetRaw)
        guard let pace = UsagePace.weekly(window: window, now: now) else { return nil }
        return (pace.expectedUsedPercent / 100).clamped(to: 0...1)
    }

    /// Warning-threshold fractions (0...1, as-used) from configured percents
    /// (e.g. `[80, 95]`). Out-of-range values (≤0, ≥100) are dropped; the
    /// result is sorted ascending and de-duplicated.
    public static func warningFractions(thresholdsPercent: [Int]) -> [Double] {
        var seen = Set<Double>()
        return thresholdsPercent
            .map { Double($0) / 100.0 }
            .filter { $0 > 0 && $0 < 1 && seen.insert($0).inserted }
            .sorted()
    }

    /// Place an **as-used** fraction onto a bar. Remaining-oriented bars (fill
    /// = headroom left, deplete as used) put a used-fraction `f` at `1 − f`;
    /// used-oriented bars put it at `f`. The single conversion every renderer
    /// routes through — so a "90% used" critical marker correctly sits near
    /// the empty end of a countdown bar.
    public static func place(_ usedFraction: Double, onRemainingBar: Bool) -> Double {
        let f = usedFraction.clamped(to: 0...1)
        return onRemainingBar ? 1 - f : f
    }
}
