// Unit tests for the v1.23.0 Phase C-4 VeniceCollector (4th
// Phase-C api-key provider; .credits + nil-gauge + cap-aware
// per-currency tiers + flexible-Double decoder). macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class VeniceCollectorTests: XCTestCase {
    private let collector = VeniceCollector()

    private func decode(_ json: String) throws -> VeniceCollector.BalanceResponse {
        try VeniceCollector.parseResponse(Data(json.utf8))
    }

    // MARK: - Flexible-Double decoder (the port-gotcha)

    func test_flexibleDouble_accepts_number_form() throws {
        let r = try decode("""
        {"canConsume":true,"consumptionCurrency":"USD",
         "balances":{"diem":null,"usd":12.34},
         "diemEpochAllocation":null}
        """)
        let usd = try XCTUnwrap(r.balances.usd)
        XCTAssertEqual(usd, 12.34, accuracy: 0.001)
        XCTAssertNil(r.balances.diem)
        XCTAssertNil(r.diemEpochAllocation)
    }

    func test_flexibleDouble_accepts_numeric_string() throws {
        let r = try decode("""
        {"canConsume":true,"consumptionCurrency":"DIEM",
         "balances":{"diem":"42.5","usd":"0"},
         "diemEpochAllocation":"100"}
        """)
        let diem = try XCTUnwrap(r.balances.diem)
        let usd = try XCTUnwrap(r.balances.usd)
        let alloc = try XCTUnwrap(r.diemEpochAllocation)
        XCTAssertEqual(diem, 42.5, accuracy: 0.001)
        XCTAssertEqual(usd, 0.0, accuracy: 0.001)
        XCTAssertEqual(alloc, 100.0, accuracy: 0.001)
    }

    func test_flexibleDouble_rejects_non_numeric_string() throws {
        XCTAssertThrowsError(try decode("""
        {"canConsume":true,"consumptionCurrency":"USD",
         "balances":{"diem":null,"usd":"oops"}}
        """))
    }

    func test_parseResponse_missing_required_throws() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{}"))
    }

    // MARK: - statusText 6-branch verbatim port

    private func resp(canConsume: Bool, currency: String?, diem: Double?, usd: Double?,
                      allocation: Double? = nil) throws -> VeniceCollector.BalanceResponse {
        let json = """
        {"canConsume":\(canConsume),"consumptionCurrency":\(currency.map{"\"\($0)\""} ?? "null"),
         "balances":{"diem":\(diem.map{String($0)} ?? "null"),
                      "usd":\(usd.map{String($0)} ?? "null")},
         "diemEpochAllocation":\(allocation.map{String($0)} ?? "null")}
        """
        return try decode(json)
    }

    func test_statusText_unavailable_when_cannot_consume() throws {
        let r = try resp(canConsume: false, currency: "USD", diem: 0, usd: 5)
        XCTAssertEqual(VeniceCollector.statusText(r), "Balance unavailable for API calls")
    }

    func test_statusText_USD_active_positive() throws {
        let r = try resp(canConsume: true, currency: "USD", diem: 0, usd: 9.99)
        XCTAssertEqual(VeniceCollector.statusText(r), "$9.99 USD remaining")
    }

    func test_statusText_DIEM_with_allocation_shows_quota_progress() throws {
        let r = try resp(canConsume: true, currency: "DIEM", diem: 30, usd: 0, allocation: 100)
        XCTAssertEqual(VeniceCollector.statusText(r),
                       "DIEM 30.00 / 100.00 epoch allocation")
    }

    func test_statusText_DIEM_active_without_allocation() throws {
        let r = try resp(canConsume: true, currency: "DIEM", diem: 7.5, usd: 0)
        XCTAssertEqual(VeniceCollector.statusText(r), "DIEM 7.50 remaining")
    }

    func test_statusText_fallback_positive_diem() throws {
        let r = try resp(canConsume: true, currency: nil, diem: 3, usd: 0)
        XCTAssertEqual(VeniceCollector.statusText(r), "DIEM 3.00 remaining")
    }

    func test_statusText_fallback_positive_usd() throws {
        let r = try resp(canConsume: true, currency: nil, diem: 0, usd: 4)
        XCTAssertEqual(VeniceCollector.statusText(r), "$4.00 USD remaining")
    }

    func test_statusText_all_zero_no_balance() throws {
        let r = try resp(canConsume: true, currency: "USD", diem: 0, usd: 0)
        XCTAssertEqual(VeniceCollector.statusText(r), "No Venice API balance available")
    }

    // MARK: - buildResult: .credits, nil-gauge, cap-aware tiers

    func test_buildResult_nil_top_level_gauge() throws {
        let r = try resp(canConsume: true, currency: "USD", diem: 0, usd: 5)
        let result = collector.buildResult(r)
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertNil(u.remaining)
        XCTAssertEqual(u.today_usage, 0)
        XCTAssertEqual(u.week_usage, 0)
        XCTAssertEqual(u.plan_type, "API key")
        XCTAssertNil(u.reset_time)
    }

    func test_buildResult_DIEM_tier_with_allocation_is_quota_form() throws {
        // DIEM 30 / 100 allocation ⇒ DIEM tier quota=10000 (cents),
        // remaining=3000 (cents). The real cap shows at the tier.
        let r = try resp(canConsume: true, currency: "DIEM",
                         diem: 30, usd: 0, allocation: 100)
        let u = collector.buildResult(r).usage
        let diem = u.tiers.first { $0.name == "DIEM Balance" }
        XCTAssertEqual(diem?.quota, 10_000)
        XCTAssertEqual(diem?.remaining, 3_000)
    }

    func test_buildResult_DIEM_tier_no_cap_is_quota_equals_remaining() throws {
        // No allocation, positive diem ⇒ DeepSeek no-cap form.
        let r = try resp(canConsume: true, currency: "DIEM", diem: 7.5, usd: 0)
        let u = collector.buildResult(r).usage
        let diem = u.tiers.first { $0.name == "DIEM Balance" }
        XCTAssertEqual(diem?.quota, 750)
        XCTAssertEqual(diem?.remaining, 750)
    }

    func test_buildResult_DIEM_tier_clamps_balance_to_cap() throws {
        // Balance exceeds allocation ⇒ remaining clamped to cap.
        let r = try resp(canConsume: true, currency: "DIEM",
                         diem: 200, usd: 0, allocation: 100)
        let u = collector.buildResult(r).usage
        let diem = u.tiers.first { $0.name == "DIEM Balance" }
        XCTAssertEqual(diem?.quota, 10_000)
        XCTAssertEqual(diem?.remaining, 10_000)   // clamped (min cap, cents)
    }

    func test_buildResult_USD_tier_no_cap() throws {
        let r = try resp(canConsume: true, currency: "USD", diem: 0, usd: 12.34)
        let u = collector.buildResult(r).usage
        let usd = u.tiers.first { $0.name == "USD Balance" }
        XCTAssertEqual(usd?.quota, 1234)
        XCTAssertEqual(usd?.remaining, 1234)
    }

    func test_buildResult_skips_zero_balance_tier_when_no_cap() throws {
        let r = try resp(canConsume: true, currency: "USD", diem: 0, usd: 0)
        let u = collector.buildResult(r).usage
        // Zero balances + no allocation ⇒ no tiers.
        XCTAssertTrue(u.tiers.isEmpty)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .venice)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .venice, apiKey: "vn-test")))
        XCTAssertFalse(collector.isAvailable(
            config: ProviderConfig(kind: .venice, apiKey: "  ")))
    }

    // MARK: - New ProviderKind case (4th consecutive)

    func test_providerKind_venice_case() {
        XCTAssertEqual(ProviderKind(rawValue: "Venice"), .venice)
        XCTAssertEqual(ProviderKind.venice.rawValue, "Venice")
        XCTAssertEqual(ProviderKind.venice.iconName, "v.circle")
        XCTAssertTrue(ProviderKind.allCases.contains(.venice))
        XCTAssertEqual(collector.kind, .venice)
    }
}
#endif
