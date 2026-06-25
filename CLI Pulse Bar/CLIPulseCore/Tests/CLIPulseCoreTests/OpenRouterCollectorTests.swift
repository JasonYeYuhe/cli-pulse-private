#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class OpenRouterCollectorTests: XCTestCase {

    // MARK: - Credits parsing

    func testParseCreditsNormal() throws {
        let json = """
        {
            "data": {
                "total_credits": 10.0,
                "total_usage": 3.5
            }
        }
        """.data(using: .utf8)!

        let credits = try OpenRouterCollector.parseCredits(json)
        XCTAssertEqual(credits.totalCredits, 10.0, accuracy: 0.001)
        XCTAssertEqual(credits.totalUsage, 3.5, accuracy: 0.001)
        XCTAssertEqual(credits.balance, 6.5, accuracy: 0.001)
    }

    func testParseCreditsZeroBalance() throws {
        let json = """
        {
            "data": {
                "total_credits": 5.0,
                "total_usage": 5.0
            }
        }
        """.data(using: .utf8)!

        let credits = try OpenRouterCollector.parseCredits(json)
        XCTAssertEqual(credits.balance, 0.0, accuracy: 0.001)
    }

    func testParseCreditsOverspend() throws {
        let json = """
        {
            "data": {
                "total_credits": 5.0,
                "total_usage": 7.0
            }
        }
        """.data(using: .utf8)!

        let credits = try OpenRouterCollector.parseCredits(json)
        // balance should clamp to 0, not go negative
        XCTAssertEqual(credits.balance, 0.0, accuracy: 0.001)
    }

    func testParseCreditsInvalidJSON() {
        let json = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try OpenRouterCollector.parseCredits(json))
    }

    func testParseCreditsMissingDataKey() {
        let json = """
        { "total_credits": 10.0 }
        """.data(using: .utf8)!
        XCTAssertThrowsError(try OpenRouterCollector.parseCredits(json))
    }

    // MARK: - Key info parsing

    func testParseKeyInfoFull() throws {
        let json = """
        {
            "data": {
                "limit": 20.0,
                "usage": 0.5,
                "rate_limit": {
                    "requests": 120,
                    "interval": "10s"
                }
            }
        }
        """.data(using: .utf8)!

        let keyInfo = try OpenRouterCollector.parseKeyInfo(json)
        XCTAssertEqual(keyInfo.limit, 20.0)
        XCTAssertEqual(keyInfo.usage, 0.5)
        XCTAssertEqual(keyInfo.rateLimitRequests, 120)
        XCTAssertEqual(keyInfo.rateLimitInterval, "10s")
    }

    func testParseKeyInfoNoRateLimit() throws {
        let json = """
        {
            "data": {
                "limit": 10.0,
                "usage": 2.0
            }
        }
        """.data(using: .utf8)!

        let keyInfo = try OpenRouterCollector.parseKeyInfo(json)
        XCTAssertEqual(keyInfo.limit, 10.0)
        XCTAssertEqual(keyInfo.usage, 2.0)
        XCTAssertNil(keyInfo.rateLimitRequests)
        XCTAssertNil(keyInfo.rateLimitInterval)
    }

    func testParseKeyInfoNullLimit() throws {
        let json = """
        {
            "data": {
                "limit": null,
                "usage": null
            }
        }
        """.data(using: .utf8)!

        let keyInfo = try OpenRouterCollector.parseKeyInfo(json)
        XCTAssertNil(keyInfo.limit)
        XCTAssertNil(keyInfo.usage)
    }

    // MARK: - Availability

    func testCollectorNotAvailableWithoutKey() {
        let collector = OpenRouterCollector()
        let config = ProviderConfig(kind: .openRouter)
        XCTAssertFalse(collector.isAvailable(config: config))
    }

    func testCollectorAvailableWithKey() {
        let collector = OpenRouterCollector()
        let config = ProviderConfig(kind: .openRouter, apiKey: "sk-or-v1-test")
        XCTAssertTrue(collector.isAvailable(config: config))
    }

    func testCollectorNotAvailableWithEmptyKey() {
        let collector = OpenRouterCollector()
        let config = ProviderConfig(kind: .openRouter, apiKey: "")
        XCTAssertFalse(collector.isAvailable(config: config))
    }

    // MARK: - CollectorRegistry

    func testRegistryFindsOpenRouter() {
        let config = ProviderConfig(kind: .openRouter, apiKey: "sk-test")
        let collector = CollectorRegistry.collector(for: .openRouter, config: config)
        XCTAssertNotNil(collector)
        XCTAssertEqual(collector?.kind, .openRouter)
    }

    func testRegistryReturnsNilWithoutKey() {
        let config = ProviderConfig(kind: .openRouter)
        let collector = CollectorRegistry.collector(for: .openRouter, config: config)
        XCTAssertNil(collector)
    }

    func testRegistryReturnsNilWhenCursorAutoImportDisabledAndNoCookie() {
        // Cursor auto-imports its browser session by default, so a bare
        // `ProviderConfig(kind: .cursor)` IS available. A user who explicitly
        // picks a non-automatic source (.manual) without supplying a cookie has
        // opted OUT — the registry must then return no collector. (An API key
        // is irrelevant to Cursor, which is cookie-based.)
        let config = ProviderConfig(kind: .cursor, cookieSource: .manual)
        let collector = CollectorRegistry.collector(for: .cursor, config: config)
        XCTAssertNil(collector)
    }
}
#endif
