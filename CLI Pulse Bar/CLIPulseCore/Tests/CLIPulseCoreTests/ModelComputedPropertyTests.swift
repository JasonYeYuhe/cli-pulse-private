import XCTest
@testable import CLIPulseCore

final class ModelComputedPropertyTests: XCTestCase {

    // MARK: - ProviderUsage.usagePercent

    private func makeProviderUsage(quota: Int?, remaining: Int?) -> ProviderUsage {
        ProviderUsage(
            provider: "Claude", today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Estimated", cost_status_week: "Estimated",
            quota: quota, remaining: remaining,
            status_text: "", trend: [], recent_sessions: [], recent_errors: []
        )
    }

    func testUsagePercentNilQuotaReturnsZero() {
        XCTAssertEqual(makeProviderUsage(quota: nil, remaining: nil).usagePercent, 0)
    }

    func testUsagePercentZeroQuotaReturnsZero() {
        XCTAssertEqual(makeProviderUsage(quota: 0, remaining: 0).usagePercent, 0)
    }

    func testUsagePercentNormalCase() {
        // quota=1000, remaining=200 → used=800 → 0.8
        XCTAssertEqual(makeProviderUsage(quota: 1000, remaining: 200).usagePercent, 0.8, accuracy: 1e-9)
    }

    func testUsagePercentCapsAtOne() {
        // remaining=0, used >= quota → capped at 1.0
        XCTAssertEqual(makeProviderUsage(quota: 500, remaining: 0).usagePercent, 1.0, accuracy: 1e-9)
    }

    // MARK: - UserSecret.projectHash

    func testProjectHashIsDeterministic() {
        let secret = Data(repeating: 0xAB, count: 32)
        let h1 = UserSecret.projectHash(secret: secret, absolutePath: "/Users/jason/project")
        let h2 = UserSecret.projectHash(secret: secret, absolutePath: "/Users/jason/project")
        XCTAssertEqual(h1, h2)
    }

    func testProjectHashIs64HexChars() {
        let secret = Data(repeating: 0x01, count: 32)
        let hash = UserSecret.projectHash(secret: secret, absolutePath: "/some/path")
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit }, "hash should be lowercase hex: \(hash)")
    }

    func testProjectHashDifferentPathsDifferentHashes() {
        let secret = Data(repeating: 0x42, count: 32)
        let h1 = UserSecret.projectHash(secret: secret, absolutePath: "/path/a")
        let h2 = UserSecret.projectHash(secret: secret, absolutePath: "/path/b")
        XCTAssertNotEqual(h1, h2)
    }

    func testProjectHashDifferentSecretsProduceDifferentHashes() {
        let s1 = Data(repeating: 0x11, count: 32)
        let s2 = Data(repeating: 0x22, count: 32)
        let path = "/shared/path"
        XCTAssertNotEqual(
            UserSecret.projectHash(secret: s1, absolutePath: path),
            UserSecret.projectHash(secret: s2, absolutePath: path)
        )
    }

    // MARK: - SessionRecord computed properties

    private func makeSession(provider: String, status: String, confidence: String?) -> SessionRecord {
        SessionRecord(
            id: "s1", name: "test", provider: provider, project: "proj",
            device_name: "Mac", started_at: "2026-04-21T00:00:00Z",
            last_active_at: "2026-04-21T01:00:00Z", status: status,
            total_usage: 0, estimated_cost: 0, cost_status: "Estimated",
            requests: 0, error_count: 0, collection_confidence: confidence
        )
    }

    func testSessionProviderKindKnown() {
        XCTAssertEqual(makeSession(provider: "Claude", status: "Running", confidence: nil).providerKind, .claude)
    }

    func testSessionProviderKindUnknownReturnsNil() {
        XCTAssertNil(makeSession(provider: "Unknown", status: "Running", confidence: nil).providerKind)
    }

    func testSessionStatusRunning() {
        XCTAssertEqual(makeSession(provider: "Codex", status: "Running", confidence: nil).sessionStatus, .running)
    }

    func testSessionConfidenceHighMediumLow() {
        XCTAssertEqual(makeSession(provider: "Gemini", status: "Idle", confidence: "high").confidence, .high)
        XCTAssertEqual(makeSession(provider: "Gemini", status: "Idle", confidence: "medium").confidence, .medium)
        XCTAssertNil(makeSession(provider: "Gemini", status: "Idle", confidence: nil).confidence)
    }

    // MARK: - AlertRecord computed properties

    private func makeAlert(type: String, severity: String) -> AlertRecord {
        AlertRecord(
            id: "a1", type: type, severity: severity,
            title: "Test", message: "msg", created_at: "2026-04-21T00:00:00Z",
            is_read: false, is_resolved: false,
            acknowledged_at: nil, snoozed_until: nil,
            related_project_id: nil, related_project_name: nil,
            related_session_id: nil, related_session_name: nil,
            related_provider: nil, related_device_name: nil
        )
    }

    func testAlertSeverityKnown() {
        XCTAssertEqual(makeAlert(type: "Quota Low", severity: "Critical").alertSeverity, .critical)
        XCTAssertEqual(makeAlert(type: "Quota Low", severity: "Warning").alertSeverity, .warning)
        XCTAssertEqual(makeAlert(type: "Quota Low", severity: "Info").alertSeverity, .info)
    }

    func testAlertSeverityUnknownReturnsNil() {
        XCTAssertNil(makeAlert(type: "Quota Low", severity: "unknown").alertSeverity)
    }

    func testAlertTypeKnown() {
        XCTAssertEqual(makeAlert(type: "Quota Low", severity: "Warning").alertType, .quotaLow)
        XCTAssertEqual(makeAlert(type: "Usage Spike", severity: "Warning").alertType, .usageSpike)
    }

    func testAlertTypeUnknownReturnsNil() {
        XCTAssertNil(makeAlert(type: "Mystery Alert", severity: "Info").alertType)
    }

    func testAlertCreatedDateParsesISO8601() {
        let alert = makeAlert(type: "Quota Low", severity: "Info")
        XCTAssertNotNil(alert.createdDate)
    }

    // MARK: - DeviceRecord.deviceStatus

    private func makeDevice(status: String) -> DeviceRecord {
        DeviceRecord(
            id: "d1", name: "Mac", type: "laptop", system: "macOS 15",
            status: status, last_sync_at: nil, helper_version: "1.0",
            current_session_count: 0, cpu_usage: nil, memory_usage: nil
        )
    }

    func testDeviceStatusKnownValues() {
        XCTAssertEqual(makeDevice(status: "Online").deviceStatus, .online)
        XCTAssertEqual(makeDevice(status: "Offline").deviceStatus, .offline)
        XCTAssertEqual(makeDevice(status: "Degraded").deviceStatus, .degraded)
    }

    func testDeviceStatusUnknownReturnsNil() {
        XCTAssertNil(makeDevice(status: "Unreachable").deviceStatus)
    }
}
