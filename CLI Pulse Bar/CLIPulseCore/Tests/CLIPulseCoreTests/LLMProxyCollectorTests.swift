// Unit tests for the v1.23.0 Phase C-14 LLMProxyCollector (CodexBar parity —
// niche batch, self-hosted gateway). Locks the Gemini C-14 R1 adoptions:
// array-or-keyed-object quota_groups decode, empty-providers safety,
// summary-preferred totals, v1 path dedup, and the `.statusOnly` aggregate
// mapping (no synthetic 100-unit quota). macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class LLMProxyCollectorTests: XCTestCase {
    private let collector = LLMProxyCollector()

    private func parse(_ json: String) throws -> LLMProxyCollector.Stats {
        try LLMProxyCollector.parseSnapshot(Data(json.utf8))
    }

    // MARK: - parseSnapshot

    func test_parse_aggregates_across_providers() throws {
        let s = try parse("""
        {"providers":{
          "openai":{"credential_count":3,"active_count":2,"total_requests":100,
            "tokens":{"input_cached":10,"input_uncached":20,"output":30},"approx_cost":1.5,
            "quota_groups":[{"remaining_percent":40,"reset_time":"2025-06-15T13:46:40Z"}]},
          "anthropic":{"credential_count":2,"active_count":1,"total_requests":50,
            "tokens":{"input_uncached":5,"output":5},"approx_cost":0.5,
            "quota_groups":[{"remaining_percent":80,"reset_time":"2025-07-01T00:00:00Z"}]}
        }}
        """)
        XCTAssertEqual(s.providerCount, 2)
        XCTAssertEqual(s.totalKeys, 5)
        XCTAssertEqual(s.activeKeys, 3)
        XCTAssertEqual(s.totalRequests, 150)
        XCTAssertEqual(s.totalTokens, 70)
        XCTAssertEqual(s.approxCostUSD ?? 0, 2.0, accuracy: 0.001)
        XCTAssertEqual(s.minRemainingPercent ?? -1, 40, accuracy: 0.001)   // min across groups
        XCTAssertEqual(ISO8601DateFormatter().string(from: try XCTUnwrap(s.nextResetAt)),
                       "2025-06-15T13:46:40Z")                              // earliest reset
    }

    func test_parse_quota_groups_keyed_object() throws {
        let s = try parse("""
        {"providers":{"x":{"quota_groups":{"daily":{"remaining_percent":25,
          "reset_time":"2025-06-15T13:46:40Z"}}}}}
        """)
        XCTAssertEqual(s.minRemainingPercent ?? -1, 25, accuracy: 0.001)
    }

    func test_parse_summary_totals_preferred() throws {
        let s = try parse("""
        {"providers":{"x":{"total_requests":10,"tokens":{"output":10}}},
         "summary":{"total_requests":999,"total_tokens":888,"approx_cost":7.0}}
        """)
        XCTAssertEqual(s.totalRequests, 999)
        XCTAssertEqual(s.totalTokens, 888)
        XCTAssertEqual(s.approxCostUSD ?? 0, 7.0, accuracy: 0.001)
    }

    func test_parse_empty_providers_safe() throws {
        let s = try parse(#"{"providers":{}}"#)
        XCTAssertEqual(s.providerCount, 0)
        XCTAssertEqual(s.totalRequests, 0)
        XCTAssertNil(s.minRemainingPercent)
        XCTAssertNil(s.approxCostUSD)
    }

    func test_parse_invalid_json_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult

    func test_buildResult_with_quota_and_cost() {
        let result = LLMProxyCollector.buildResult(.init(
            providerCount: 2, totalKeys: 5, activeKeys: 3, totalRequests: 150,
            totalTokens: 70, approxCostUSD: 2.0, minRemainingPercent: 40, nextResetAt: nil))
        XCTAssertEqual(result.dataKind, .statusOnly)
        let u = result.usage
        XCTAssertNil(u.quota)                       // no synthetic 100-unit quota
        XCTAssertEqual(u.estimated_cost_week, 2.0, accuracy: 0.001)
        XCTAssertEqual(u.cost_status_week, "Estimated")
        XCTAssertEqual(u.plan_type, "Self-hosted")
        XCTAssertEqual(u.status_text, "40% left · 3/5 keys · 150 req · 70 tok")
    }

    func test_buildResult_no_quota_no_cost() {
        let u = LLMProxyCollector.buildResult(.init(
            providerCount: 1, totalKeys: 2, activeKeys: 2, totalRequests: 0,
            totalTokens: 0, approxCostUSD: nil, minRemainingPercent: nil, nextResetAt: nil)).usage
        XCTAssertEqual(u.cost_status_week, "Unavailable")
        XCTAssertEqual(u.status_text, "2/2 keys")    // no %-left prefix, no req/tok
    }

    // MARK: - quotaStatsURL (v1 dedup + trailing slash)

    func test_quotaStatsURL_variants() {
        XCTAssertEqual(LLMProxyCollector.quotaStatsURL(base: "https://proxy.local")?.absoluteString,
                       "https://proxy.local/v1/quota-stats")
        XCTAssertEqual(LLMProxyCollector.quotaStatsURL(base: "https://proxy.local/")?.absoluteString,
                       "https://proxy.local/v1/quota-stats")
        XCTAssertEqual(LLMProxyCollector.quotaStatsURL(base: "https://proxy.local/v1")?.absoluteString,
                       "https://proxy.local/v1/quota-stats")
        XCTAssertEqual(LLMProxyCollector.quotaStatsURL(base: "https://proxy.local/api/v1")?.absoluteString,
                       "https://proxy.local/api/v1/quota-stats")
    }

    // MARK: - Availability (requires BOTH key and base URL env)

    func test_isAvailable_requires_key_and_base() {
        // base URL comes from LLM_PROXY_BASE_URL (unset in test env) ⇒ false
        // even with a key present.
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .llmProxy)))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .llmProxy, apiKey: "x")))
    }
}
#endif
