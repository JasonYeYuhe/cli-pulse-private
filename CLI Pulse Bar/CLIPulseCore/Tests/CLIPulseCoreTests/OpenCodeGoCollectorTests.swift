// Unit tests for the v1.23.0 Phase C-22 OpenCodeGoCollector (CodexBar parity —
// most fragile cookie port; unverifiable). These lock the PORTED logic: usage
// regex + JSON window finder, workspace-ID normalization, Zen-balance parse,
// and the `.quota` window mapping. macOS-gated.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class OpenCodeGoCollectorTests: XCTestCase {
    private let collector = OpenCodeGoCollector()

    // MARK: - parseUsage (regex primary)

    func test_parseUsage_regex() throws {
        let page = #"""
        {"rollingUsage":{"usagePercent":25,"resetInSec":3600},"weeklyUsage":{"usagePercent":40,"resetInSec":604800},"monthlyUsage":{"usagePercent":10,"resetInSec":2592000}}
        """#
        let s = try OpenCodeGoCollector.parseUsage(page)
        XCTAssertEqual(s.rollingUsedPercent, 25, accuracy: 0.001)
        XCTAssertEqual(s.weeklyUsedPercent, 40, accuracy: 0.001)
        XCTAssertEqual(s.monthlyUsedPercent ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(s.rollingResetSec, 3600)
    }

    func test_parseUsage_missing_throws() {
        XCTAssertThrowsError(try OpenCodeGoCollector.parseUsage("<html>nothing here</html>")) {
            guard case CollectorError.parseFailed = $0 else { return XCTFail("expected parseFailed") }
        }
    }

    func test_parseUsageJSON_window_finder() {
        // Different shape (used/limit, not usagePercent) ⇒ exercises parseWindow.
        let s = OpenCodeGoCollector.parseUsageJSON(#"""
        {"data":{"rollingWindow":{"used":50,"limit":200,"resetSec":3600},"weeklyWindow":{"used":10,"limit":100,"resetSec":99}}}
        """#)
        XCTAssertEqual(s?.rollingUsedPercent ?? -1, 25, accuracy: 0.001)   // 50/200
        XCTAssertEqual(s?.weeklyUsedPercent ?? -1, 10, accuracy: 0.001)    // 10/100
    }

    // MARK: - normalizeWorkspaceID

    func test_normalizeWorkspaceID() {
        XCTAssertEqual(OpenCodeGoCollector.normalizeWorkspaceID("wrk_abc123"), "wrk_abc123")
        XCTAssertEqual(OpenCodeGoCollector.normalizeWorkspaceID("https://opencode.ai/workspace/wrk_xyz/go"), "wrk_xyz")
        XCTAssertNil(OpenCodeGoCollector.normalizeWorkspaceID("garbage"))
        XCTAssertEqual(OpenCodeGoCollector.firstWorkspaceID(in: #"[{"id":"wrk_first"},{"id":"wrk_second"}]"#), "wrk_first")
    }

    // MARK: - Zen balance

    func test_parseZenBalance() {
        XCTAssertEqual(OpenCodeGoCollector.parseZenBalance(#"{"currentBalanceUsd":12.5}"#) ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(OpenCodeGoCollector.parseZenBalance("Your Zen balance: $8.00 remaining") ?? -1, 8.0, accuracy: 0.001)
        XCTAssertNil(OpenCodeGoCollector.parseZenBalance("no balance"))
    }

    // MARK: - buildResult

    func test_buildResult_quota_windows_and_zen() {
        let result = OpenCodeGoCollector.buildResult(.init(
            rollingUsedPercent: 25, weeklyUsedPercent: 40, monthlyUsedPercent: 10,
            rollingResetSec: 3600, weeklyResetSec: 604_800, monthlyResetSec: 2_592_000, zenBalanceUSD: 12.5))
        XCTAssertEqual(result.dataKind, .quota)
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        XCTAssertEqual(u.remaining, 75)          // rolling: 100 − 25 used
        XCTAssertEqual(u.tiers.first { $0.name == "Rolling" }?.remaining, 75)
        XCTAssertEqual(u.tiers.first { $0.name == "Weekly" }?.remaining, 60)
        XCTAssertEqual(u.tiers.first { $0.name == "Monthly" }?.remaining, 90)
        XCTAssertTrue(u.status_text.contains("Rolling 75% · Weekly 60% left"), u.status_text)
        XCTAssertTrue(u.status_text.contains("$12.50 Zen"), u.status_text)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .openCodeGo)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .openCodeGo, manualCookieHeader: "session=x")))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .openCodeGo, cookieSource: .automatic)))
    }
}
#endif
