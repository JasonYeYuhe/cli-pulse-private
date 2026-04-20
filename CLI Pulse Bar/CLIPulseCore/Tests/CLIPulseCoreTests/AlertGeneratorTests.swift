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

    func testCpuAlertNotFiredBelow85() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 84, memoryUsage: 40)
        let alerts = AlertGenerator.generate(device: snap, sessions: [])
        XCTAssertTrue(alerts.isEmpty)
    }

    // MARK: - generate(): session CPU rule

    func testSessionCpuAlertFires() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        let session = makeSession(id: "s1")
        let alerts = AlertGenerator.generate(device: snap, sessions: [session], sessionCPU: ["s1": 80.0])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0]["type"] as? String, "Usage Spike")
        XCTAssertEqual(alerts[0]["source_kind"] as? String, "session")
    }

    func testSessionCpuAlertNotFiredBelow80() {
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        let session = makeSession(id: "s1")
        let alerts = AlertGenerator.generate(device: snap, sessions: [session], sessionCPU: ["s1": 79.9])
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
        let snap = DeviceMetrics.Snapshot(cpuUsage: 10, memoryUsage: 40)
        // 4 sessions each triggering both CPU + long-run = 8 alerts, but capped at 6
        let sessions = (1...4).map { makeSession(id: "s\($0)", requests: 400) }
        let cpu = Dictionary(uniqueKeysWithValues: (1...4).map { ("s\($0)", 85.0) })
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

    func testQuotaAlertFromTiers() {
        let tier = TierDTO(name: "5h Window", quota: 100, remaining: 10)
        let p = makeProvider(tiers: [tier])
        let alerts = AlertGenerator.evaluateQuotaAlerts(providers: [p], thresholds: [80])
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue((alerts[0]["id"] as? String)?.contains("5h Window") == true)
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
