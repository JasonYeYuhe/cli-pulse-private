import XCTest
@testable import CLIPulseCore

final class ExportServiceTests: XCTestCase {

    // MARK: - Helpers

    private func readFile(url: URL?) -> String? {
        guard let url else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func lines(_ content: String) -> [String] {
        content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func makeSession(
        id: String = "s1", name: String = "Chat",
        provider: String = "claude", project: String = "Proj",
        status: String = "active", totalUsage: Int = 100,
        cost: Double = 0.05, requests: Int = 10, errors: Int = 0,
        startedAt: String = "2026-04-01T10:00:00Z",
        lastActiveAt: String = "2026-04-01T11:00:00Z"
    ) -> SessionRecord {
        SessionRecord(
            id: id, name: name, provider: provider, project: project,
            device_name: "Mac", started_at: startedAt, last_active_at: lastActiveAt,
            status: status, total_usage: totalUsage, estimated_cost: cost,
            cost_status: "normal", requests: requests, error_count: errors
        )
    }

    private func makeProvider(
        provider: String = "claude",
        todayUsage: Int = 50, weekUsage: Int = 300, costWeek: Double = 1.5,
        quota: Int? = 1000, remaining: Int? = 700,
        planType: String? = "pro", resetTime: String? = "2026-04-07"
    ) -> ProviderUsage {
        ProviderUsage(
            provider: provider, today_usage: todayUsage, week_usage: weekUsage,
            estimated_cost_today: 0.2, estimated_cost_week: costWeek,
            cost_status_today: "normal", cost_status_week: "normal",
            quota: quota, remaining: remaining,
            plan_type: planType, reset_time: resetTime,
            tiers: [], status_text: "ok",
            trend: [], recent_sessions: [], recent_errors: []
        )
    }

    private func makeAlert(
        id: String = "a1", type: String = "Quota Warning",
        severity: String = "Warning", title: String = "Claude at 80%",
        message: String = "Quota almost full",
        provider: String? = "claude", projectName: String? = "MyProject",
        createdAt: String = "2026-04-01T12:00:00Z",
        isRead: Bool = false, isResolved: Bool = false
    ) -> AlertRecord {
        AlertRecord(
            id: id, type: type, severity: severity, title: title,
            message: message, created_at: createdAt, is_read: isRead,
            is_resolved: isResolved, acknowledged_at: nil, snoozed_until: nil,
            related_project_id: nil, related_project_name: projectName,
            related_session_id: nil, related_session_name: nil,
            related_provider: provider, related_device_name: nil
        )
    }

    // MARK: - exportSessionsCSV

    func testExportSessionsCSV_returnsURL() {
        XCTAssertNotNil(ExportService.exportSessionsCSV(sessions: []))
    }

    func testExportSessionsCSV_headerIsCorrect() {
        let content = readFile(url: ExportService.exportSessionsCSV(sessions: []))!
        XCTAssertEqual(lines(content)[0],
            "ID,Name,Provider,Project,Status,Usage,Cost,Requests,Errors,Started,Last Active")
    }

    func testExportSessionsCSV_emptyProducesOnlyHeader() {
        let content = readFile(url: ExportService.exportSessionsCSV(sessions: []))!
        XCTAssertEqual(lines(content).count, 1)
    }

    func testExportSessionsCSV_basicRow() {
        let session = makeSession(
            id: "s1", name: "Chat", provider: "claude", project: "Proj",
            status: "active", totalUsage: 100, cost: 0.05, requests: 10, errors: 2,
            startedAt: "2026-04-01T10:00:00Z", lastActiveAt: "2026-04-01T11:00:00Z"
        )
        let content = readFile(url: ExportService.exportSessionsCSV(sessions: [session]))!
        XCTAssertEqual(lines(content)[1],
            "s1,Chat,claude,Proj,active,100,0.05,10,2,2026-04-01T10:00:00Z,2026-04-01T11:00:00Z")
    }

    func testExportSessionsCSV_commaInFieldIsQuoted() {
        let session = makeSession(project: "My,Project")
        let content = readFile(url: ExportService.exportSessionsCSV(sessions: [session]))!
        XCTAssertTrue(content.contains("\"My,Project\""))
    }

    func testExportSessionsCSV_quoteInFieldIsEscaped() {
        let session = makeSession(name: "He said \"hello\"")
        let content = readFile(url: ExportService.exportSessionsCSV(sessions: [session]))!
        XCTAssertTrue(content.contains("\"He said \"\"hello\"\"\""))
    }

    func testExportSessionsCSV_multipleRowsCount() {
        let sessions = [makeSession(id: "s1"), makeSession(id: "s2"), makeSession(id: "s3")]
        let content = readFile(url: ExportService.exportSessionsCSV(sessions: sessions))!
        XCTAssertEqual(lines(content).count, 4)
    }

    // MARK: - exportProviderSummaryCSV

    func testExportProviderSummaryCSV_returnsURL() {
        XCTAssertNotNil(ExportService.exportProviderSummaryCSV(providers: []))
    }

    func testExportProviderSummaryCSV_headerIsCorrect() {
        let content = readFile(url: ExportService.exportProviderSummaryCSV(providers: []))!
        XCTAssertEqual(lines(content)[0],
            "Provider,Today Usage,Week Usage,Est. Cost (Week),Remaining,Quota,Plan Type,Reset Time")
    }

    func testExportProviderSummaryCSV_nilQuotaAndRemainingShowNA() {
        let p = makeProvider(quota: nil, remaining: nil, planType: nil, resetTime: nil)
        let content = readFile(url: ExportService.exportProviderSummaryCSV(providers: [p]))!
        let row = lines(content)[1]
        XCTAssertTrue(row.contains(",N/A,N/A,"))
    }

    func testExportProviderSummaryCSV_valuesPresent() {
        let p = makeProvider(
            provider: "gemini", weekUsage: 500, costWeek: 2.0,
            quota: 1000, remaining: 400, planType: "pro", resetTime: "2026-05-01"
        )
        let content = readFile(url: ExportService.exportProviderSummaryCSV(providers: [p]))!
        let row = lines(content)[1]
        XCTAssertTrue(row.hasPrefix("gemini,"))
        XCTAssertTrue(row.contains(",400,1000,"))
    }

    // MARK: - exportAlertsCSV

    func testExportAlertsCSV_returnsURL() {
        XCTAssertNotNil(ExportService.exportAlertsCSV(alerts: []))
    }

    func testExportAlertsCSV_headerIsCorrect() {
        let content = readFile(url: ExportService.exportAlertsCSV(alerts: []))!
        XCTAssertEqual(lines(content)[0],
            "ID,Type,Severity,Title,Message,Provider,Project,Created,Read,Resolved")
    }

    func testExportAlertsCSV_basicRow() {
        let alert = makeAlert(
            id: "a1", type: "Quota Warning", severity: "Warning",
            title: "Claude at 80%", message: "Quota almost full",
            provider: "claude", projectName: "MyProject",
            createdAt: "2026-04-01T12:00:00Z", isRead: false, isResolved: false
        )
        let content = readFile(url: ExportService.exportAlertsCSV(alerts: [alert]))!
        XCTAssertEqual(lines(content)[1],
            "a1,Quota Warning,Warning,Claude at 80%,Quota almost full,claude,MyProject,2026-04-01T12:00:00Z,false,false")
    }

    func testExportAlertsCSV_nilProviderAndProjectShowEmpty() {
        let alert = makeAlert(provider: nil, projectName: nil)
        let content = readFile(url: ExportService.exportAlertsCSV(alerts: [alert]))!
        let parts = lines(content)[1].components(separatedBy: ",")
        XCTAssertEqual(parts[5], "")
        XCTAssertEqual(parts[6], "")
    }

    func testExportAlertsCSV_resolvedAndRead() {
        let alert = makeAlert(isRead: true, isResolved: true)
        let content = readFile(url: ExportService.exportAlertsCSV(alerts: [alert]))!
        XCTAssertTrue(lines(content)[1].hasSuffix(",true,true"))
    }
}
