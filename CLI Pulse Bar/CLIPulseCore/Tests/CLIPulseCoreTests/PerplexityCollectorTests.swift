// Unit tests for the v1.23.0 Phase B-1 PerplexityCollector
// (CodexBar stub → real .credits collector). Locks the Gemini
// Phase-B R1 adoptions: ported waterfall attribution
// (recurring→purchased→promotional) verbatim, plan inference,
// .credits + OpenRouter unit scaling, isAvailable matrix.
// macOS-gated like the other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class PerplexityCollectorTests: XCTestCase {
    private let collector = PerplexityCollector()

    private func decode(_ json: String) throws -> PerplexityCollector.PerplexityCreditsResponse {
        try PerplexityCollector.parseCredits(Data(json.utf8))
    }

    // MARK: - Parsing

    func test_parseCredits_decodes_snake_case() throws {
        let r = try decode("""
        {
          "balance_cents": 1234.5,
          "renewal_date_ts": 1750000000,
          "current_period_purchased_cents": 800,
          "total_usage_cents": 4200,
          "credit_grants": [
            {"type": "recurring", "amount_cents": 5000, "expires_at_ts": null},
            {"type": "purchased", "amount_cents": 500, "expires_at_ts": null}
          ]
        }
        """)
        XCTAssertEqual(r.balanceCents, 1234.5, accuracy: 0.001)
        XCTAssertEqual(r.renewalDateTs, 1_750_000_000, accuracy: 1)
        XCTAssertEqual(r.currentPeriodPurchasedCents, 800, accuracy: 0.001)
        XCTAssertEqual(r.totalUsageCents, 4200, accuracy: 0.001)
        XCTAssertEqual(r.creditGrants.count, 2)
        XCTAssertEqual(r.creditGrants[0].type, "recurring")
    }

    func test_parseCredits_invalid_throws() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{}")) // missing required keys
    }

    // MARK: - Waterfall attribution (verbatim port)

    func test_snapshot_waterfall_recurring_then_purchased_then_promo() throws {
        // recurring 1000, purchased 500, promo 2000; usage 1300.
        // → recurringUsed 1000, purchasedUsed 300, promoUsed 0.
        let r = try decode("""
        { "balance_cents": 2200, "renewal_date_ts": 1750000000,
          "current_period_purchased_cents": 0, "total_usage_cents": 1300,
          "credit_grants": [
            {"type":"recurring","amount_cents":1000,"expires_at_ts":null},
            {"type":"purchased","amount_cents":500,"expires_at_ts":null},
            {"type":"promotional","amount_cents":2000,"expires_at_ts":null}
          ] }
        """)
        let s = PerplexityCollector.PerplexitySnapshot(
            response: r, now: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(s.recurringTotal, 1000, accuracy: 0.001)
        XCTAssertEqual(s.recurringUsed, 1000, accuracy: 0.001)
        XCTAssertEqual(s.purchasedTotal, 500, accuracy: 0.001)
        XCTAssertEqual(s.purchasedUsed, 300, accuracy: 0.001)
        XCTAssertEqual(s.promoTotal, 2000, accuracy: 0.001)
        XCTAssertEqual(s.promoUsed, 0, accuracy: 0.001)
    }

    func test_snapshot_purchased_takes_max_of_field_and_grants() throws {
        let r = try decode("""
        { "balance_cents": 0, "renewal_date_ts": 1750000000,
          "current_period_purchased_cents": 800, "total_usage_cents": 0,
          "credit_grants": [{"type":"purchased","amount_cents":500,"expires_at_ts":null}] }
        """)
        let s = PerplexityCollector.PerplexitySnapshot(response: r, now: Date())
        XCTAssertEqual(s.purchasedTotal, 800, accuracy: 0.001) // max(500, 800)
    }

    func test_snapshot_excludes_expired_promotional_grant() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r = try decode("""
        { "balance_cents": 0, "renewal_date_ts": 1750000000,
          "current_period_purchased_cents": 0, "total_usage_cents": 0,
          "credit_grants": [
            {"type":"promotional","amount_cents":999,"expires_at_ts":1600000000}
          ] }
        """) // expires before `now` ⇒ filtered out
        let s = PerplexityCollector.PerplexitySnapshot(response: r, now: now)
        XCTAssertEqual(s.promoTotal, 0, accuracy: 0.001)
    }

    func test_planName_inference() throws {
        func plan(recurring: Double) throws -> String? {
            let r = try decode("""
            { "balance_cents": 0, "renewal_date_ts": 1750000000,
              "current_period_purchased_cents": 0, "total_usage_cents": 0,
              "credit_grants": [{"type":"recurring","amount_cents":\(recurring),"expires_at_ts":null}] }
            """)
            return PerplexityCollector.PerplexitySnapshot(response: r, now: Date()).planName
        }
        XCTAssertNil(try plan(recurring: 0))
        XCTAssertEqual(try plan(recurring: 4999), "Pro")
        XCTAssertEqual(try plan(recurring: 5000), "Max")
    }

    // MARK: - buildResult: .credits + OpenRouter unit scaling

    func test_buildResult_credits_scale_and_fields() throws {
        let r = try decode("""
        { "balance_cents": 1000, "renewal_date_ts": 1750000000,
          "current_period_purchased_cents": 0, "total_usage_cents": 250,
          "credit_grants": [{"type":"recurring","amount_cents":2000,"expires_at_ts":null}] }
        """)
        let s = PerplexityCollector.PerplexitySnapshot(response: r, now: Date())
        let result = collector.buildResult(s)
        XCTAssertEqual(result.dataKind, .credits)
        let u = result.usage
        // $1 = 100_000 units ⇒ 1 cent = 1000 units. balance 1000c ⇒ 1_000_000.
        XCTAssertEqual(u.remaining, 1_000_000)
        XCTAssertEqual(u.quota, 2_000_000)               // total pool 2000c
        XCTAssertEqual(u.estimated_cost_today, 2.50, accuracy: 0.001) // 250c → $2.50
        XCTAssertEqual(u.plan_type, "Pro") // recurring 2000c < 5000 ⇒ Pro
        let resetISO = try XCTUnwrap(u.reset_time)
        let parsed = try XCTUnwrap(sharedISO8601Parse(resetISO))
        XCTAssertEqual(parsed.timeIntervalSince1970, 1_750_000_000, accuracy: 1)
        XCTAssertEqual(u.tiers.first { $0.name == "Recurring" }?.quota, 2_000_000)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .perplexity)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .perplexity, manualCookieHeader: "sid=abc")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .perplexity, cookieSource: .automatic)))
    }
}
#endif
