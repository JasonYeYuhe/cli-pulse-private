import Foundation
import CommonCrypto

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
    /// - `deviceID`: stable device identifier (helper config UUID, falling
    ///    back to host name). Used to scope the device-CPU alert id so
    ///    multi-device users don't collide on a shared `cpu-spike-global` row.
    /// - `now`: clock injection point for tests.
    ///
    /// Returns at most 6 alerts per cycle (matching Python behavior).
    public static func generate(
        device: DeviceMetrics.Snapshot,
        sessions: [SessionRecord],
        sessionCPU: [String: Double] = [:],
        deviceID: String = ProcessInfo.processInfo.hostName,
        now: Date = Date()
    ) -> [[String: Any]] {
        var alerts: [[String: Any]] = []
        let nowStr = sharedISO8601Formatter.string(from: now)

        // Rule 1: Device CPU >= 85%
        //
        // History:
        //   * `cpu-spike-global` → silenced multi-device users + once the
        //     user resolved the row the helper UPSERT-with-ON-CONFLICT
        //     preserved is_resolved=true forever.
        //   * `cpu-spike-<device>-<hourBucket>` (iter2) → multi-device safe
        //     and re-fires on the next hour, BUT created a brand-new
        //     unresolved alert row every hour the device stayed above
        //     85%. Resolving / snoozing was useless because the next hour
        //     produced a fresh id with no suppression match. Settings
        //     also offered no knob to turn this off, so users were stuck
        //     with a recurring noise floor.
        //   * iter3 (this PR, post-Codex review on PR #18): drop hourBucket
        //     entirely. Stable id `cpu-spike-<device>` lets the helper's
        //     ON CONFLICT preserve `is_resolved` once the user resolves /
        //     snoozes / dismisses, so the same device-level CPU
        //     condition does NOT keep generating new unresolved rows.
        //     The visible `created_at` still updates each cycle so the
        //     row's timestamp reflects the most recent sample, but the
        //     row identity is stable — which is what the suppression
        //     infra (both client-side `suppressedAlertIDs` and server-
        //     side `is_resolved`) keys on. Re-firing after a recovery /
        //     re-spike is intentionally deferred: doing it well requires
        //     a "below threshold for N consecutive cycles" recovery
        //     detector + a Settings page to expose the knob, both of
        //     which are out of scope for the iter 2B noise-reduction
        //     pass.
        //
        // The pinning test that asserted the hourly rotation
        // (`testCpuSpikeIdRotatesByHour`) flips to assert id stability
        // across hours so a future engineer doesn't reintroduce the
        // bug under the original-comment justification.
        if device.cpuUsage >= 85 {
            let stableID = "cpu-spike-\(deviceID)"
            alerts.append([
                "id": stableID,
                "type": "Usage Spike",
                "severity": "Warning",
                "title": "Device CPU usage is elevated",
                "message": "helper sampled CPU usage at \(device.cpuUsage)%.",
                "created_at": nowStr,
                "source_kind": "device",
                "grouping_key": "Usage Spike:device:\(deviceID)",
                "suppression_key": stableID,
            ])
        }

        let cpuCount = max(ProcessInfo.processInfo.processorCount, 1)
        let systemCapacity = Double(cpuCount * 100)
        let systemFractionThreshold = 0.4

        for session in sessions {
            // Rule 2: Session using ≥40% of total system CPU.
            // Prior versions compared raw per-process %CPU (where 100% = 1 core)
            // against a hardcoded 80, which fired on trivial workloads on
            // high-core-count Macs (80% of 1 core = 5.7% of a 14-core system).
            // Normalize by core count so the threshold represents a meaningful
            // share of total capacity regardless of machine.
            // v1.16 §2.4: alert_id includes process start_time so PID
            // recycling can't suppress new alerts when a fresh process
            // lands on a recently-resolved PID.
            let sid = AlertGenerator.alertSessionIDSuffix(session)
            if let cpu = sessionCPU[session.id], cpu / systemCapacity >= systemFractionThreshold {
                let systemPct = Int(round(cpu / systemCapacity * 100))
                alerts.append([
                    "id": "session-spike-\(sid)",
                    "type": "Usage Spike",
                    "severity": "Warning",
                    "title": "\(session.name) is consuming high CPU",
                    "message": "Using ~\(systemPct)% of total system CPU (\(cpuCount) cores) for \(session.provider).",
                    "created_at": nowStr,
                    "related_session_id": session.id,
                    "related_session_name": session.name,
                    "related_provider": session.provider,
                    "related_project_name": session.project,
                    "source_kind": "session",
                    "grouping_key": "Usage Spike:\(session.provider)",
                    "suppression_key": "Usage Spike:\(sid)",
                ])
            }

            // Rule 3: Session requests >= 400 (long-running)
            // v1.16.1 parity with helper/system_collector.py: skip
            // process-detected (`proc-*`) rows entirely. They're GUI
            // desktop apps the user keeps open all day, not "agentic CLI
            // sessions". The synthetic `requests` proxy makes them trip
            // the threshold within hours of being open. See full analysis
            // in helper/system_collector.py.
            let isProcessDetected = session.id.hasPrefix("proc-")
            if !isProcessDetected, session.requests >= 400 {
                alerts.append([
                    "id": "session-long-\(sid)",
                    "type": "Session Too Long",
                    "severity": "Info",
                    "title": "\(session.name) has been running for a long time",
                    "message": "Long-running local agent session detected by helper.",
                    "created_at": nowStr,
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

    /// v1.16 §2.4: stable id suffix combining the session's PID + start
    /// time so PID recycling can't collide. SHA-256 prefix is plenty for
    /// ID-disambiguation at PID-recycling cadence.
    ///
    /// v1.16.1 (Codex review): truncate sub-second precision off
    /// `started_at` before hashing. The Python helper recomputes it as
    /// `now() - etime` each cycle and `etime` is whole-second only, so
    /// the ISO timestamp drifted ~hundreds of ms cycle-to-cycle for the
    /// same process — fracturing the digest, breaking server upserts,
    /// and producing a fresh alert row every sync. Keep the second-
    /// precision portion only.
    static func alertSessionIDSuffix(_ session: SessionRecord) -> String {
        let stableStarted = session.started_at.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression
        )
        let payload = "\(session.id)|\(stableStarted)"
        let digest = sha256Prefix(payload, prefixBytes: 4)
        return "\(session.id)-\(digest)"
    }

    private static func sha256Prefix(_ s: String, prefixBytes: Int) -> String {
        guard let data = s.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            let buf = ptr.baseAddress!.assumingMemoryBound(to: UInt8.self)
            CC_SHA256(buf, CC_LONG(data.count), &hash)
        }
        return hash.prefix(prefixBytes).map { String(format: "%02x", $0) }.joined()
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

        // Claude launch-window quotas (Designs, Daily Routines) intentionally
        // skip notifications this round — the brief explicitly excludes them.
        // Suppression is provider-scoped: a non-Claude provider that happens
        // to ship a tier named "Designs" still alerts.
        let claudeNonAlertingTiers: Set<String> = ["Designs", "Daily Routines"]

        for provider in providers {
            // If provider ships per-tier data, evaluate each tier; otherwise
            // fall back to the overall quota/remaining pair.
            let tiersToCheck: [(name: String, quota: Int, remaining: Int, reset: String?)]
            if !provider.tiers.isEmpty {
                tiersToCheck = provider.tiers.compactMap { t in
                    guard t.quota > 0 else { return nil }
                    if provider.provider == ProviderKind.claude.rawValue,
                       claudeNonAlertingTiers.contains(t.name) {
                        return nil
                    }
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
