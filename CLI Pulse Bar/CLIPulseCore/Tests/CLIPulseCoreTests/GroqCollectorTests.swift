// Unit tests for the v1.23.0 Phase C-12 GroqCollector (CodexBar parity — first
// niche provider). Locks the Gemini C-12 R1 adoptions: Prometheus mixed-array
// value decode (number-or-string), empty-result→0 graceful degradation,
// `.statusOnly` per-minute rate display, and formatDecimal "0" for exactly
// zero. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class GroqCollectorTests: XCTestCase {
    private let collector = GroqCollector()

    private func parse(_ json: String) throws -> Double {
        try GroqCollector.parseScalar(Data(json.utf8))
    }

    // MARK: - parseScalar (Prometheus instant-query envelope)

    func test_parseScalar_sums_last_value_of_each_series() throws {
        // mixed array [timestamp, "value"]; sum last of each series.
        let v = try parse("""
        {"status":"success","data":{"result":[
          {"value":[1712345678.1,"1.5"]},
          {"value":[1712345678.1,"2.5"]}
        ]}}
        """)
        XCTAssertEqual(v, 4.0, accuracy: 0.0001)
    }

    func test_parseScalar_number_and_string_values() throws {
        XCTAssertEqual(try parse(#"{"status":"success","data":{"result":[{"value":[1,3.0]}]}}"#),
                       3.0, accuracy: 0.0001)   // numeric value
        XCTAssertEqual(try parse(#"{"status":"success","data":{"result":[{"value":[1,"3.5"]}]}}"#),
                       3.5, accuracy: 0.0001)   // string value
    }

    func test_parseScalar_empty_result_is_zero() throws {
        XCTAssertEqual(try parse(#"{"status":"success","data":{"result":[]}}"#), 0, accuracy: 0.0001)
    }

    func test_parseScalar_error_status_throws() {
        XCTAssertThrowsError(try parse(#"{"status":"error","error":"bad query"}"#)) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult (.statusOnly rates)

    func test_buildResult_rates_status_text() {
        // 2 req/s → 120 req/min; (100+50) tok/s → 9000 tok/min; no cache.
        let result = GroqCollector.buildResult(
            requestsPerSec: 2.0, inputTokPerSec: 100, outputTokPerSec: 50, cacheHitsPerSec: 0)
        XCTAssertEqual(result.dataKind, .statusOnly)
        let u = result.usage
        XCTAssertNil(u.quota)
        XCTAssertNil(u.remaining)
        XCTAssertEqual(u.plan_type, "API key")
        XCTAssertEqual(u.metadata?.supports_quota, false)
        XCTAssertEqual(u.status_text, "120 req/min · 9000 tok/min")
    }

    func test_buildResult_includes_cache_when_positive() {
        let u = GroqCollector.buildResult(
            requestsPerSec: 0, inputTokPerSec: 0, outputTokPerSec: 0, cacheHitsPerSec: 0.5).usage
        // 0.5/s → 30 cache/min; zero req/tok render as "0".
        XCTAssertEqual(u.status_text, "0 req/min · 0 tok/min · 30.0 cache/min")
    }

    func test_buildResult_zero_rates() {
        let u = GroqCollector.buildResult(
            requestsPerSec: 0, inputTokPerSec: 0, outputTokPerSec: 0, cacheHitsPerSec: 0).usage
        XCTAssertEqual(u.status_text, "0 req/min · 0 tok/min")
    }

    func test_formatDecimal_boundaries() {
        XCTAssertEqual(GroqCollector.formatDecimal(0), "0")
        XCTAssertEqual(GroqCollector.formatDecimal(5.5), "5.50")
        XCTAssertEqual(GroqCollector.formatDecimal(15.5), "15.5")
        XCTAssertEqual(GroqCollector.formatDecimal(60), "60.0")
        XCTAssertEqual(GroqCollector.formatDecimal(150.7), "151")
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .groq, apiKey: "gsk_test")))
        // absent key (assumes GROQ_API_KEY unset in the test env).
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .groq)))
    }
}
#endif
