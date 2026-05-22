// Unit tests for the v1.23.0 Phase C-10 MistralCollector (CodexBar parity —
// cookie batch #3). Locks the Gemini C-10 R1 design: `.statusOnly` exact
// month-to-date spend, the token×price aggregation across categories
// (valuePaid preferred, price-miss → 0, flat-pricing nil-group key, refund
// clamp), and the ory_session_/csrftoken cookie handling. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class MistralCollectorTests: XCTestCase {
    private let collector = MistralCollector()

    private func parse(_ json: String) throws -> MistralCollector.MistralUsage {
        try MistralCollector.parseUsage(Data(json.utf8))
    }

    // MARK: - parseUsage aggregation

    func test_parseUsage_aggregates_cost_and_tokens() throws {
        // completion: 1000 input × .001 = 1.0 (+1000 tok); output valuePaid 500
        // × .003 = 1.5 (+500 tok, value 999 ignored). ocr: 10 × .01 = 0.1 (cost
        // only). total = 2.6, tokens = 1500.
        let u = try parse("""
        {
          "currency": "USD", "currency_symbol": "$",
          "start_date": "2025-06-01T00:00:00Z", "end_date": "2025-06-30T23:59:59Z",
          "prices": [
            {"billing_metric":"input_tokens","billing_group":"large","price":"0.001"},
            {"billing_metric":"output_tokens","billing_group":"large","price":"0.003"},
            {"billing_metric":"ocr_pages","billing_group":"ocr","price":"0.01"}
          ],
          "completion": {"models": {"large": {
            "input": [{"billing_metric":"input_tokens","billing_group":"large","value":1000}],
            "output": [{"billing_metric":"output_tokens","billing_group":"large","value_paid":500,"value":999}]
          }}},
          "ocr": {"models": {"ocr-1": {
            "input": [{"billing_metric":"ocr_pages","billing_group":"ocr","value":10}]
          }}}
        }
        """)
        XCTAssertEqual(u.totalCost, 2.6, accuracy: 0.0001)
        XCTAssertEqual(u.totalTokens, 1500)        // completion only; ocr excluded
        XCTAssertEqual(u.currency, "USD")
        XCTAssertEqual(u.currencySymbol, "$")
        XCTAssertEqual(ISO8601DateFormatter().string(from: try XCTUnwrap(u.endDate)),
                       "2025-06-30T23:59:59Z")
    }

    func test_parseUsage_price_miss_contributes_zero_cost_but_counts_tokens() throws {
        let u = try parse("""
        { "prices": [],
          "completion": {"models": {"m": {
            "input": [{"billing_metric":"unknown","billing_group":"x","value":700}]
          }}} }
        """)
        XCTAssertEqual(u.totalCost, 0, accuracy: 0.0001)   // no matching price
        XCTAssertEqual(u.totalTokens, 700)                 // tokens still counted
    }

    func test_parseUsage_flat_pricing_nil_group_matches() throws {
        // price + entry both omit billing_group ⇒ key "flat::" matches.
        let u = try parse("""
        { "prices": [{"billing_metric":"flat","price":"2.5"}],
          "completion": {"models": {"m": {"input": [{"billing_metric":"flat","value":4}]}}} }
        """)
        XCTAssertEqual(u.totalCost, 10, accuracy: 0.0001)
    }

    func test_parseUsage_negative_cost_clamped_to_zero() throws {
        let u = try parse("""
        { "prices": [{"billing_metric":"refund","billing_group":"g","price":"-5.0"}],
          "completion": {"models": {"m": {"input": [{"billing_metric":"refund","billing_group":"g","value":3}]}}} }
        """)
        XCTAssertEqual(u.totalCost, 0, accuracy: 0.0001)   // -15 clamped
    }

    func test_parseUsage_defaults_currency_eur() throws {
        let u = try parse(#"{"completion":{"models":{}}}"#)
        XCTAssertEqual(u.currency, "EUR")
        XCTAssertEqual(u.currencySymbol, "€")
        XCTAssertEqual(u.totalCost, 0, accuracy: 0.0001)
        XCTAssertEqual(u.totalTokens, 0)
    }

    func test_parseUsage_invalid_json_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else {
                return XCTFail("expected parseFailed, got \($0)")
            }
        }
    }

    // MARK: - buildResult (.statusOnly with exact cost)

    func test_buildResult_statusOnly_with_cost_and_tokens() throws {
        let end = Date(timeIntervalSince1970: 1_750_000_000)
        let result = MistralCollector.buildResult(.init(
            totalCost: 2.6, currency: "USD", currencySymbol: "$",
            totalTokens: 1500, startDate: nil, endDate: end))
        XCTAssertEqual(result.dataKind, .statusOnly)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertNil(u.remaining)
        XCTAssertEqual(u.estimated_cost_week, 2.6, accuracy: 0.0001)
        XCTAssertEqual(u.cost_status_week, "Exact")
        XCTAssertEqual(u.week_usage, 1500)
        XCTAssertEqual(u.plan_type, "Pay-as-you-go")
        XCTAssertEqual(u.metadata?.supports_exact_cost, true)
        XCTAssertEqual(u.metadata?.supports_quota, false)
        XCTAssertTrue(u.status_text.contains("$2.6000 this month"), u.status_text)
        XCTAssertTrue(u.status_text.contains("1,500 tokens"), u.status_text)
        let resetISO = try XCTUnwrap(u.reset_time)
        XCTAssertEqual(try XCTUnwrap(sharedISO8601Parse(resetISO)).timeIntervalSince1970,
                       1_750_000_000, accuracy: 1)
    }

    func test_buildResult_zero_tokens_omits_token_suffix() {
        let u = MistralCollector.buildResult(.init(
            totalCost: 0, currency: "EUR", currencySymbol: "€",
            totalTokens: 0, startDate: nil, endDate: nil)).usage
        XCTAssertTrue(u.status_text.contains("€0.0000 this month"), u.status_text)
        XCTAssertFalse(u.status_text.contains("tokens"), u.status_text)
        XCTAssertNil(u.reset_time)
    }

    // MARK: - sessionAndCSRF

    func test_sessionAndCSRF_extracts_both() {
        let r = MistralCollector.sessionAndCSRF(
            fromHeader: "ory_session_abc123=zzz; csrftoken=tok42; other=x")
        XCTAssertTrue(r.hasSession)
        XCTAssertEqual(r.csrf, "tok42")
    }

    func test_sessionAndCSRF_no_session_cookie() {
        let r = MistralCollector.sessionAndCSRF(fromHeader: "_ga=1; csrftoken=tok42")
        XCTAssertFalse(r.hasSession)
        XCTAssertEqual(r.csrf, "tok42")
    }

    func test_sessionAndCSRF_csrf_absent_is_nil() {
        let r = MistralCollector.sessionAndCSRF(fromHeader: "ory_session_x=zzz")
        XCTAssertTrue(r.hasSession)
        XCTAssertNil(r.csrf)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .mistral)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .mistral, manualCookieHeader: "ory_session_x=y")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .mistral, cookieSource: .automatic)))
    }
}
#endif
