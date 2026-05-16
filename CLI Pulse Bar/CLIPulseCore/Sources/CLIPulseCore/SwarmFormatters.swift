import Foundation

/// v1.22 P0 — shared, locale-neutral formatting for Swarm View.
///
/// Lives in CLIPulseCore (not the Mac app target) so the Mac grid (S3),
/// the iOS grid + Live Activity (S4), and the watch / Android-parity
/// surfaces (S5) all render swarm ages identically without duplicating
/// the logic — and so it's unit-testable from `CLIPulseCoreTests`.
public enum SwarmFormat {

    /// Compact relative age: `"42s"` / `"9m"` / `"1h 4m"`.
    /// Clamped at zero — a clock-skewed negative never shows.
    public static func humanizeAge(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600
        let m = (s % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}
