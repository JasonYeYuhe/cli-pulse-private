// Unit tests for the v1.40.0 PoeCollector (CodexBar parity). Locks the design:
// `current_point_balance` parse (flexible numeric), `.credits` with the RAW
// points count as remaining (no USD scale), graceful missing-balance status,
// and the "Balance: N points" compact en-US label. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class PoeCollectorTests: XCTestCase {
    private let collector = PoeCollector()

    private func parse(_ json: String) throws -> Double? {
        try PoeCollector.parseBalance(Data(json.utf8))
    }

    // MARK: - parseBalance

    func test_parseBalance_number() throws {
        XCTAssertEqual(try parse(#"{"current_point_balance": 1234567}"#) ?? -1, 1_234_567, accuracy: 0.5)
    }

    func test_parseBalance_string_number() throws {
        XCTAssertEqual(try parse(#"{"current_point_balance": "980.5"}"#) ?? -1, 980.5, accuracy: 0.001)
    }

    func test_parseBalance_absent_field_is_nil() throws {
        XCTAssertNil(try parse(#"{"other": 1}"#))
    }

    func test_parseBalance_invalid_json_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult

    func test_buildResult_positive_balance() {
        let result = PoeCollector.buildResult(1_000_000)
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        XCTAssertNil(u.quota)                       // uncapped
        XCTAssertEqual(u.remaining, 1_000_000)      // RAW points — no USD scale
        XCTAssertEqual(u.plan_type, "API key")
        XCTAssertEqual(u.provider, "Poe")
        XCTAssertEqual(u.metadata?.supports_quota, false)
        XCTAssertTrue(u.status_text.contains("points"), u.status_text)
        XCTAssertTrue(u.status_text.contains("1,000,000"), u.status_text)
        XCTAssertTrue(u.tiers.isEmpty)
    }

    func test_buildResult_missing_balance_is_graceful() {
        let u = PoeCollector.buildResult(nil).usage
        XCTAssertNil(u.remaining)
        XCTAssertTrue(u.status_text.contains("unavailable"), u.status_text)
    }

    func test_points_clamps_negative() {
        XCTAssertEqual(PoeCollector.points(-3), 0)
        XCTAssertEqual(PoeCollector.points(42.6), 43)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .poe, apiKey: "pk-test")))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .poe)))
    }
}
#endif
