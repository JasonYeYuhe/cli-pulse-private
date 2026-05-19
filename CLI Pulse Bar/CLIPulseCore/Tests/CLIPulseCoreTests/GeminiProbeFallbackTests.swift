// Unit tests for the v1.23.0 G3 dark/opt-in GeminiStatusProbe
// fallback wired into GeminiCollector. Locks the Gemini 3.1 Pro R1
// adoptions: HIGH scale (percentLeft is already 0–100, no second
// ×100), Q3 consistency (snapshot→ProviderUsage mirrors buildResult),
// plan normalization, and LOW dark-safe Codable for the new
// ProviderConfig opt-in. macOS-gated like GeminiCollectorTests
// (GeminiCollector / GeminiStatusProbe are #if os(macOS)).

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class GeminiProbeFallbackTests: XCTestCase {
    private let collector = GeminiCollector()

    private func snap(
        _ quotas: [GeminiModelQuota],
        plan: String? = nil) -> GeminiStatusSnapshot
    {
        GeminiStatusSnapshot(
            modelQuotas: quotas,
            rawText: "",
            accountEmail: nil,
            accountPlan: plan)
    }

    // MARK: - Gemini R1 HIGH: percentLeft is 0–100, NOT re-multiplied

    func test_mapSnapshot_does_not_double_scale_percent() {
        let result = collector.mapSnapshot(snap([
            GeminiModelQuota(modelId: "gemini-2.0-pro", percentLeft: 85, resetTime: nil, resetDescription: nil),
            GeminiModelQuota(modelId: "gemini-2.0-flash", percentLeft: 60, resetTime: nil, resetDescription: nil),
            GeminiModelQuota(modelId: "gemini-2.0-flash-lite", percentLeft: 95, resetTime: nil, resetDescription: nil),
        ]))
        let u = result.usage
        XCTAssertEqual(u.quota, 100)
        // Primary family = Pro ⇒ overall remaining 85 (NOT 8500).
        XCTAssertEqual(u.remaining, 85)
        XCTAssertEqual(u.today_usage, 15)
        let pro = u.tiers.first { $0.name == "Pro" }
        let flash = u.tiers.first { $0.name == "Flash" }
        let lite = u.tiers.first { $0.name == "Flash Lite" }
        XCTAssertEqual(pro?.remaining, 85)
        XCTAssertEqual(flash?.remaining, 60)
        XCTAssertEqual(lite?.remaining, 95)
        XCTAssertEqual(pro?.quota, 100)
    }

    // MARK: - Q3 consistency: family grouping + primary-family order

    func test_mapSnapshot_keeps_lowest_per_family() {
        let result = collector.mapSnapshot(snap([
            GeminiModelQuota(modelId: "gemini-pro-exp", percentLeft: 90, resetTime: nil, resetDescription: nil),
            GeminiModelQuota(modelId: "gemini-2.5-pro", percentLeft: 40, resetTime: nil, resetDescription: nil),
        ]))
        XCTAssertEqual(result.usage.tiers.first { $0.name == "Pro" }?.remaining, 40)
        XCTAssertEqual(result.usage.remaining, 40)
    }

    func test_mapSnapshot_primary_family_falls_back_when_no_pro() {
        let result = collector.mapSnapshot(snap([
            GeminiModelQuota(modelId: "gemini-2.0-flash", percentLeft: 70, resetTime: nil, resetDescription: nil),
        ]))
        // No Pro ⇒ overall = Flash (next in preferred order).
        XCTAssertEqual(result.usage.remaining, 70)
        XCTAssertNil(result.usage.tiers.first { $0.name == "Pro" })
    }

    func test_mapSnapshot_clamps_out_of_range_percent() {
        let result = collector.mapSnapshot(snap([
            GeminiModelQuota(modelId: "gemini-pro", percentLeft: 140, resetTime: nil, resetDescription: nil),
        ]))
        XCTAssertEqual(result.usage.tiers.first { $0.name == "Pro" }?.remaining, 100)
    }

    // MARK: - reset_time: ISO round-trips (G4 pace + primary parity)

    func test_mapSnapshot_resetTime_serializes_iso_roundtrippable() throws {
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        let result = collector.mapSnapshot(snap([
            GeminiModelQuota(modelId: "gemini-pro", percentLeft: 50, resetTime: when, resetDescription: "soon"),
        ]))
        let resetStr = try XCTUnwrap(result.usage.reset_time)
        let parsed = try XCTUnwrap(sharedISO8601Parse(resetStr))
        XCTAssertEqual(parsed.timeIntervalSince1970, when.timeIntervalSince1970, accuracy: 1)
    }

    func test_mapSnapshot_resetDescription_used_when_no_date() {
        let result = collector.mapSnapshot(snap([
            GeminiModelQuota(modelId: "gemini-pro", percentLeft: 50, resetTime: nil, resetDescription: "in 3h"),
        ]))
        XCTAssertEqual(result.usage.reset_time, "in 3h")
    }

    // MARK: - Q3: plan normalization matches buildResult vocabulary

    func test_normalizePlan_matches_buildResult_vocabulary() {
        XCTAssertEqual(collector.normalizePlan("standard-tier"), "Paid")
        XCTAssertEqual(collector.normalizePlan("Gemini Code Assist Standard"), "Paid")
        XCTAssertEqual(collector.normalizePlan("free-tier"), "Free")
        XCTAssertEqual(collector.normalizePlan("legacy-tier"), "Legacy")
        XCTAssertEqual(collector.normalizePlan(nil), "Unknown")
        XCTAssertEqual(collector.normalizePlan(""), "Unknown")
        XCTAssertEqual(collector.normalizePlan("something-else"), "Unknown")
    }

    // MARK: - Gemini R1 LOW: ProviderConfig opt-in is dark-safe

    func test_providerConfig_probeFallback_defaults_off_and_is_darksafe() throws {
        // Default init ⇒ nil ⇒ OFF.
        let fresh = ProviderConfig(kind: .gemini)
        XCTAssertNil(fresh.geminiCliProbeFallback)

        // Synthesized Encodable uses encodeIfPresent for optionals ⇒
        // nil omits the key entirely, exactly simulating a legacy
        // stored config; decoding it back yields nil (OFF).
        let legacyJSON = try JSONEncoder().encode(fresh)
        XCTAssertFalse(
            String(data: legacyJSON, encoding: .utf8)!.contains("geminiCliProbeFallback"),
            "nil opt-in must not be serialized (legacy-config parity)")
        let roundTripped = try JSONDecoder().decode(ProviderConfig.self, from: legacyJSON)
        XCTAssertNil(roundTripped.geminiCliProbeFallback)

        // Explicit opt-in survives a round-trip.
        let optedIn = ProviderConfig(kind: .gemini, geminiCliProbeFallback: true)
        let data = try JSONEncoder().encode(optedIn)
        let back = try JSONDecoder().decode(ProviderConfig.self, from: data)
        XCTAssertEqual(back.geminiCliProbeFallback, true)
    }
}
#endif
