// Unit tests for the v1.40.0 CrossModelCollector (CodexBar parity). Locks the
// design: micro-unit ÷1_000_000 credits/usage parse, currency normalization +
// required-currency gate, HTTPS-or-loopback endpoint-override validation, the
// currency-mismatch drop, and the `.credits` status text. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CrossModelCollectorTests: XCTestCase {
    private let collector = CrossModelCollector()

    // MARK: - parseCredits

    func test_parseCredits_success() throws {
        let c = try CrossModelCollector.parseCredits(Data(#"""
        {"currency":"usd","balance_micro":12500000,"uncollected_micro":250000}
        """#.utf8))
        XCTAssertEqual(c.currency, "USD")               // normalized upper
        XCTAssertEqual(c.balance, 12.5, accuracy: 0.0001)
        XCTAssertEqual(c.uncollected, 0.25, accuracy: 0.0001)
    }

    func test_parseCredits_missing_currency_throws() {
        XCTAssertThrowsError(try CrossModelCollector.parseCredits(Data(#"""
        {"currency":"","balance_micro":1,"uncollected_micro":0}
        """#.utf8))) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_parseCredits_invalid_json_throws() {
        XCTAssertThrowsError(try CrossModelCollector.parseCredits(Data("nope".utf8))) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - parseUsage

    func test_parseUsage_success() throws {
        let u = try CrossModelCollector.parseUsage(Data(#"""
        {"currency":"USD",
         "daily":{"cost_micro":1500000,"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"request_count":1,"success_count":1},
         "weekly":{"cost_micro":7000000,"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"request_count":1,"success_count":1},
         "monthly":{"cost_micro":30000000,"prompt_tokens":1,"completion_tokens":1,"total_tokens":2,"request_count":1,"success_count":1}}
        """#.utf8))
        XCTAssertEqual(u.dailyCost, 1.5, accuracy: 0.0001)
        XCTAssertEqual(u.monthlyCost, 30, accuracy: 0.0001)
    }

    // MARK: - buildResult

    func test_buildResult_balance_only() {
        let result = CrossModelCollector.buildResult(
            credits: .init(currency: "USD", balance: 12.5, uncollected: 0), usage: nil)
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertEqual(u.remaining, 1_250_000)          // $12.5 × 100_000 magnitude
        XCTAssertEqual(u.provider, "CrossModel")
        XCTAssertTrue(u.status_text.contains("Balance"), u.status_text)
        XCTAssertFalse(u.status_text.contains("Today"), u.status_text)
    }

    func test_buildResult_with_usage_shows_today_and_month() {
        let result = CrossModelCollector.buildResult(
            credits: .init(currency: "USD", balance: 100, uncollected: 5),
            usage: .init(currency: "USD", dailyCost: 1.5, weeklyCost: 7, monthlyCost: 30))
        let s = result.usage.status_text
        XCTAssertTrue(s.contains("uncollected"), s)
        XCTAssertTrue(s.contains("Today"), s)
        XCTAssertTrue(s.contains("Month"), s)
    }

    // MARK: - endpoint override validation

    func test_validatedOverride() {
        XCTAssertNotNil(CrossModelCollector.validatedOverride("https://api.example.com/v1"))
        XCTAssertNotNil(CrossModelCollector.validatedOverride("http://localhost:8080/v1"))
        XCTAssertNotNil(CrossModelCollector.validatedOverride("http://127.0.0.1:9000"))
        XCTAssertNil(CrossModelCollector.validatedOverride("http://api.example.com/v1"))   // remote HTTP rejected
        XCTAssertNil(CrossModelCollector.validatedOverride("ftp://example.com"))
        XCTAssertNil(CrossModelCollector.validatedOverride("garbage"))
    }

    // MARK: - helpers

    func test_units_and_majorUnits() {
        XCTAssertEqual(CrossModelCollector.units(1), 100_000)
        XCTAssertEqual(CrossModelCollector.units(-5), 0)
        XCTAssertEqual(CrossModelCollector.majorUnits(2_500_000), 2.5, accuracy: 0.0001)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .crossModel, apiKey: "cm-test")))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .crossModel)))
    }
}
#endif
