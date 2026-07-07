// Unit tests for the v1.40 PR-7 CurrencyConverter: display-time USD→currency
// conversion, per-currency formatting (symbol + fraction digits + grouping +
// small-value convention), open.er-api rate parse, and 24h TTL freshness.

import XCTest
@testable import CLIPulseCore

final class CurrencyConverterTests: XCTestCase {

    private func makeConverter() -> CurrencyConverter {
        // Empty suite ⇒ hardcoded fallback rates (USD 1, CNY 7.15, JPY 150, …).
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        return CurrencyConverter(defaults: suite)
    }

    func test_format_usd_default() {
        let c = makeConverter()
        c.setCurrency(.usd)
        XCTAssertEqual(c.format(12.5), "$12.50")
        XCTAssertEqual(c.format(1234.5), "$1,234.50")
    }

    func test_format_cny_uses_yen_symbol_and_rate() {
        let c = makeConverter()
        c.setCurrency(.cny)
        // 10 USD × 7.15 = 71.50
        XCTAssertEqual(c.format(10), "¥71.50")
    }

    func test_format_jpy_zero_decimals_grouped() {
        let c = makeConverter()
        c.setCurrency(.jpy)
        // 12.5 USD × 150 = 1875 → ¥1,875 (no decimals)
        XCTAssertEqual(c.format(12.5), "¥1,875")
    }

    func test_format_twd_symbol() {
        let c = makeConverter()
        c.setCurrency(.twd)
        XCTAssertTrue(c.format(10).hasPrefix("NT$"), c.format(10))
    }

    func test_format_small_value_convention() {
        let c = makeConverter()
        c.setCurrency(.usd)
        XCTAssertEqual(c.format(0.001), "<$0.01")
        XCTAssertEqual(c.format(0), "$0.00")     // exactly zero is not "<"
        c.setCurrency(.jpy)
        XCTAssertEqual(c.format(0.001), "<¥1")   // 0-decimal smallest unit is 1
    }

    func test_convert_and_rate() {
        let c = makeConverter()
        c.setCurrency(.eur)
        XCTAssertEqual(c.rate(), 0.92, accuracy: 0.0001)
        XCTAssertEqual(c.convert(100), 92, accuracy: 0.001)
    }

    func test_cached_rates_override_fallback() {
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        suite.set(["CNY": 7.0], forKey: CurrencyConverter.ratesKey)
        let c = CurrencyConverter(defaults: suite)
        c.setCurrency(.cny)
        XCTAssertEqual(c.rate(), 7.0, accuracy: 0.0001)   // cached beats fallback 7.15
        XCTAssertEqual(c.convert(10), 70, accuracy: 0.001)
    }

    // MARK: - parseRates

    func test_parseRates_success_shape() {
        let json = #"{"result":"success","base_code":"USD","rates":{"USD":1,"CNY":7.1,"EUR":0.92}}"#
        let parsed = CurrencyConverter.parseRates(Data(json.utf8))
        XCTAssertEqual(parsed?["CNY"] ?? -1, 7.1, accuracy: 0.001)
        XCTAssertEqual(parsed?["EUR"] ?? -1, 0.92, accuracy: 0.001)
    }

    func test_parseRates_non_success_is_nil() {
        XCTAssertNil(CurrencyConverter.parseRates(Data(#"{"result":"error","rates":{"CNY":7}}"#.utf8)))
    }

    func test_parseRates_invalid_is_nil() {
        XCTAssertNil(CurrencyConverter.parseRates(Data("not json".utf8)))
        XCTAssertNil(CurrencyConverter.parseRates(Data(#"{"result":"success"}"#.utf8)))   // no rates
    }

    // MARK: - TTL

    func test_refreshRatesIfStale_skips_when_fresh() async {
        let suite = UserDefaults(suiteName: "fx-\(UUID().uuidString)")!
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        suite.set(now.timeIntervalSince1970, forKey: CurrencyConverter.fetchedAtKey)
        suite.set(["CNY": 7.0], forKey: CurrencyConverter.ratesKey)
        let c = CurrencyConverter(defaults: suite)
        // 1 hour later → within 24h TTL → no fetch, cached rate preserved.
        await c.refreshRatesIfStale(now: now.addingTimeInterval(3600))
        c.setCurrency(.cny)
        XCTAssertEqual(c.rate(), 7.0, accuracy: 0.0001)
    }
}
