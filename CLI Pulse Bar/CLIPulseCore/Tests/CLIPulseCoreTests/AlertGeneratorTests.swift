import XCTest
@testable import CLIPulseCore

#if os(macOS)

final class AlertGeneratorTests: XCTestCase {

    // MARK: - Helpers

    private func makeSession(id: String = "s1", requests: Int = 0) -> SessionRecord {
        SessionRecord(
            id: id, name: "Test Session", provider: "Claude",
            project: "test-project", device_name: "Mac",
            started_at: "2026-04-20T10:00:00Z",
            last_active_at: "2026-04-20T10:00:00Z",
            status: "active", total_usage: 100,
            estimated_cost: 0.01, cost_status: "normal",
            requests: requests, error_count: 0
        )
    }

    private func makeProvider(
        provider: String = "Claude",
        today_usage: Int = 0,
        estimated_cost_week: Double = 0,
        quota: Int? = nil,
        remaining: Int? = nil,
        tiers: [TierDTO] = []
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider, today_usage: today_usage, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: estimated_cost_week,
            cost_status_today: "normal", cost_status_week: "normal",
            quota: quota, remaining: remaining,
            tiers: tiers,
            status_text: "ok",
            trend: [], recent_sessions: [], recent_errors: []
        )
    }

    // MARK: - generate(): device CPU rule

    func testNoAlertsWhenCPULowAndNoSessions() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 50, memoryUsage: 40)
        let alerts = AlertGenerator.generate(device: snap, sessions: [])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testCpuAlertFiresAtThreshold() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 85, memoryUsage: 40)
        let alerts = AlertGenerator.generate(device: snap, sessions: [])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["type"] as? String, "Usage Spike")
        XCTAssertEqual(alerts[0]["severity"] as? String, "Warning")
        XCTAssertEqual(alerts[0]["source_kind"] as? String, "device")
    }

    // Iter2 — cpu-spike id must rotate hourly (so a re-spike after the user
    // resolved an old one creates a new row instead of upserting into the
    // resolved one) and stay scoped to a device (so a multi-device user
    // doesn't have one mac silence the other's alerts).
    func testCpuSpikeIdRotatesByHour() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 90, memoryUsage: 40)
        // Pin two timestamps exactly one hour apart, same device id.
        let t1 = Date(timeIntervalSince1970: 1_770_000_000)              // hour bucket N
        let t2 = Date(timeIntervalSince1970: 1_770_000_000 + 3600)       // hour bucket N+1
        let alertsT1 = AlertGenerator.generate(device: snap, sessions: [], deviceID: "dev-A", now: t1)
        let alertsT2 = AlertGenerator.generate(device: snap, sessions: [], deviceID: "dev-A", now: t2)
        XCTAssertEqual(alertsT1.count, 1)
        XCTAssertEqual(alertsT2.count, 1)
        let id1 = alertsT1[0]["id"] as? String
        let id2 = alertsT2[0]["id"] as? String
        XCTAssertNotEqual(id1, id2,
                          "cpu-spike id must rotate across the hour boundary so a re-spike fires fresh")
        XCTAssertEqual(id1, "cpu-spike-dev-A-\(Int(t1.timeIntervalSince1970 / 3600))")
        XCTAssertEqual(id2, "cpu-spike-dev-A-\(Int(t2.timeIntervalSince1970 / 3600))")
    }

    func testCpuSpikeIdScopedByDevice() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 90, memoryUsage: 40)
        let t = Date(timeIntervalSince1970: 1_770_000_000)
        let alertsA = AlertGenerator.generate(device: snap, sessions: [], deviceID: "dev-A", now: t)
        let alertsB = AlertGenerator.generate(device: snap, sessions: [], deviceID: "dev-B", now: t)
        XCTAssertNotEqual(alertsA[0]["id"] as? String, alertsB[0]["id"] as? String,
                          "two devices must produce independent cpu-spike ids in the same hour")
        XCTAssertEqual(alertsA[0]["suppression_key"] as? String, alertsA[0]["id"] as? String)
        XCTAssertEqual(alertsB[0]["grouping_key"] as? String, "Usage Spike:device:dev-B")
    }

    func testCpuAlertNotFiredBelow85() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 84, memoryUsage: 40)
        let alerts = AlertGenerator.generate(device: snap, sessions: [])
        XCTAssertTrue(alerts.isEmpty)
    }

    // MARK: - generate(): session CPU rule

    // v1.10.5: Rule 2 is now "session using ≥40% of total system CPU capacity"
    // (capacity = cores * 100). A raw per-process pcpu of 80 means 80% of one
    // core, which on a 14-core Mac is only 5.7% of system — harmless. Tests
    // scale inputs by processorCount so they pass regardless of hardware.

    func testSessionCpuAlertFires() {
        let cores = ProcessInfo.processInfo.processorCount
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        let session = makeSession(id: "s1")
        // 60% of total capacity clearly crosses the 40% threshold.
        let pcpu = Double(cores) * 100.0 * 0.6
        let alerts = AlertGenerator.generate(device: snap, sessions: [session], sessionCPU: ["s1": pcpu])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["type"] as? String, "Usage Spike")
        XCTAssertEqual(alerts[0]["source_kind"] as? String, "session")
    }

    func testSessionCpuAlertNotFiredBelowThreshold() {
        let cores = ProcessInfo.processInfo.processorCount
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        let session = makeSession(id: "s1")
        // 30% of total capacity — below the 40% fire threshold.
        let pcpu = Double(cores) * 100.0 * 0.3
        let alerts = AlertGenerator.generate(device: snap, sessions: [session], sessionCPU: ["s1": pcpu])
        XCTAssertTrue(alerts.isEmpty)
    }

    // MARK: - generate(): long-run session rule

    func testLongRunAlertFires() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        let session = makeSession(id: "s1", requests: 400)
        let alerts = AlertGenerator.generate(device: snap, sessions: [session])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["type"] as? String, "Session Too Long")
        XCTAssertEqual(alerts[0]["severity"] as? String, "Info")
    }

    func testLongRunAlertNotFiredBelow400() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        let session = makeSession(id: "s1", requests: 399)
        let alerts = AlertGenerator.generate(device: snap, sessions: [session])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testResultsCappedAtSix() {
        let cores = ProcessInfo.processInfo.processorCount
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        // 4 sessions each triggering both CPU + long-run = 8 alerts, but capped at 6
        let sessions = (1...4).map { makeSession(id: "s\($0)", requests: 400) }
        // Push each session above the 40%-of-system threshold so the CPU rule fires.
        let pcpu = Double(cores) * 100.0 * 0.6
        let cpu = Dictionary(uniqueKeysWithValues: (1...4).map { ("s\($0)", pcpu) })
        let alerts = AlertGenerator.generate(device: snap, sessions: sessions, sessionCPU: cpu)
        XCTAssertEqual(alerts.count, 6)
    }

    // MARK: - evaluateBudgetAlerts()

    func testNoBudgetAlertsWhenThresholdZero() {
        let p = makeProvider(estimated_cost_week: 100)
        let alerts = AlertGenerator.evaluateBudgetAlerts(providers: [p], budgetThreshold: 0)
        XCTAssertTrue(alerts.isEmpty)
    }

    func testBudgetAlertFiresWhenOverThreshold() {
        let p = makeProvider(estimated_cost_week: 20)
        let alerts = AlertGenerator.evaluateBudgetAlerts(providers: [p], budgetThreshold: 10)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["type"] as? String, "Project Budget Exceeded")
    }

    func testNoBudgetAlertWhenUnderThreshold() {
        let p = makeProvider(estimated_cost_week: 9)
        let alerts = AlertGenerator.evaluateBudgetAlerts(providers: [p], budgetThreshold: 10)
        let budgetAlerts = alerts.filter { $0["type"] as? String == "Project Budget Exceeded" }
        XCTAssertTrue(budgetAlerts.isEmpty)
    }

    func testCostSpikeAlertFires() {
        // today_usage * 0.001 = 11.0 > yesterday(5.0) * 2
        let p = makeProvider(today_usage: 11_000)
        let alerts = AlertGenerator.evaluateBudgetAlerts(providers: [p], budgetThreshold: 1000, yesterdayCost: 5.0)
        let spikeAlerts = alerts.filter { $0["type"] as? String == "Cost Spike" }
        XCTAssertEqual(spikeAlerts.count, 1)
        XCTAssertEqual(spikeAlerts[0]["severity"] as? String, "Warning")
    }

    func testNoSpikeAlertWhenYesterdayBelowMinimum() {
        let p = makeProvider(today_usage: 11_000)
        let alerts = AlertGenerator.evaluateBudgetAlerts(providers: [p], budgetThreshold: 1000, yesterdayCost: 0.5)
        let spikeAlerts = alerts.filter { $0["type"] as? String == "Cost Spike" }
        XCTAssertTrue(spikeAlerts.isEmpty)
    }

    // MARK: - evaluateQuotaAlerts()

    func testEmptyThresholdsReturnsEmpty() {
        let p = makeProvider(quota: 100, remaining: 10)
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testQuotaAlertFiresAt80Percent() {
        // 80 used out of 100 = 80%
        let p = makeProvider(quota: 100, remaining: 20)
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [80, 95])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["severity"] as? String, "Warning")
        XCTAssertEqual(alerts[0]["type"] as? String, "Quota Warning")
    }

    func testQuotaAlertCriticalAt95Percent() {
        // 95 used out of 100 = 95%
        let p = makeProvider(quota: 100, remaining: 5)
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [80, 95])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["severity"] as? String, "Critical")
    }

    func testNoAlertBelowLowestThreshold() {
        // 79 used out of 100 = 79%
        let p = makeProvider(quota: 100, remaining: 21)
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [80, 95])
        XCTAssertTrue(alerts.isEmpty)
    }

    func testQuotaAlertUsesHighestCrossedThreshold() {
        // 96 used = 96%; should cross 95, not 80 (highest-first sort)
        let p = makeProvider(quota: 100, remaining: 4)
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [80, 95])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["severity"] as? String, "Critical")
    }

    // P1-1: severity should be positional against the provided thresholds,
    // not against hard-coded 95%/80% cutoffs. When a user configures
    // [60, 85], a tier at 87% has crossed the "critical" (85) threshold
    // and must render as Critical — even though 87 < 95.
    func testQuotaAlertSeverityPositionalForCustomThresholds() {
        let pHit85 = makeProvider(quota: 100, remaining: 13)  // 87% used
        let critical = AlertGenerator.evaluateQuotaAlerts(
            providers: [pHit85], thresholds: [60, 85]
        )
        XCTAssertEqual(critical.count, 1)
        XCTAssertEqual(critical[0]["severity"] as? String, "Critical")

        let pHit60 = makeProvider(quota: 100, remaining: 35)  // 65% used
        let warning = AlertGenerator.evaluateQuotaAlerts(
            providers: [pHit60], thresholds: [60, 85]
        )
        XCTAssertEqual(warning.count, 1)
        XCTAssertEqual(warning[0]["severity"] as? String, "Warning")
    }

    func testQuotaAlertFromTiers() {
        let tier = TierDTO(name: "5h Window", quota: 100, remaining: 10)
        let p = makeProvider(tiers: [tier])
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [80])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue((alerts[0]["id"] as? String)?.contains("5h Window") == true)
    }

    // P3 — Designs and Daily Routines on Claude must NOT generate quota
    // alerts even when 99% used. The brief explicitly excludes them this
    // round. Weekly at 99% in the same provider still alerts (Critical),
    // proving the suppression is tier-name scoped, not a global mute.
    func testClaudeDesignsAndDailyRoutinesDoNotGenerateQuotaAlerts() {
        let designs = TierDTO(name: "Designs", quota: 100, remaining: 1)            // 99% used
        let routines = TierDTO(name: "Daily Routines", quota: 100, remaining: 1)    // 99% used
        let weekly = TierDTO(name: "Weekly", quota: 100, remaining: 1)              // 99% used
        let claude = makeProvider(provider: "Claude", tiers: [weekly, designs, routines])
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [claude], thresholds: [80, 95])

        let alertedNames = alerts.compactMap { $0["title"] as? String }
        XCTAssertFalse(alertedNames.contains { $0.contains("Designs") },
                       "Designs must not surface a quota alert on Claude")
        XCTAssertFalse(alertedNames.contains { $0.contains("Daily Routines") },
                       "Daily Routines must not surface a quota alert on Claude")
        XCTAssertEqual(alerts.count, 1, "Only the Weekly tier should alert")
        XCTAssertEqual(alerts[0]["severity"] as? String, "Critical")
        XCTAssertTrue((alerts[0]["title"] as? String)?.contains("Weekly") == true)
    }

    // P3 — Suppression is provider-scoped: a non-Claude provider that
    // happens to ship a tier literally named "Designs" must still alert.
    func testNonClaudeDesignsTierStillAlerts() {
        let designs = TierDTO(name: "Designs", quota: 100, remaining: 1) // 99% used
        let other = makeProvider(provider: "Cursor", tiers: [designs])
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [other], thresholds: [80, 95])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue((alerts[0]["title"] as? String)?.contains("Designs") == true)
        XCTAssertEqual(alerts[0]["severity"] as? String, "Critical")
    }

    // MARK: - makeAlertRecord()

    func testMakeAlertRecordFromValidDict() {
        let dict: [String: Any] = [
            "id": "test-id",
            "type": "Usage Spike",
            "severity": "Warning",
            "title": "High CPU",
            "message": "CPU is at 90%",
            "created_at": "2026-04-20T10:00:00Z",
            "source_kind": "device",
        ]
        let record = AlertGenerator.makeAlertRecord(from: dict)
        XCTAssertNotNil(record)
        XCTAssertEqual(record?.id, "test-id")
        XCTAssertEqual(record?.type, "Usage Spike")
        XCTAssertEqual(record?.severity, "Warning")
        XCTAssertEqual(record?.source_kind, "device")
    }

    func testMakeAlertRecordReturnsNilWhenMissingId() {
        let dict: [String: Any] = [
            "type": "Usage Spike",
            "severity": "Warning",
            "title": "High CPU",
            "message": "CPU is at 90%",
            "created_at": "2026-04-20T10:00:00Z",
        ]
        XCTAssertNil(AlertGenerator.makeAlertRecord(from: dict))
    }
}

#endif
