// Unit tests for the v1.23.0 Phase C-7 DeepgramCollector (new
// status-only usage reporter). Locks the parse/aggregate/format/build
// logic; the network concurrency + absolute timeout (Gemini C-7 R1
// CRITICAL) are exercised indirectly (URLSession not injectable).
// macOS-gated like the other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class DeepgramCollectorTests: XCTestCase {
    private let collector = DeepgramCollector()

    // MARK: - Projects parse

    func test_parseProjects_snake_case() throws {
        let projects = try DeepgramCollector.parseProjects(Data("""
        {"projects":[{"project_id":"p1","name":"Prod"},{"project_id":"p2"}]}
        """.utf8))
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].projectID, "p1")
        XCTAssertEqual(projects[0].name, "Prod")
        XCTAssertEqual(projects[1].projectID, "p2")
        XCTAssertNil(projects[1].name)
    }

    func test_parseProjects_invalid_throws() {
        XCTAssertThrowsError(try DeepgramCollector.parseProjects(Data("not json".utf8)))
    }

    // MARK: - Usage aggregate parse

    func test_parseUsageAggregate_sums_results() throws {
        let a = try DeepgramCollector.parseUsageAggregate(Data("""
        {"results":[
          {"requests":100,"hours":5.5,"total_hours":6.0,"tokens_in":1000,"tokens_out":2000,"tts_characters":500},
          {"requests":50,"hours":1.5,"agent_hours":2.0}
        ]}
        """.utf8))
        XCTAssertEqual(a.requests, 150)
        XCTAssertEqual(a.hours, 7.0, accuracy: 0.0001)
        XCTAssertEqual(a.totalHours, 6.0, accuracy: 0.0001)
        XCTAssertEqual(a.agentHours, 2.0, accuracy: 0.0001)
        XCTAssertEqual(a.tokensIn, 1000)
        XCTAssertEqual(a.tokensOut, 2000)
        XCTAssertEqual(a.ttsCharacters, 500)
    }

    func test_parseUsageAggregate_empty_results_is_zero() throws {
        let a = try DeepgramCollector.parseUsageAggregate(Data(#"{"results":[]}"#.utf8))
        XCTAssertEqual(a.requests, 0)
        XCTAssertEqual(a.hours, 0)
    }

    func test_parseUsageAggregate_missing_keys_default_zero() throws {
        let a = try DeepgramCollector.parseUsageAggregate(Data(#"{"results":[{"requests":7}]}"#.utf8))
        XCTAssertEqual(a.requests, 7)
        XCTAssertEqual(a.hours, 0)
        XCTAssertEqual(a.tokensIn, 0)
    }

    // MARK: - Combine (multi-project)

    func test_combine_aggregates() {
        let a = DeepgramCollector.UsageAggregate(
            requests: 100, hours: 5, totalHours: 6, agentHours: 1,
            tokensIn: 10, tokensOut: 20, ttsCharacters: 30)
        let b = DeepgramCollector.UsageAggregate(
            requests: 50, hours: 2, totalHours: 3, agentHours: 0,
            tokensIn: 5, tokensOut: 5, ttsCharacters: 0)
        let c = DeepgramCollector.combine([a, b])
        XCTAssertEqual(c.requests, 150)
        XCTAssertEqual(c.hours, 7, accuracy: 0.0001)
        XCTAssertEqual(c.totalHours, 9, accuracy: 0.0001)
        XCTAssertEqual(c.tokensIn, 15)
        XCTAssertEqual(c.tokensOut, 25)
        XCTAssertEqual(c.ttsCharacters, 30)
    }

    func test_combine_empty_is_zero() {
        XCTAssertEqual(DeepgramCollector.combine([]), DeepgramCollector.UsageAggregate())
    }

    // MARK: - status_text formatting

    func test_statusText_requests_audio_tokens() {
        let s = DeepgramCollector.formatStatusText(
            .init(requests: 1234, hours: 56.7, tokensIn: 1000, tokensOut: 2000))
        XCTAssertEqual(s, "1,234 requests · 56.7 audio hrs · 3,000 tokens")
    }

    func test_statusText_falls_back_to_billable_and_tts() {
        let s = DeepgramCollector.formatStatusText(
            .init(requests: 50, totalHours: 10, ttsCharacters: 4096))
        XCTAssertEqual(s, "50 requests · 10 billable hrs · 4,096 TTS chars")
    }

    func test_statusText_requests_only() {
        XCTAssertEqual(DeepgramCollector.formatStatusText(.init(requests: 0)), "0 requests")
    }

    // MARK: - buildResult: statusOnly

    func test_buildResult_single_named_project() {
        let r = DeepgramCollector.buildResult(
            aggregate: .init(requests: 100, hours: 5), projectName: "My Project", projectCount: 1)
        XCTAssertEqual(r.dataKind, .statusOnly)
        XCTAssertNil(r.usage.quota)
        XCTAssertNil(r.usage.remaining)
        XCTAssertEqual(r.usage.today_usage, 0)
        XCTAssertTrue(r.usage.tiers.isEmpty)
        XCTAssertEqual(r.usage.plan_type, "My Project")
        XCTAssertTrue(r.usage.status_text.contains("100 requests"))
        XCTAssertEqual(r.usage.metadata?.supports_quota, false)
    }

    func test_buildResult_multi_project_plan_label() {
        let r = DeepgramCollector.buildResult(
            aggregate: .init(requests: 500), projectName: nil, projectCount: 3)
        XCTAssertEqual(r.usage.plan_type, "3 projects")
    }

    func test_buildResult_single_unnamed_defaults_plan() {
        let r = DeepgramCollector.buildResult(
            aggregate: .init(requests: 10), projectName: nil, projectCount: 1)
        XCTAssertEqual(r.usage.plan_type, "API key")
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .deepgram)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .deepgram, apiKey: "dg-key")))
        XCTAssertFalse(collector.isAvailable(
            config: ProviderConfig(kind: .deepgram, apiKey: "   ")))
    }

    // MARK: - New ProviderKind case (per the new-ProviderKind checklist)

    func test_providerKind_deepgram_case() {
        XCTAssertEqual(ProviderKind(rawValue: "Deepgram"), .deepgram)
        XCTAssertEqual(ProviderKind.deepgram.rawValue, "Deepgram")
        XCTAssertEqual(ProviderKind.deepgram.iconName, "waveform.path")
        XCTAssertTrue(ProviderKind.allCases.contains(.deepgram))
        XCTAssertEqual(collector.kind, .deepgram)
    }
}
#endif
