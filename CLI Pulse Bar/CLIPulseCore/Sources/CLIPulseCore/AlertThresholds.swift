import Foundation

/// Persisted user-facing thresholds (percent of quota used) that gate
/// `AlertGenerator.evaluateQuotaAlerts`. Stored as a 2-element Int array
/// under UserDefaults key `cli_pulse_alert_thresholds_v1` so the existing
/// `thresholds: [Int]` API on `AlertGenerator` consumes it unchanged.
///
/// Invariants enforced on save:
///   - `warning  ∈ [50, 94]`
///   - `critical ∈ [warning + 1, 99]`
/// Values outside these bounds are clamped before persistence; a fully
/// unreadable / missing / malformed record falls back to the defaults.
public struct AlertThresholds: Equatable, Sendable {
    public let warning: Int
    public let critical: Int

    public static let defaults = AlertThresholds(warning: 80, critical: 95)

    public static let warningRange = 50...94
    public static let criticalUpperBound = 99

    public init(warning: Int, critical: Int) {
        self.warning = warning
        self.critical = critical
    }

    /// Array form used by `AlertGenerator.evaluateQuotaAlerts(thresholds:)`.
    public var asArray: [Int] { [warning, critical] }

    /// Clamp to invariants. Returns a valid instance.
    public static func clamped(warning: Int, critical: Int) -> AlertThresholds {
        let w = min(max(warning, warningRange.lowerBound), warningRange.upperBound)
        let c = min(max(critical, w + 1), criticalUpperBound)
        return AlertThresholds(warning: w, critical: c)
    }
}

/// UserDefaults-backed load/save for `AlertThresholds`. Kept as a tiny
/// namespace (not an ObservableObject) because settings UI reads/writes
/// synchronously and there is no need for cross-view observation yet.
public enum AlertThresholdsStore {
    public static let key = "cli_pulse_alert_thresholds_v1"

    public static func load(from defaults: UserDefaults = .standard) -> AlertThresholds {
        guard let raw = defaults.array(forKey: key) as? [Int],
              raw.count == 2
        else {
            return .defaults
        }
        return AlertThresholds.clamped(warning: raw[0], critical: raw[1])
    }

    public static func save(_ thresholds: AlertThresholds,
                            to defaults: UserDefaults = .standard) {
        let clamped = AlertThresholds.clamped(warning: thresholds.warning,
                                              critical: thresholds.critical)
        defaults.set(clamped.asArray, forKey: key)
    }

    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
