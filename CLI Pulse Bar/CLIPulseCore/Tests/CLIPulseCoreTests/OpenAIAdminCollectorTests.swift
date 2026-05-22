// Unit tests for the v1.23.0 Phase C-15 OpenAIAdminCollector (CodexBar parity
// — niche batch). Locks the Gemini C-15 R1 design: sum month-to-date cost from
// /organization/costs, flexible amount decode, empty→$0 (no throw), and the
// `.statusOnly` exact-spend mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class OpenAIAdminCollectorTests: XCTestCase {
    private let collector = OpenAIAdminCollector()

    private func parse(_ json: String) throws -> (total: Double, currency: String) {
        try OpenAIAdminCollector.parseCosts(Data(json.utf8))
    }

    // MARK: - parseCosts

    func test_parseCosts_sums_across_buckets() throws {
        let (total, currency) = try parse("""
        {"data":[
          {"results":[{"amount":{"value":1.5,"currency":"USD"}}]},
          {"results":[{"amount":{"value":2.5,"currency":"USD"}},
                      {"amount":{"value":0.25,"currency":"USD"}}]}
        ]}
        """)
        XCTAssertEqual(total, 4.25, accuracy: 0.0001)
        XCTAssertEqual(currency, "USD")
    }

    func test_parseCosts_flexible_string_value() throws {
        let (total, _) = try parse(#"{"data":[{"results":[{"amount":{"value":"3.25"}}]}]}"#)
        XCTAssertEqual(total, 3.25, accuracy: 0.0001)
    }

    func test_parseCosts_missing_amount_contributes_zero() throws {
        let (total, _) = try parse("""
        {"data":[{"results":[{"amount":{"value":2.0}},{}]}]}
        """)
        XCTAssertEqual(total, 2.0, accuracy: 0.0001)
    }

    func test_parseCosts_empty_data_is_zero_usd() throws {
        let (total, currency) = try parse(#"{"data":[]}"#)
        XCTAssertEqual(total, 0, accuracy: 0.0001)
        XCTAssertEqual(currency, "USD")    // default
    }

    func test_parseCosts_invalid_json_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult

    func test_buildResult_statusOnly_exact_cost() {
        let result = OpenAIAdminCollector.buildResult(total: 4.25, currency: "USD")
        XCTAssertEqual(result.dataKind, .statusOnly)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertEqual(u.estimated_cost_week, 4.25, accuracy: 0.0001)
        XCTAssertEqual(u.cost_status_week, "Exact")
        XCTAssertEqual(u.plan_type, "Admin API")
        XCTAssertEqual(u.metadata?.supports_exact_cost, true)
        XCTAssertEqual(u.status_text, "$4.25 this month")
    }

    func test_buildResult_non_usd_currency_prefix() {
        let u = OpenAIAdminCollector.buildResult(total: 5, currency: "EUR").usage
        XCTAssertEqual(u.status_text, "EUR 5.00 this month")
    }

    // MARK: - Availability

    func test_isAvailable_with_key() {
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .openaiAdmin, apiKey: "sk-admin-test")))
    }
}
#endif
