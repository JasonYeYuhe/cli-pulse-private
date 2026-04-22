import Foundation

/// Generates alerts from device metrics and session data.
/// Ports the 3 alert rules from Python's `collect_alerts()`.
///
/// v1.10 P3-4: budget/quota evaluators + `makeAlertRecord` are cross-platform
/// (operate on ProviderUsage, thresholds, dicts). The device-based `generate`
/// method remains macOS-only because it depends on `DeviceMetrics.Snapshot`
/// which is only produced by the macOS helper.
public enum AlertGenerator {

    #if os(macOS)
    /// Generate alerts based on device snapshot and active sessions.
    ///
    /// - `device`: device-level CPU/memory snapshot
    /// - `sessions`: active sessions from LocalScanner
    /// - `sessionCPU`: optional per-session CPU usage (session.id → cpu%), from raw ps output
    ///
    /// Returns at most 6 alerts per cycle (matching Python behavior).
    public static func generate(
        device: DeviceMetrics.Snapshot,
        sessions: [SessionRecord],
        sessionCPU: [String: Double] = [:]
    ) -> [[String: Any]] {
        var alerts: [[String: Any]] = []
        let now = sharedISO8601Formatter.string(from: Date())

        // Rule 1: Device CPU >= 85%
        if device.cpuUsage >= 85 {
            alerts.append([
                "id": "cpu-spike-\(Int(Date().timeIntervalSince1970))",
                "type": "Usage Spike",
                "severity": "Warning",
                "title": "Device CPU usage is elevated",
                "message": "helper sampled CPU usage at \(device.cpuUsage)%.",
                "created_at": now,
                "source_kind": "device",
                "grouping_key": "Usage Spike:system",
                "suppression_key": "Usage Spike:global",
            ])
        }

        for session in sessions {
            // Rule 2: Session CPU >= 80%
            if let cpu = sessionCPU[session.id], cpu >= 80 {
                alerts.append([
                    "id": "session-spike-\(session.id)",
                    "type": "Usage Spike",
                    "severity": "Warning",
                    "title": "\(session.name) is consuming high CPU",
                    "message": "Process CPU is \(String(format: "%.1f", cpu))% for \(session.provider).",
                    "created_at": now,
                    "related_session_id": session.id,
                    "related_session_name": session.name,
                    "related_provider": session.provider,
                    "related_project_name": session.project,
                    "source_kind": "session",
                    "grouping_key": "Usage Spike:\(session.provider)",
                    "suppression_key": "Usage Spike:\(session.id)",
                ])
            }

            // Rule 3: Session requests >= 400 (long-running)
            if session.requests >= 400 {
                alerts.append([
                    "id": "session-long-\(session.id)",
                    "type": "Session Too Long",
                    "severity": "Info",
                    "title": "\(session.name) has been running for a long time",
                    "message": "Long-running local agent session detected by helper.",
                    "created_at": now,
                    "related_session_id": session.id,
                    "related_session_name": session.name,
                    "related_provider": session.provider,
                    "related_project_name": session.project,
                    "source_kind": "session",
                    "grouping_key": "Session Too Long:\(session.provider)",
                    "suppression_key": "Session Too Long:\(session.id)",
                ])
            }
        }

        return Array(alerts.prefix(6))
    }
    #endif

    /// Generate budget and cost spike alerts from provider usage data.
    /// Called during both cloud and local refresh cycles.
    public static func evaluateBudgetAlerts(
        providers: [ProviderUsage],
        budgetThreshold: Double,
        yesterdayCost: Double? = nil
    ) -> [[String: Any]] {
        guard budgetThreshold > 0 else { return [] }
        var alerts: [[String: Any]] = []
        let now = sharedISO8601Formatter.string(from: Date())
        let weekLabel = {
            let cal = Calendar(identifier: .iso8601)
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
            return "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
        }()

        // Per-provider budget check
        let totalWeekCost = providers.reduce(0.0) { $0 + $1.estimated_cost_week }
        if totalWeekCost > budgetThreshold {
            let key = "budget:total:\(weekLabel)"
            alerts.append([
                "id": "budget-total-\(weekLabel)",
                "type": "Project Budget Exceeded",
                "severity": "Warning",
                "title": "Weekly cost exceeds budget",
                "message": String(format: "Total cost this week ($%.2f) exceeds your budget ($%.2f)", totalWeekCost, budgetThreshold),
                "created_at": now,
                "suppression_key": key,
                "grouping_key": "budget:total",
            ])
        }

        // Cost spike: today's total > 2x yesterday (min $1 to avoid trivial alerts)
        if let yesterday = yesterdayCost, yesterday >= 1.0 {
            let todayCost = providers.reduce(0.0) { $0 + Double($1.today_usage) * 0.001 } // rough estimate
            if todayCost > yesterday * 2 {
                let spikeKey = "costspike:\(sharedISO8601Formatter.string(from: Date()).prefix(10))"
                alerts.append([
                    "id": "costspike-\(spikeKey)",
                    "type": "Cost Spike",
                    "severity": "Warning",
                    "title": "Unusual cost spike detected",
                    "message": String(format: "Today's estimated cost is significantly higher than yesterday ($%.2f)", yesterday),
                    "created_at": now,
                    "suppression_key": spikeKey,
                    "grouping_key": "costspike:daily",
                ])
            }
        }

        return alerts
    }

