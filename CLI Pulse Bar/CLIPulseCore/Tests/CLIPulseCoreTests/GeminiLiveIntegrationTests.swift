#if os(macOS)
import XCTest
@testable import CLIPulseCore
import Foundation

/// LIVE integration test — exercises the REAL `GeminiCollector.collect()` path
/// against the local `~/.gemini` credentials and the live Google quota API
/// (loadCodeAssist → retrieveUserQuota). Skipped unless `RUN_LIVE_GEMINI=1`, so
/// CI (no creds, no network) stays green. Run on-device with:
///
///   RUN_LIVE_GEMINI=1 swift test --filter GeminiLiveIntegrationTests
///
/// This is the end-to-end proof that the Antigravity/Gemini quota wiring works
/// through the actual Swift code, not just an API mirror.
final class GeminiLiveIntegrationTests: XCTestCase {

    private var live: Bool {
        ProcessInfo.processInfo.environment["RUN_LIVE_GEMINI"] == "1"
    }

    func test_liveCollect_returnsRealQuota() async throws {
        try XCTSkipUnless(live, "live test — set RUN_LIVE_GEMINI=1 to run on-device")

        let collector = GeminiCollector()
        let config = ProviderConfig(kind: .gemini)
        XCTAssertTrue(collector.isAvailable(config: config),
                      "expected local ~/.gemini credentials to be present")

        let result = try await collector.collect(config: config)
        let u = result.usage

        print("=== LIVE Gemini/Antigravity quota ===")
        print("plan=\(u.plan_type ?? "?")  overall remaining=\(u.remaining.map(String.init) ?? "nil")%  reset=\(u.reset_time ?? "?")")
        print("status_text=\(u.status_text)")
        for t in u.tiers {
            print("  TIER \(t.name): remaining=\(t.remaining)%  reset=\(t.reset_time ?? "?")")
        }

        XCTAssertEqual(result.dataKind, .quota)
        XCTAssertNotNil(u.remaining, "overall remaining must be present")
        XCTAssertFalse(u.tiers.isEmpty, "expected at least one model-family tier (Pro/Flash/Flash Lite)")
        // Every tier percentage must be a sane 0...100.
        for t in u.tiers {
            XCTAssert((0...100).contains(t.remaining), "tier \(t.name) remaining out of range: \(t.remaining)")
        }
        if let overall = u.remaining { XCTAssert((0...100).contains(overall)) }
    }

    /// Refreshing must not corrupt the agy token file: after a collect() that
    /// may persist a refreshed token, the file must still be valid JSON with the
    /// nested {token:{access_token,refresh_token},auth_method} shape intact.
    func test_liveCollect_doesNotCorruptAgyTokenFile() async throws {
        try XCTSkipUnless(live, "live test — set RUN_LIVE_GEMINI=1 to run on-device")

        let path = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        guard let before = FileManager.default.contents(atPath: path) else {
            throw XCTSkip("no antigravity token file on this machine")
        }
        let beforeJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: before) as? [String: Any])
        let beforeToken = try XCTUnwrap(beforeJSON["token"] as? [String: Any])
        let beforeRefresh = beforeToken["refresh_token"] as? String

        _ = try? await GeminiCollector().collect(config: ProviderConfig(kind: .gemini))

        let after = try XCTUnwrap(FileManager.default.contents(atPath: path))
        let afterJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: after) as? [String: Any],
                                      "agy token file must still be valid JSON after collect()")
        let afterToken = try XCTUnwrap(afterJSON["token"] as? [String: Any])
        XCTAssertNotNil(afterToken["access_token"], "access_token must survive")
        // refresh_token + auth_method must be preserved (never dropped/clobbered).
        XCTAssertEqual(afterToken["refresh_token"] as? String, beforeRefresh,
                       "refresh_token must be preserved across persist")
        XCTAssertEqual(afterJSON["auth_method"] as? String, beforeJSON["auth_method"] as? String,
                       "auth_method must be preserved")
    }
}
#endif
