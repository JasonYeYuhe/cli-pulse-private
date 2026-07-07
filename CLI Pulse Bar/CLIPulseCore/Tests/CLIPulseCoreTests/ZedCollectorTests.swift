// Unit tests for the v1.40 ZedCollector (CodexBar parity). Locks the pure parse
// + `.quota` mapping: edit-predictions (limited AND "unlimited"), billing-cycle
// window, overdue-invoices flag, plan-name display, and the DEVID-only gate.
// macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ZedCollectorTests: XCTestCase {
    private let collector = ZedCollector()

    private func parse(_ json: String) throws -> ZedCollector.Snapshot {
        try ZedCollector.parse(Data(json.utf8))
    }

    private func json(limit: String, overdue: Bool = false, plan: String = "zed_pro") -> String {
        """
        {"user":{"id":123,"github_login":"octocat","name":"Octo"},
         "plan":{"plan_v3":"\(plan)",
          "subscription_period":{"started_at":"2026-07-01T00:00:00Z","ended_at":"2026-08-01T00:00:00Z"},
          "usage":{"edit_predictions":{"used":400,"limit":\(limit)}},
          "has_overdue_invoices":\(overdue)}}
        """
    }

    // MARK: - parse

    func test_parse_limited() throws {
        let s = try parse(json(limit: "1000"))
        XCTAssertEqual(s.planV3, "zed_pro")
        XCTAssertEqual(s.editUsed, 400)
        XCTAssertEqual(s.editLimit, .limited(1000))
        XCTAssertNotNil(s.cycleStart)
        XCTAssertNotNil(s.cycleEnd)
        XCTAssertFalse(s.hasOverdueInvoices)
    }

    func test_parse_unlimited() throws {
        let s = try parse(json(limit: "\"unlimited\""))
        XCTAssertEqual(s.editLimit, .unlimited)
    }

    func test_parse_limited_nested_serde_form() throws {
        // Zed's Rust backend may emit the externally-tagged {"limited": N} shape.
        let s = try parse(json(limit: "{\"limited\": 500}"))
        XCTAssertEqual(s.editLimit, .limited(500))
    }

    func test_parse_invalid_throws() {
        XCTAssertThrowsError(try parse("not json")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    // MARK: - buildResult

    func test_buildResult_limited_quota() {
        let s = ZedCollector.Snapshot(
            planV3: "zed_pro", githubLogin: "octocat", editUsed: 400, editLimit: .limited(1000),
            cycleStart: Date(timeIntervalSince1970: 1_000_000),
            cycleEnd: Date(timeIntervalSince1970: 3_000_000), hasOverdueInvoices: false)
        let result = ZedCollector.buildResult(s)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.provider, "Zed")
        XCTAssertEqual(u.quota, 1000)
        XCTAssertEqual(u.remaining, 600)                       // 1000 - 400
        XCTAssertEqual(u.plan_type, "Zed Pro")
        XCTAssertEqual(u.tiers.first { $0.name == "Edit Predictions" }?.remaining, 600)
        XCTAssertNotNil(u.tiers.first { $0.name == "Billing Cycle" })
        XCTAssertTrue(u.status_text.contains("400 / 1000"), u.status_text)
    }

    func test_buildResult_unlimited() {
        let s = ZedCollector.Snapshot(
            planV3: "zed_business", githubLogin: "x", editUsed: 0, editLimit: .unlimited,
            cycleStart: nil, cycleEnd: nil, hasOverdueInvoices: false)
        let u = ZedCollector.buildResult(s).usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 100)
        XCTAssertTrue(u.status_text.contains("Unlimited"), u.status_text)
        XCTAssertEqual(u.plan_type, "Zed Business")
    }

    func test_buildResult_overdue_flag_in_status() {
        let s = ZedCollector.Snapshot(
            planV3: "zed_free", githubLogin: "x", editUsed: 50, editLimit: .limited(100),
            cycleStart: nil, cycleEnd: nil, hasOverdueInvoices: true)
        XCTAssertTrue(ZedCollector.buildResult(s).usage.status_text.contains("overdue"),
                      "overdue flag must surface in status")
    }

    // MARK: - helpers

    func test_displayPlanName() {
        XCTAssertEqual(ZedCollector.displayPlanName("zed_pro_trial"), "Zed Pro Trial")
        XCTAssertEqual(ZedCollector.displayPlanName("zed_free"), "Zed Free")
        XCTAssertEqual(ZedCollector.displayPlanName("some_new_plan"), "Some New Plan")   // title-cased fallback
    }

    func test_billingCycleUsedPercent() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(ZedCollector.billingCycleUsedPercent(start: start, end: end,
                                                            now: Date(timeIntervalSince1970: 25)), 25, accuracy: 0.001)
        // Degenerate window → 0, clamped.
        XCTAssertEqual(ZedCollector.billingCycleUsedPercent(start: end, end: start), 0)
    }

    // MARK: - Keychain cooldown gate

    func test_keychainGate_cooldown() {
        ZedKeychainGate.reset()
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(ZedKeychainGate.isCoolingDown(now: now))
        ZedKeychainGate.noteInteractionDenied(now: now)
        XCTAssertTrue(ZedKeychainGate.isCoolingDown(now: now.addingTimeInterval(60)))          // within 30 min
        XCTAssertFalse(ZedKeychainGate.isCoolingDown(now: now.addingTimeInterval(31 * 60)))    // expired
        ZedKeychainGate.reset()
        XCTAssertFalse(ZedKeychainGate.isCoolingDown(now: now))
    }

    // MARK: - DEVID gate

    #if !DEVID_BUILD
    func test_isAvailable_false_on_non_devid() {
        // MAS / non-DEVID builds cannot read Zed's Keychain → never available.
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .zed)))
    }
    #endif
}
#endif
