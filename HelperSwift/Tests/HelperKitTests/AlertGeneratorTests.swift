import XCTest
@testable import HelperKit
import Foundation

final class AlertGeneratorTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    private func session(
        id: String = "proc-1",
        name: String = "claude",
        provider: String = "Claude",
        project: String = "myproj",
        cpu: Double? = nil,
        requests: Int? = nil
    ) -> CollectedSession {
        return CollectedSession(
            sessionId: id,
            name: name,
            provider: provider,
            project: project,
            status: "Running",
            totalUsage: 1000,
            requests: requests,
            errorCount: 0,
            startedAt: nil,
            lastActiveAt: nil,
            exactCost: nil,
            cpuUsage: cpu,
            command: nil,
            collectionConfidence: "high",
            projectHash: nil,
            projectRoot: nil
        )
    }

    // MARK: - Threshold pinning (Gemini review pattern: pin values)

    func testThresholdsArePinned() {
        // Drift in any of these values would silently change which
        // sessions / devices fire alerts. Pin against the Python
        // helper's `collect_alerts` constants so a future tweak that
        // forgets the alert table can't slip in.
        XCTAssertEqual(AlertGenerator.deviceCpuSpikeThreshold, 85)
        XCTAssertEqual(AlertGenerator.sessionCpuSpikeThreshold, 80.0)
        XCTAssertEqual(AlertGenerator.sessionTooLongRequestsThreshold, 400)
        XCTAssertEqual(AlertGenerator.maxAlertsPerCollection, 6)
    }

    // MARK: - Device-level alerts

    func testDeviceCpuSpikeAtThreshold() {
        let alerts = AlertGenerator().generate(
            sessions: [],
            device: DeviceSnapshot(cpuUsage: 85, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].type, "Usage Spike")
        XCTAssertEqual(alerts[0].severity, "Warning")
        XCTAssertTrue(alerts[0].title.contains("CPU"))
        XCTAssertTrue(alerts[0].message.contains("85%"))
    }

    func testDeviceCpuBelowThreshold_noAlert() {
        let alerts = AlertGenerator().generate(
            sessions: [],
            device: DeviceSnapshot(cpuUsage: 84, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 0)
    }

    // MARK: - Session-level alerts

    func testSessionCpuSpikeAtThreshold() {
        let alerts = AlertGenerator().generate(
            sessions: [session(cpu: 80.0)],
            device: DeviceSnapshot(cpuUsage: 10, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts[0].alertId.hasPrefix("session-spike-"))
        XCTAssertEqual(alerts[0].relatedProvider, "Claude")
        XCTAssertEqual(alerts[0].relatedSessionId, "proc-1")
    }

    func testSessionCpuBelowThreshold_noAlert() {
        let alerts = AlertGenerator().generate(
            sessions: [session(cpu: 79.9)],
            device: DeviceSnapshot(cpuUsage: 10, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 0)
    }

    func testSessionTooLongAtThreshold() {
        let alerts = AlertGenerator().generate(
            sessions: [session(requests: 400)],
            device: DeviceSnapshot(cpuUsage: 10, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].type, "Session Too Long")
        XCTAssertEqual(alerts[0].severity, "Info")
    }

    func testSessionWithNilFieldsDoesntFire() {
        // A session whose cpuUsage and requests are nil (Slice 1 init
        // shape) must NOT trigger any alert.
        let s = CollectedSession(sessionId: "x", provider: "Claude", projectRoot: nil)
        let alerts = AlertGenerator().generate(
            sessions: [s],
            device: DeviceSnapshot(cpuUsage: 10, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 0)
    }

    // MARK: - Cap

    func testTopSixCap() {
        // 8 sessions at 90% CPU each → 8 candidate alerts; cap to 6.
        let sessions = (0..<8).map { i in
            session(id: "proc-\(i)", name: "s\(i)", project: "p\(i)", cpu: 90.0)
        }
        let alerts = AlertGenerator().generate(
            sessions: sessions,
            device: DeviceSnapshot(cpuUsage: 10, memoryUsage: 30),
            now: fixedNow
        )
        XCTAssertEqual(alerts.count, 6)
    }

    // MARK: - Project ID slug

    func testProjectIdSlugifies() {
        XCTAssertEqual(AlertGenerator.projectId("My Cool App"), "my-cool-app")
        XCTAssertEqual(AlertGenerator.projectId("foo_bar/baz"), "foo-bar-baz")
        XCTAssertEqual(AlertGenerator.projectId("UPPER"), "upper")
        XCTAssertEqual(AlertGenerator.projectId(""), "local-workspace")
        XCTAssertEqual(AlertGenerator.projectId("---"), "local-workspace")
    }

    // MARK: - Wire shape

    func testCollectedAlertEncodesSnakeCase() throws {
        let alert = CollectedAlert(
            alertId: "x-1",
            type: "Usage Spike",
            severity: "Warning",
            title: "t", message: "m",
            createdAt: "2026-05-07T00:00:00Z",
            relatedProjectId: "p1",
            relatedProjectName: "P One",
            relatedSessionId: "s1",
            relatedSessionName: "S One",
            relatedProvider: "Claude"
        )
        let data = try JSONEncoder().encode(alert)
        let json = String(data: data, encoding: .utf8) ?? ""
        for needle in [
            "\"alert_id\":\"x-1\"",
            "\"created_at\":",
            "\"related_project_id\":\"p1\"",
            "\"related_session_id\":\"s1\"",
            "\"related_provider\":\"Claude\"",
        ] {
            XCTAssertTrue(json.contains(needle),
                          "missing snake_case key `\(needle)` in \(json)")
        }
    }
}
