#if os(macOS)
import XCTest
@testable import CLIPulseCore
import Foundation

/// v1.32.x — CLI Pulse can now pull the Gemini / Antigravity (`agy`) quota.
/// Two things were broken before: file-based gemini-cli tokens were declared
/// "un-refreshable" (false — the public installed-app client refreshes them),
/// and Antigravity's consumer token (`~/.gemini/antigravity-cli/...`) was never
/// read at all. These tests cover the pure pieces of that wiring: the nested
/// Antigravity token parser, the RFC3339-nano expiry parser, the form encoder,
/// and the shape of the embedded public client secrets. The network refresh +
/// sandbox file IO are exercised on-device.
final class GeminiAntigravityCredsTests: XCTestCase {

    // MARK: - Antigravity nested-token parsing

    func test_parseAntigravityCreds_extractsNestedToken() {
        let json = """
        {
          "token": {
            "access_token": "ya29.ACCESS",
            "token_type": "Bearer",
            "refresh_token": "1//0eREFRESH",
            "expiry": "2026-06-21T02:08:45.204796+09:00"
          },
          "auth_method": "consumer"
        }
        """
        let creds = GeminiCollector.parseAntigravityCreds(Data(json.utf8))
        XCTAssertNotNil(creds)
        XCTAssertEqual(creds?.accessToken, "ya29.ACCESS")
        XCTAssertEqual(creds?.refreshToken, "1//0eREFRESH")
        XCTAssertEqual(creds?.source, .antigravity)
        XCTAssertNotNil(creds?.expiryDate)
    }

    func test_parseAntigravityCreds_rejectsFlatGeminiCliFormat() {
        // The gemini-cli format is flat (no nested "token") — must not be
        // mistaken for an Antigravity file.
        let json = #"{"access_token":"x","refresh_token":"y","expiry_date":123}"#
        XCTAssertNil(GeminiCollector.parseAntigravityCreds(Data(json.utf8)))
    }

    func test_parseAntigravityCreds_garbageReturnsNil() {
        XCTAssertNil(GeminiCollector.parseAntigravityCreds(Data("not json".utf8)))
        XCTAssertNil(GeminiCollector.parseAntigravityCreds(Data("{}".utf8)))
    }

    // MARK: - RFC3339-nano expiry parsing

