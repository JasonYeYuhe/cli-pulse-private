// Unit tests for the v1.23.0 Phase C-13 MoonshotCollector (CodexBar parity —
// niche batch #2). Locks the Gemini C-13 R1 design: code/status success gate,
// `.credits` uncapped USD balance ($1=100_000 units), absolute-value deficit
// display, and skipping negative cash as a tier. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class MoonshotCollectorTests: XCTestCase {
    private let collector = MoonshotCollector()

    private func parse(_ json: String) throws -> MoonshotCollector.MoonshotBalance {
        try MoonshotCollector.parseBalance(Data(json.utf8))
    }

    // MARK: - parseBalance

    func test_parseBalance_success() throws {
        let b = try parse("""
        {"code":0,"status":true,"scode":"0x0",
         "data":{"available_balance":12.5,"voucher_balance":5,"cash_balance":7.5}}
        """)
        XCTAssertEqual(b.available, 12.5, accuracy: 0.001)
        XCTAssertEqual(b.voucher, 5, accuracy: 0.001)
        XCTAssertEqual(b.cash, 7.5, accuracy: 0.001)
    }

    func test_parseBalance_preserves_negative_cash() throws {
        let b = try parse("""
        {"code":0,"status":true,"data":{"available_balance":0,"voucher_balance":0,"cash_balance":-3}}
        """)
        XCTAssertEqual(b.cash, -3, accuracy: 0.001)
    }

    func test_parseBalance_failure_gate_throws() {
        for json in [
            #"{"code":1,"status":true,"data":{"available_balance":0,"voucher_balance":0,"cash_balance":0}}"#,
            #"{"code":0,"status":false,"data":{"available_balance":0,"voucher_balance":0,"cash_balance":0}}"#,
            "not json",
        ] {
            XCTAssertThrowsError(try parse(json)) {
                guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed: \(json)") }
            }
        }
    }

    // MARK: - buildResult

    func test_buildResult_positive_balance() throws {
        let result = MoonshotCollector.buildResult(.init(available: 12.5, voucher: 5, cash: 7.5))
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        XCTAssertNil(u.quota)                       // uncapped
        XCTAssertEqual(u.remaining, 1_250_000)      // $12.5 × 100_000
        XCTAssertEqual(u.plan_type, "API key")
        XCTAssertEqual(u.metadata?.supports_quota, false)
        XCTAssertTrue(u.status_text.contains("Balance: $12.50"), u.status_text)
        XCTAssertFalse(u.status_text.contains("deficit"), u.status_text)
        XCTAssertEqual(u.tiers.first { $0.name == "Voucher" }?.remaining, 500_000)
        XCTAssertEqual(u.tiers.first { $0.name == "Cash" }?.remaining, 750_000)
    }

    func test_buildResult_deficit_shows_absolute_value_and_skips_tier() {
        let u = MoonshotCollector.buildResult(.init(available: 0, voucher: 0, cash: -3)).usage
        XCTAssertEqual(u.remaining, 0)
        XCTAssertTrue(u.status_text.contains("Balance: $0.00"), u.status_text)
        XCTAssertTrue(u.status_text.contains("$3.00 in deficit"), u.status_text)  // abs value
        XCTAssertTrue(u.tiers.isEmpty, "negative cash must not be a tier")
    }

    func test_units_scaling() {
        XCTAssertEqual(MoonshotCollector.units(1), 100_000)
        XCTAssertEqual(MoonshotCollector.units(-5), 0)   // negative clamped
        XCTAssertEqual(MoonshotCollector.units(0), 0)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .moonshot, apiKey: "sk-test")))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .moonshot)))
    }
}
#endif
