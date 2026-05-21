// Unit tests for the v1.23.0 Phase C-6 CodebuffCollector (new
// api-key credits-quota provider). Locks the Gemini C-6 R1 adoptions:
// flexible Int|String|Number JSON parse, ISO/epoch date tolerance,
// the .quota (capped) vs .statusOnly (degenerate) classification, the
// resolvedTotal/resolvedUsed derivations, and the best-effort weekly
// TierDTO. macOS-gated like the other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodebuffCollectorTests: XCTestCase {
    private let collector = CodebuffCollector()

    // MARK: - Flexible usage parse (canonical + alias keys)

    func test_parseUsage_canonical_keys() throws {
        let u = try CodebuffCollector.parseUsage(Data("""
        {"used":250,"limit":1000,"remaining":750,"autoTopupEnabled":true}
        """.utf8))
        XCTAssertEqual(u.used, 250)
        XCTAssertEqual(u.total, 1000)
        XCTAssertEqual(u.remaining, 750)
        XCTAssertEqual(u.autoTopUpEnabled, true)
    }

    func test_parseUsage_alias_keys() throws {
        let u = try CodebuffCollector.parseUsage(Data("""
        {"usage":300,"quota":2000,"remainingBalance":1700,"auto_topup_enabled":false}
        """.utf8))
        XCTAssertEqual(u.used, 300)
        XCTAssertEqual(u.total, 2000)
        XCTAssertEqual(u.remaining, 1700)
        XCTAssertEqual(u.autoTopUpEnabled, false)
    }

    func test_parseUsage_flexible_string_numbers() throws {
        let u = try CodebuffCollector.parseUsage(Data("""
        {"used":"250","quota":"1000","remaining":"750"}
        """.utf8))
        XCTAssertEqual(u.used, 250)
        XCTAssertEqual(u.total, 1000)
        XCTAssertEqual(u.remaining, 750)
    }

    func test_parseUsage_invalid_json_throws() {
        XCTAssertThrowsError(try CodebuffCollector.parseUsage(Data("not json".utf8)))
    }

    // MARK: - Date tolerance (ISO + epoch sec + epoch millis)

    func test_dateValue_iso8601() {
        let d = CodebuffCollector.dateValue(from: "2026-06-01T00:00:00Z")
        XCTAssertNotNil(d)
    }

    func test_dateValue_epoch_seconds_and_millis() {
        let secs = 1_800_000_000.0
        let fromSecs = CodebuffCollector.dateValue(from: secs)
        XCTAssertEqual(fromSecs?.timeIntervalSince1970 ?? 0, secs, accuracy: 1)
        let fromMillis = CodebuffCollector.dateValue(from: secs * 1000)
        XCTAssertEqual(fromMillis?.timeIntervalSince1970 ?? 0, secs, accuracy: 1)
        // String epoch also parses.
        XCTAssertEqual(
            CodebuffCollector.dateValue(from: "1800000000")?.timeIntervalSince1970 ?? 0, secs, accuracy: 1)
    }

    // MARK: - Subscription parse (tier waterfall, weekly, email)

    func test_parseSubscription_full() throws {
        let s = try CodebuffCollector.parseSubscription(Data("""
        {
          "subscription": {"displayName":"Pro","status":"active"},
          "email":"dev@example.com",
          "rateLimit": {"weeklyUsed":1000,"weeklyLimit":5000,"weeklyResetsAt":"2026-06-08T00:00:00Z"}
        }
        """.utf8))
        XCTAssertEqual(s.tier, "Pro")
        XCTAssertEqual(s.status, "active")
        XCTAssertEqual(s.email, "dev@example.com")
        XCTAssertEqual(s.weeklyUsed, 1000)
        XCTAssertEqual(s.weeklyLimit, 5000)
        XCTAssertNotNil(s.weeklyResetsAt)
    }

    func test_parseSubscription_tier_waterfall_and_nested_email() throws {
        let s = try CodebuffCollector.parseSubscription(Data("""
        {"tier":"team","user":{"email":"u@x.io"},"rateLimit":{"used":10,"limit":100}}
        """.utf8))
        XCTAssertEqual(s.tier, "team")
        XCTAssertEqual(s.email, "u@x.io")
        XCTAssertEqual(s.weeklyUsed, 10)
        XCTAssertEqual(s.weeklyLimit, 100)
    }

    // MARK: - Derivations

    func test_resolvedTotal_and_used() {
        XCTAssertEqual(
            CodebuffCollector.resolvedTotal(.init(used: 250, total: 1000, remaining: 750)), 1000)
        // total absent ⇒ used + remaining.
        XCTAssertEqual(
            CodebuffCollector.resolvedTotal(.init(used: 250, total: nil, remaining: 750)), 1000)
        // used absent ⇒ total - remaining.
        XCTAssertEqual(
            CodebuffCollector.resolvedUsed(.init(used: nil, total: 1000, remaining: 750)), 250)
    }

    // MARK: - buildResult: .quota when capped

    func test_buildResult_quota_with_weekly_tier() {
        let usage = CodebuffCollector.UsagePayload(
            used: 250, total: 1000, remaining: 750,
            nextQuotaReset: Date(timeIntervalSince1970: 1_800_000_000), autoTopUpEnabled: true)
        let sub = CodebuffCollector.SubscriptionPayload(
            tier: "pro", weeklyUsed: 1000, weeklyLimit: 5000,
            weeklyResetsAt: Date(timeIntervalSince1970: 1_800_500_000))
        let r = CodebuffCollector.buildResult(usage: usage, subscription: sub)
        XCTAssertEqual(r.dataKind, .quota)
        let u = r.usage
        XCTAssertEqual(u.quota, 1000)
        XCTAssertEqual(u.remaining, 750)
        XCTAssertEqual(u.today_usage, 250)
        XCTAssertEqual(u.plan_type, "Pro")            // tier capitalized
        XCTAssertNotNil(u.reset_time)
        XCTAssertTrue(u.status_text.contains("750 credits remaining"))
        XCTAssertTrue(u.status_text.contains("auto top-up"))
        XCTAssertEqual(u.metadata?.supports_quota, true)
        // Credits + Weekly tiers.
        XCTAssertEqual(u.tiers.count, 2)
        XCTAssertEqual(u.tiers.first { $0.name == "Credits" }?.quota, 1000)
        let weekly = u.tiers.first { $0.name == "Weekly" }
        XCTAssertEqual(weekly?.quota, 5000)
        XCTAssertEqual(weekly?.remaining, 4000)       // 5000 - 1000
    }

    func test_buildResult_quota_no_subscription_defaults_plan() {
        let usage = CodebuffCollector.UsagePayload(used: 0, total: 500, remaining: 500)
        let r = CodebuffCollector.buildResult(usage: usage, subscription: nil)
        XCTAssertEqual(r.dataKind, .quota)
        XCTAssertEqual(r.usage.plan_type, "API key")
        XCTAssertEqual(r.usage.tiers.count, 1)        // Credits only
    }

    // MARK: - buildResult: .statusOnly degenerate

    func test_buildResult_degenerate_total_zero_with_remaining() {
        let usage = CodebuffCollector.UsagePayload(used: 10, total: 0, remaining: 5)
        let r = CodebuffCollector.buildResult(usage: usage, subscription: nil)
        XCTAssertEqual(r.dataKind, .statusOnly)
        XCTAssertNil(r.usage.quota)
        XCTAssertNil(r.usage.remaining)
        XCTAssertTrue(r.usage.status_text.contains("5 credits remaining"))
    }

    func test_buildResult_no_data_is_connected_statusOnly() {
        let r = CodebuffCollector.buildResult(
            usage: CodebuffCollector.UsagePayload(), subscription: nil)
        XCTAssertEqual(r.dataKind, .statusOnly)
        XCTAssertNil(r.usage.quota)
        XCTAssertEqual(r.usage.status_text, "Connected")
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .codebuff)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .codebuff, apiKey: "cb-key")))
        XCTAssertFalse(collector.isAvailable(
            config: ProviderConfig(kind: .codebuff, apiKey: "   ")))
    }

    // MARK: - New ProviderKind case (per the new-ProviderKind checklist)

    func test_providerKind_codebuff_case() {
        XCTAssertEqual(ProviderKind(rawValue: "Codebuff"), .codebuff)
        XCTAssertEqual(ProviderKind.codebuff.rawValue, "Codebuff")
        XCTAssertEqual(ProviderKind.codebuff.iconName, "b.circle")
        XCTAssertTrue(ProviderKind.allCases.contains(.codebuff))
        XCTAssertEqual(collector.kind, .codebuff)
    }
}
#endif
