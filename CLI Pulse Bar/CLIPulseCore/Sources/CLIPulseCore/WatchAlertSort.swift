import Foundation

/// Pure severity ordering for the watchOS Alerts page. In CLIPulseCore so
/// `swift test` exercises it (the watch app target is CI-only).
public enum WatchAlertSort {

    /// Sort rank: Critical (0) → Warning (1) → Info (2) → unknown (3).
    public static func severityRank(_ severity: String) -> Int {
        switch AlertSeverity(rawValue: severity) {
        case .critical: return 0
        case .warning: return 1
        case .info: return 2
        case .none: return 3
        }
    }

    /// Alerts ordered most-severe first. The sort is made deterministically
    /// **stable** (Swift's `sorted` is not guaranteed stable) by using the
    /// original index as the tie-breaker, so same-severity alerts keep the
    /// server's order (typically newest-first).
    public static func bySeverity(_ alerts: [AlertRecord]) -> [AlertRecord] {
        alerts.enumerated()
            .sorted { lhs, rhs in
                let lr = severityRank(lhs.element.severity)
                let rr = severityRank(rhs.element.severity)
                if lr != rr { return lr < rr }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}