    /// v1.9.3: Generate quota-depletion alerts when any tier crosses one of
    /// the configured thresholds. Stable IDs per (provider, tier, threshold)
    /// keep duplicates from re-firing every refresh.
    ///
    /// - thresholds: percentage points at which to fire (default 50/80/95).
    /// - Returns dictionaries shaped like the other alert generators (compatible
    ///   with `AlertRecord` decoding upstream).
    public static func evaluateQuotaAlerts(
        providers: [ProviderUsage],
        thresholds: [Int] = [80, 95]
    ) -> [[String: Any]] {
        guard !thresholds.isEmpty else { return [] }
        var alerts: [[String: Any]] = []
        let now = sharedISO8601Formatter.string(from: Date())
        let sortedThresholds = thresholds.sorted(by: >) // highest first

        for provider in providers {
            // If provider ships per-tier data, evaluate each tier; otherwise
            // fall back to the overall quota/remaining pair.
            let tiersToCheck: [(name: String, quota: Int, remaining: Int, reset: String?)]
            if !provider.tiers.isEmpty {
                tiersToCheck = provider.tiers.compactMap { t in
                    guard t.quota > 0 else { return nil }
                    return (t.name, t.quota, t.remaining, t.reset_time)
                }
            } else if let q = provider.quota, q > 0, let r = provider.remaining {
                tiersToCheck = [("Overall", q, r, provider.reset_time)]
            } else {
                tiersToCheck = []
            }

            for tier in tiersToCheck {
                let usedPct = Int(round(100.0 * Double(tier.quota - tier.remaining) / Double(tier.quota)))
                guard let crossed = sortedThresholds.first(where: { usedPct >= $0 }) else { continue }
                // Severity is positional, not absolute: the highest configured
                // threshold the user crossed is Critical; any lower threshold
                // they configured is Warning. This lets custom thresholds like
                // [60, 85] mean "60 = Warning, 85 = Critical" instead of
                // mislabeling both as Warning via a hard 95%/80% cutoff.
                let severity = (crossed == sortedThresholds.first) ? "Critical" : "Warning"
                let stableID = "quota-\(provider.provider)-\(tier.name)-\(crossed)"
                let resetSuffix = tier.reset != nil ? " (resets \(tier.reset!))" : ""
                alerts.append([
                    "id": stableID,
                    "type": "Quota Warning",
                    "severity": severity,
                    "title": "\(provider.provider) \(tier.name) at \(usedPct)%",
                    "message": "Quota window '\(tier.name)' is \(usedPct)% used (\(tier.remaining)% remaining)\(resetSuffix).",
                    "created_at": now,
                    "related_provider": provider.provider,
                    "source_kind": "quota",
                    "grouping_key": "Quota Warning:\(provider.provider)",
                    "suppression_key": stableID,
                ])
            }
        }

        return alerts
    }

    /// Convert one of the dictionary alerts emitted above into an
    /// `AlertRecord` so it can flow through `RefreshPayload.alerts` alongside
    /// cloud-supplied alerts.
    public static func makeAlertRecord(from dict: [String: Any]) -> AlertRecord? {
        guard let id = dict["id"] as? String,
              let type = dict["type"] as? String,
              let severity = dict["severity"] as? String,
              let title = dict["title"] as? String,
              let message = dict["message"] as? String,
              let createdAt = dict["created_at"] as? String else {
            return nil
        }
        return AlertRecord(
            id: id, type: type, severity: severity, title: title,
            message: message, created_at: createdAt,
            is_read: false, is_resolved: false,
            acknowledged_at: nil, snoozed_until: nil,
            related_project_id: nil,
            related_project_name: dict["related_project_name"] as? String,
            related_session_id: dict["related_session_id"] as? String,
            related_session_name: dict["related_session_name"] as? String,
            related_provider: dict["related_provider"] as? String,
            related_device_name: dict["related_device_name"] as? String,
            source_kind: dict["source_kind"] as? String,
            source_id: dict["source_id"] as? String,
            grouping_key: dict["grouping_key"] as? String,
            suppression_key: dict["suppression_key"] as? String
        )
    }
}
