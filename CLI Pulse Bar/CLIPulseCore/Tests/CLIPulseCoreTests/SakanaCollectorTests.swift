// Unit tests for the v1.40 SakanaCollector (CodexBar parity). Locks: 5-hour +
// weekly window HTML scrape, UTC reset-date parse (upstream #1826), PAYG credit
// scrape, plan/price extraction, and the `.quota` window mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class SakanaCollectorTests: XCTestCase {
    private let collector = SakanaCollector()

    private static let billingHTML = """
    <div data-slot="card-title"><span>Pro Plan</span> <span>$20/mo</span></div>
    <p>5-hour</p>
    <p>40% used</p>
    <p>Resets on January 1, 2027 at 3:00 PM</p>
    <p>Weekly</p>
    <p>60% used</p>
    <p>Resets on January 7, 2027 at 12:00 AM</p>
    """

    func test_parseBillingHTML_windows_and_plan() throws {
        let s = try SakanaCollector.parseBillingHTML(Self.billingHTML)
        XCTAssertEqual(s.fiveHour?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(s.weekly?.usedPercent ?? -1, 60, accuracy: 0.001)
        XCTAssertNotNil(s.fiveHour?.resetsAt)
        XCTAssertEqual(s.planName, "Pro Plan")
        XCTAssertEqual(s.priceLabel, "$20/mo")
    }

    func test_parseResetDate_is_UTC() {
        let date = SakanaCollector.parseResetDate("January 1, 2027 at 3:00 PM")
        let d = try? XCTUnwrap(date)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: d ?? Date(timeIntervalSince1970: 0))
        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 15)   // 3 PM UTC — NOT shifted to local
    }

    func test_parsePayAsYouGoCredit() {
        let html = """
        <h2>Credit balance</h2>
        <div class="mt-2"><p class="text-2xl tabular-nums font-mono">$12.50</p></div>
        """
        XCTAssertEqual(SakanaCollector.parsePayAsYouGoCredit(html) ?? -1, 12.5, accuracy: 0.001)
    }

    func test_parsePayAsYouGoCredit_absent_is_nil() {
        XCTAssertNil(SakanaCollector.parsePayAsYouGoCredit("<div>no balance here</div>"))
    }

    func test_parseBillingHTML_missing_windows_throws() {
        XCTAssertThrowsError(try SakanaCollector.parseBillingHTML("<div>nothing</div>")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_buildResult_quota_windows() {
        let s = SakanaCollector.Snapshot(
            planName: "Pro", priceLabel: "$20",
            fiveHour: .init(usedPercent: 40, resetsAt: Date(timeIntervalSince1970: 1_893_456_000)),
            weekly: .init(usedPercent: 60, resetsAt: nil),
            payAsYouGoCreditUSD: 12.5)
        let result = SakanaCollector.buildResult(s)
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.provider, "Sakana AI")
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 60)   // 5h 100-40
        XCTAssertEqual(u.tiers.count, 2)
        XCTAssertEqual(u.tiers.first { $0.name == "5-hour" }?.remaining, 60)
        XCTAssertEqual(u.tiers.first { $0.name == "Weekly" }?.remaining, 40)
        XCTAssertEqual(u.plan_type, "Pro $20")
        XCTAssertTrue(u.status_text.contains("5h 60% left"), u.status_text)
        XCTAssertTrue(u.status_text.contains("Weekly 40% left"), u.status_text)
        XCTAssertTrue(u.status_text.contains("$12.50 credit"), u.status_text)
    }

    func test_isAvailable_matrix() {
        XCTAssertTrue(collector.isAvailable(config: ProviderConfig(kind: .sakana, manualCookieHeader: "sid=abc")))
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .sakana)))
    }
}
#endif
