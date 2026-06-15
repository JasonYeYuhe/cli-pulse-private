import XCTest
@testable import CLIPulseCore

final class SaturatingIntTests: XCTestCase {

    private struct Box: Codable, Equatable {
        @SaturatingInt var n: Int
    }

    func test_decodesNormalValue() throws {
        let box = try JSONDecoder().decode(Box.self, from: Data(#"{"n": 12345}"#.utf8))
        XCTAssertEqual(box.n, 12_345)
    }

    func test_decodesZeroAndNegative() throws {
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data(#"{"n": 0}"#.utf8)).n, 0)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: Data(#"{"n": -42}"#.utf8)).n, -42)
    }

    func test_decodesValueAboveInt32_exactlyOn64bit() throws {
        // 5e9 > Int32.max (2.1e9). On the 64-bit test host Int is 64-bit, so
        // it decodes EXACTLY — proving no truncation on iPhone/Mac. (On the
        // 32-bit watch it would saturate; that path is covered by clamp().)
        let big: Int64 = 5_000_000_000
        let box = try JSONDecoder().decode(Box.self, from: Data("{\"n\": \(big)}".utf8))
        XCTAssertEqual(Int64(box.n), big)
    }

    func test_clamp_withinRange() {
        XCTAssertEqual(SaturatingInt.clamp(5), 5)
        XCTAssertEqual(SaturatingInt.clamp(-5), -5)
        XCTAssertEqual(SaturatingInt.clamp(0), 0)
    }

    func test_clamp_saturatesAtPlatformBounds() {
        // On any platform, clamping Int64's extremes yields the platform Int
        // bounds (on 32-bit watch this is what protects the decode).
        XCTAssertEqual(SaturatingInt.clamp(Int64.max), Int.max)
        XCTAssertEqual(SaturatingInt.clamp(Int64.min), Int.min)
        XCTAssertEqual(SaturatingInt.clamp(Int64(Int.max)), Int.max)
    }

    func test_encodeRoundTrips() throws {
        let box = Box(n: 987_654)
        let data = try JSONEncoder().encode(box)
        XCTAssertEqual(try JSONDecoder().decode(Box.self, from: data), box)
        // Encodes as a bare integer, not an object.
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"n":987654}"#)
    }

    // Real model: a ProviderUsage with a > Int32 token field decodes (would
    // previously throw on the 32-bit watch).
    func test_providerUsage_decodesLargeUsage() throws {
        let json = #"""
        {"provider":"Claude","today_usage":5000000000,"week_usage":9000000000,
         "estimated_cost_today":1.0,"estimated_cost_week":1.0,"estimated_cost_30_day":1.0,
         "cost_status_today":"Estimated","cost_status_week":"Estimated",
         "quota":100,"remaining":40,"tiers":[],"status_text":"",
         "trend":[],"recent_sessions":[],"recent_errors":[]}
        """#
        let p = try JSONDecoder().decode(ProviderUsage.self, from: Data(json.utf8))
        XCTAssertEqual(Int64(p.today_usage), 5_000_000_000) // exact on 64-bit host
        XCTAssertEqual(Int64(p.week_usage), 9_000_000_000)
    }
}