    func test_parseExpiry_microsecondFractionWithOffset() {
        // 6-digit fraction + non-Z offset — the strict ISO formatter rejects
        // this; the fraction-stripping fallback must still parse it, and the
        // +09:00 offset must be honoured (== 2026-06-20T17:08:45Z).
        let d = GeminiCollector.parseAntigravityExpiry("2026-06-21T02:08:45.204796+09:00")
        XCTAssertNotNil(d)
        let ref = ISO8601DateFormatter()
        let expected = ref.date(from: "2026-06-20T17:08:45Z")!
        XCTAssertEqual(d!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func test_parseExpiry_threeDigitFractionZulu() {
        XCTAssertNotNil(GeminiCollector.parseAntigravityExpiry("2026-06-22T15:07:33.123Z"))
    }

    func test_parseExpiry_noFraction() {
        XCTAssertNotNil(GeminiCollector.parseAntigravityExpiry("2026-06-22T15:07:33Z"))
    }

    func test_parseExpiry_garbageReturnsNil() {
        XCTAssertNil(GeminiCollector.parseAntigravityExpiry("nonsense"))
        XCTAssertNil(GeminiCollector.parseAntigravityExpiry(""))
    }

    // MARK: - Form URL encoding (refresh body)

    func test_formURLEncode_escapesReservedTokenChars() {
        // A real refresh_token contains '/', '+', '='. In the value they must
        // all be percent-encoded; the only literal '=' is the key/value join.
        let encoded = GeminiCollector.formURLEncode(["refresh_token": "1//0e+ab=cd/ef"])
        XCTAssertEqual(encoded, "refresh_token=1%2F%2F0e%2Bab%3Dcd%2Fef")
    }

    func test_formURLEncode_joinsPairsWithAmpersand() {
        let encoded = GeminiCollector.formURLEncode(["grant_type": "refresh_token"])
        XCTAssertEqual(encoded, "grant_type=refresh_token")
    }

    // MARK: - Embedded public client secrets (split-literal reassembly)

    func test_publicClientSecrets_reassembleToValidShape() {
        // Guards against a typo in the split string literals. These are public
        // installed-app secrets (GOCSPX-, 35 chars) — assert shape only, never
        // embed the full literal here (keeps the scanner quiet too).
        for secret in [GeminiOAuthClient.cliSecret, GeminiOAuthClient.agSecret] {
            XCTAssertTrue(secret.hasPrefix("GOCSPX-"))
            XCTAssertEqual(secret.count, 35)
            XCTAssertFalse(secret.contains(" "))
        }
        XCTAssertTrue(GeminiOAuthClient.cliId.hasSuffix(".apps.googleusercontent.com"))
        XCTAssertTrue(GeminiOAuthClient.agId.hasSuffix(".apps.googleusercontent.com"))
        XCTAssertNotEqual(GeminiOAuthClient.cliSecret, GeminiOAuthClient.agSecret)
    }

    // MARK: - Quota bucket parsing (the 3.1 Pro models agy reports)

    // MARK: - buildResult mapping (family grouping + lowest-fraction + display math)

    func test_buildResult_groupsFamiliesKeepsLowestAndMapsPlan() {
        let collector = GeminiCollector()
        let r = "2026-06-22T15:00:00Z"
        let buckets = [
            GeminiCollector.QuotaBucket(modelId: "gemini-3.1-pro-preview",  remainingFraction: 0.30, resetTime: r),
            GeminiCollector.QuotaBucket(modelId: "gemini-3-pro-preview",    remainingFraction: 0.55, resetTime: r),  // same family, higher
            GeminiCollector.QuotaBucket(modelId: "gemini-3-flash-preview",  remainingFraction: 0.80, resetTime: r),
            GeminiCollector.QuotaBucket(modelId: "gemini-3.1-flash-lite",   remainingFraction: 0.95, resetTime: r),
        ]
        let tier = GeminiCollector.TierInfo(tierId: "standard-tier", projectId: "p")
        let u = collector.buildResult(buckets: buckets, tierInfo: tier).usage

        XCTAssertEqual(u.plan_type, "Paid")  // standard-tier → Paid
        // Pro family keeps the LOWEST of its two buckets (0.30 → 30%).
        XCTAssertEqual(u.tiers.first { $0.name == "Pro" }?.remaining, 30)
        XCTAssertEqual(u.tiers.first { $0.name == "Flash" }?.remaining, 80)
        XCTAssertEqual(u.tiers.first { $0.name == "Flash Lite" }?.remaining, 95)
        // Tier order: Pro, Flash, Flash Lite (the preferred order).
        XCTAssertEqual(u.tiers.map(\.name), ["Pro", "Flash", "Flash Lite"])
        // Overall = the primary (Pro) family.
        XCTAssertEqual(u.remaining, 30)
        XCTAssertEqual(u.status_text, "70% used")
    }

    func test_buildResult_freeTierAndEmptyBuckets() {
        let collector = GeminiCollector()
        let free = collector.buildResult(
            buckets: [GeminiCollector.QuotaBucket(modelId: "gemini-2.5-flash", remainingFraction: 1.0, resetTime: nil)],
            tierInfo: GeminiCollector.TierInfo(tierId: "free-tier", projectId: "p")).usage
        XCTAssertEqual(free.plan_type, "Free")
        XCTAssertEqual(free.tiers.first { $0.name == "Flash" }?.remaining, 100)

        // No buckets → no tiers, defaults to 100% remaining (not a crash).
        let empty = collector.buildResult(buckets: [], tierInfo: nil).usage
        XCTAssertTrue(empty.tiers.isEmpty)
        XCTAssertEqual(empty.remaining, 100)
        XCTAssertEqual(empty.plan_type, "Unknown")
    }

    func test_parseQuota_handlesGemini31PreviewModels() throws {
        let json = """
        {"buckets":[
          {"modelId":"gemini-3.1-pro-preview","tokenType":"REQUESTS","remainingFraction":0.42,"resetTime":"2026-06-22T15:07:33Z"},
          {"modelId":"gemini-3-flash-preview","tokenType":"REQUESTS","remainingFraction":1.0,"resetTime":"2026-06-22T15:07:33Z"},
          {"modelId":"gemini-3.1-flash-lite","tokenType":"REQUESTS","remainingFraction":0.9,"resetTime":"2026-06-22T15:07:33Z"}
        ]}
        """
        let buckets = try GeminiCollector.parseQuota(Data(json.utf8))
        XCTAssertEqual(buckets.count, 3)
        let pro = try XCTUnwrap(buckets.first { $0.modelId == "gemini-3.1-pro-preview" })
        XCTAssertEqual(pro.remainingFraction, 0.42, accuracy: 0.001)
    }
}
#endif
