import Foundation

/// v1.10 P2-3 slice 1: AppState-debloat. Moved out of `AppState.swift`:
/// the `SuppressionEntry` type, pure `prunedSuppressions` helper, and
/// the persistence keys / retention constant. `AppState` re-exports
/// `SuppressionEntry` as a nested alias so the public API is unchanged.
///
/// Zero behavior change — this is organizational cleanup so the eventual
/// P2-3 `AlertState` child ObservableObject has a clean place to live.
public enum AlertSuppression {

    public static let legacyKey  = "cli_pulse_suppressed_alert_ids_v1"
    public static let currentKey = "cli_pulse_suppressed_alert_ids_v2"

    /// Persistent "never reappear" suppressions (i.e. `Date.distantFuture`)
    /// are recycled this long after the user dismissed them, so stale IDs
    /// don't pile up forever in UserDefaults. Time-boxed snoozes expire
    /// naturally via their `until` date and ignore this constant.
    public static let permanentRetentionDays: Double = 180

    public struct Entry: Equatable, Sendable {
        public let until: Date
        public let dismissedAt: Date
        public init(until: Date, dismissedAt: Date) {
            self.until = until
            self.dismissedAt = dismissedAt
        }
        /// Heuristic: anything suppressed for more than 50 years is a
        /// `Date.distantFuture` sentinel ("never reappear"). Those entries
        /// are recycled after `permanentRetentionDays` instead of their
        /// bogus far-future `until`.
        public var isPermanent: Bool {
            until.timeIntervalSince(dismissedAt) > 50 * 365 * 24 * 3600
        }
    }

    /// Pure prune logic — no `UserDefaults` or `AppState` instance needed.
    /// Returns the surviving entry map plus the set of still-active IDs
    /// (those whose suppression has not yet expired).
    public static func prune(
        _ entries: [String: Entry],
        now: Date,
        retentionDays: Double = AlertSuppression.permanentRetentionDays
    ) -> (active: Set<String>, kept: [String: Entry]) {
        let permanentCutoff = now.addingTimeInterval(-retentionDays * 24 * 3600)
        var active = Set<String>()
        var kept = [String: Entry]()
        for (id, entry) in entries {
            let stillActive: Bool
            if entry.isPermanent {
                stillActive = entry.dismissedAt > permanentCutoff
            } else {
                stillActive = entry.until > now
            }
            if stillActive {
                active.insert(id)
                kept[id] = entry
            }
        }
        return (active, kept)
    }
}
