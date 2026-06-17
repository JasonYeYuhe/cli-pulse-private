import XCTest
@testable import CLIPulseCore

/// macOS hang fix — `publishWidgetData` writes the app-group blob + reloads
/// timelines off the main thread (was the APPLE-MACOS-9 cfprefsd main-thread
/// block) and skips the write entirely when nothing user-visible changed.
/// The dedupe hinges on `hasSameContent(as:)` ignoring `lastUpdated` only —
/// the macOS helper-sync path fires this many times a minute, so a
/// timestamp-sensitive guard would never skip (the original review trap).
final class WidgetPublishDedupeTests: XCTestCase {

    private func provider(_ name: String, usage: Int = 100, percent: Double? = 0.5)
        -> PublishedWidgetProviderData
    {
        PublishedWidgetProviderData(
            name: name, usage: usage, quota: 1000, costToday: 1.25,
            iconName: "cpu", percent: percent, weeklyPercent: 0.4)
    }

    private func payload(
        usageToday: Int = 500,
        isPro: Bool = false,
        providers: [PublishedWidgetProviderData]? = nil,
        at date: Date
    ) -> PublishedWidgetData {
        PublishedWidgetData(
            totalUsageToday: usageToday,
            totalCostToday: 3.5,
            activeSessions: 2,
            unresolvedAlerts: 1,
            providers: providers ?? [provider("claude"), provider("codex")],
            lastUpdated: date,
            swarmAgents: 3,
            swarmBlocked: 0,
            isPro: isPro)
    }

    func testIdenticalContentDiffersOnlyByTimestampIsSame() {
        let a = payload(at: Date(timeIntervalSince1970: 1_000))
        let b = payload(at: Date(timeIntervalSince1970: 9_999))   // only lastUpdated differs
        XCTAssertTrue(a.hasSameContent(as: b),
                      "Only lastUpdated changed — must be treated as no-change so the write is skipped")
        XCTAssertNotEqual(a, b, "Full Equatable still sees the timestamp difference")
    }

    func testProviderUsageChangeBreaksContent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let a = payload(providers: [provider("claude", usage: 100)], at: now)
        let b = payload(providers: [provider("claude", usage: 101)], at: now)
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    func testProviderPercentChangeBreaksContent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let a = payload(providers: [provider("claude", percent: 0.50)], at: now)
        let b = payload(providers: [provider("claude", percent: 0.51)], at: now)
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    func testIsProChangeBreaksContent() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(payload(isPro: false, at: now).hasSameContent(as: payload(isPro: true, at: now)))
    }

    func testTotalsChangeBreaksContent() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(payload(usageToday: 500, at: now).hasSameContent(as: payload(usageToday: 600, at: now)))
    }

    func testProviderListLengthChangeBreaksContent() {
        let now = Date(timeIntervalSince1970: 1_000)
        let a = payload(providers: [provider("claude")], at: now)
        let b = payload(providers: [provider("claude"), provider("codex")], at: now)
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    func testProviderReorderBreaksContent() {
        // Order is meaningful (the widget renders providers in array order).
        let now = Date(timeIntervalSince1970: 1_000)
        let a = payload(providers: [provider("claude"), provider("codex")], at: now)
        let b = payload(providers: [provider("codex"), provider("claude")], at: now)
        XCTAssertFalse(a.hasSameContent(as: b))
    }

    /// The encoded blob the widget reads must keep the exact JSON keys the
    /// extension decodes — guard against an accidental property rename.
    func testEncodedKeysMatchWidgetContract() throws {
        let data = try JSONEncoder().encode(payload(at: Date(timeIntervalSince1970: 1_000)))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let keys = Set(obj?.keys ?? [:].keys)
        for k in ["totalUsageToday", "totalCostToday", "activeSessions",
                  "unresolvedAlerts", "providers", "lastUpdated",
                  "swarmAgents", "swarmBlocked", "isPro"] {
            XCTAssertTrue(keys.contains(k), "missing widget key \(k)")
        }
        let first = (obj?["providers"] as? [[String: Any]])?.first
        for k in ["name", "usage", "quota", "costToday", "iconName", "percent", "weeklyPercent"] {
            XCTAssertNotNil(first?[k], "missing provider key \(k)")
        }
    }
}
