// Unit tests for the v1.23.0 Phase C-2 DeepSeekCollector (new
// api-key credits-only provider). Locks the Gemini Phase-C2 R1
// adoptions: string→Double balance decode, multi-currency
// selection, nil-gauge mapping (quota/remaining=nil, today/week=0),
// per-currency TierDTOs, and the status_text formats. macOS-gated
// like the other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class DeepSeekCollectorTests: XCTestCase {
    private let collector = DeepSeekCollector()

    private func decode(_ json: String) throws -> DeepSeekCollector.BalanceResponse {
        try DeepSeekCollector.parseResponse(Data(json.utf8))
    }

    // MARK: - Parse: snake_case + string→Double

    func test_parseResponse_decodes_snake_case() throws {
        let r = try decode("""
        {"is_available": true, "balance_infos": [
          {"currency":"USD","total_balance":"12.34","granted_balance":"5.00","topped_up_balance":"7.34"}
        ]}
        """)
        XCTAssertTrue(r.isAvailable)
        XCTAssertEqual(r.balanceInfos.count, 1)
        XCTAssertEqual(r.balanceInfos[0].currency, "USD")
        XCTAssertEqual(r.balanceInfos[0].totalBalance, "12.34")
    }

    func test_parseBalances_string_to_double() throws {
        let r = try decode("""
        {"is_available": true, "balance_infos": [
          {"currency":"CNY","total_balance":"100.50","granted_balance":"50","topped_up_balance":"50.50"}
        ]}
        """)
        let b = try DeepSeekCollector.parseBalances(r)
        XCTAssertEqual(b.count, 1)
        XCTAssertEqual(b[0].currency, "CNY")
        XCTAssertEqual(b[0].totalBalance, 100.50, accuracy: 0.0001)
        XCTAssertEqual(b[0].grantedBalance, 50.0, accuracy: 0.0001)
        XCTAssertEqual(b[0].toppedUpBalance, 50.50, accuracy: 0.0001)
    }

    func test_parseBalances_non_numeric_throws() throws {
        let r = try decode("""
        {"is_available": true, "balance_infos": [
          {"currency":"USD","total_balance":"oops","granted_balance":"0","topped_up_balance":"0"}
        ]}
        """)
        XCTAssertThrowsError(try DeepSeekCollector.parseBalances(r))
    }

    func test_parseResponse_invalid_throws() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{}"))  // missing required keys
    }

    // MARK: - Multi-balance selection (USD-positive → any-positive → USD → first)

    private func bal(_ ccy: String, _ total: Double, _ paid: Double = 0, _ granted: Double = 0)
        -> DeepSeekCollector.Balance
    {
        .init(currency: ccy, totalBalance: total, grantedBalance: granted, toppedUpBalance: paid)
    }

    func test_select_prefers_USD_positive() {
        let pick = DeepSeekCollector.selectPrimary([
            bal("CNY", 100), bal("USD", 5), bal("EUR", 0),
        ])
        XCTAssertEqual(pick?.currency, "USD")
    }

    func test_select_any_positive_when_no_USD_positive() {
        let pick = DeepSeekCollector.selectPrimary([
            bal("USD", 0), bal("CNY", 30),
        ])
        XCTAssertEqual(pick?.currency, "CNY")
    }

    func test_select_falls_back_to_USD_zero() {
        let pick = DeepSeekCollector.selectPrimary([
            bal("USD", 0), bal("CNY", 0),
        ])
        XCTAssertEqual(pick?.currency, "USD")
    }

    func test_select_first_when_no_USD_at_all() {
        let pick = DeepSeekCollector.selectPrimary([bal("CNY", 0), bal("EUR", 0)])
        XCTAssertEqual(pick?.currency, "CNY")
    }

    func test_select_empty_returns_nil() {
        XCTAssertNil(DeepSeekCollector.selectPrimary([]))
    }

    // MARK: - status_text formatting

    func test_statusText_funded_USD() {
        let s = DeepSeekCollector.formatStatusText(
            isAvailable: true, primary: bal("USD", 12.34, 7.34, 5.00))
        XCTAssertEqual(s, "$12.34 (Paid: $7.34 / Granted: $5.00)")
    }

    func test_statusText_CNY_uses_yuan_symbol() {
        let s = DeepSeekCollector.formatStatusText(
            isAvailable: true, primary: bal("CNY", 100, 80, 20))
        XCTAssertTrue(s.hasPrefix("¥100.00"))
    }

    func test_statusText_zero_balance_prompts_topup() {
        let s = DeepSeekCollector.formatStatusText(
            isAvailable: true, primary: bal("USD", 0))
        XCTAssertEqual(s, "$0.00 — add credits at platform.deepseek.com")
    }

    func test_statusText_unavailable_when_disabled() {
        let s = DeepSeekCollector.formatStatusText(
            isAvailable: false, primary: bal("USD", 5))
        XCTAssertEqual(s, "Balance unavailable for API calls")
    }

    // MARK: - buildResult: nil-gauge + per-currency tiers (.credits)

    func test_buildResult_nil_gauge_and_per_currency_tiers() {
        let r = collector.buildResult(
            isAvailable: true,
            balances: [bal("USD", 12.34, 7.34, 5.00), bal("CNY", 100, 80, 20)])
        XCTAssertEqual(r.dataKind, .credits)
        let u = r.usage
        // No-gauge (Gemini R1 HIGH): nil quota/remaining, zero today/week.
        XCTAssertNil(u.quota)
        XCTAssertNil(u.remaining)
        XCTAssertEqual(u.today_usage, 0)
        XCTAssertEqual(u.week_usage, 0)
        XCTAssertEqual(u.plan_type, "API key")
        XCTAssertNil(u.reset_time)
        // Per-currency tiers (Gemini R1 MEDIUM); both positive ⇒ 2.
        XCTAssertEqual(u.tiers.count, 2)
        let usd = u.tiers.first { $0.name == "USD Balance" }
        XCTAssertEqual(usd?.quota, 1234)        // 12.34 → cents
        XCTAssertEqual(usd?.remaining, 1234)    // no usage tracked
        let cny = u.tiers.first { $0.name == "CNY Balance" }
        XCTAssertEqual(cny?.quota, 10000)       // 100.00 → cents
        XCTAssertTrue(u.status_text.contains("$12.34"))
    }

    func test_buildResult_skips_zero_balance_tiers() {
        let r = collector.buildResult(
            isAvailable: true,
            balances: [bal("USD", 0), bal("CNY", 50)])
        XCTAssertEqual(r.usage.tiers.count, 1)
        XCTAssertEqual(r.usage.tiers.first?.name, "CNY Balance")
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .deepseek)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .deepseek, apiKey: "sk-deepseek")))
        XCTAssertFalse(collector.isAvailable(
            config: ProviderConfig(kind: .deepseek, apiKey: "  ")))
    }

    // MARK: - New ProviderKind case (per the new-ProviderKind checklist)

    func test_providerKind_deepseek_case() {
        XCTAssertEqual(ProviderKind(rawValue: "DeepSeek"), .deepseek)
        XCTAssertEqual(ProviderKind.deepseek.rawValue, "DeepSeek")
        XCTAssertEqual(ProviderKind.deepseek.iconName, "d.circle")
        XCTAssertTrue(ProviderKind.allCases.contains(.deepseek))
        XCTAssertEqual(collector.kind, .deepseek)
    }
}
#endif
