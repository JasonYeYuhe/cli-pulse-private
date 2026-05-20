// Unit tests for the v1.23.0 Phase C-3 ElevenLabsCollector (new
// api-key .quota provider with custom xi-api-key header). Locks the
// Gemini Phase-C3 R1 adoptions: snake_case Codable, Unix→ISO reset
// via sharedISO8601Formatter, displayTier transform, voice-slot
// sub-tiers, current_overage in status_text. macOS-gated like the
// other collector tests.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ElevenLabsCollectorTests: XCTestCase {
    private let collector = ElevenLabsCollector()

    private func decode(_ json: String) throws -> ElevenLabsCollector.SubscriptionResponse {
        try ElevenLabsCollector.parseResponse(Data(json.utf8))
    }

    // MARK: - Parse

    func test_parseResponse_decodes_snake_case() throws {
        let r = try decode("""
        {"tier":"starter","character_count":1000,"character_limit":10000,
         "voice_slots_used":3,"voice_limit":10,"status":"active",
         "next_character_count_reset_unix":1750000000}
        """)
        XCTAssertEqual(r.tier, "starter")
        XCTAssertEqual(r.characterCount, 1000)
        XCTAssertEqual(r.characterLimit, 10000)
        XCTAssertEqual(r.voiceSlotsUsed, 3)
        XCTAssertEqual(r.voiceLimit, 10)
        XCTAssertEqual(r.status, "active")
        XCTAssertEqual(r.nextCharacterCountResetUnix, 1_750_000_000)
    }

    func test_parseResponse_minimal_required_only() throws {
        let r = try decode(#"{"character_count": 0, "character_limit": 1000}"#)
        XCTAssertEqual(r.characterLimit, 1000)
        XCTAssertNil(r.tier)
        XCTAssertNil(r.nextCharacterCountResetUnix)
    }

    func test_parseResponse_invalid_throws() {
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{}")) // missing required keys
    }

    // MARK: - displayTier transform (Gemini R1 MEDIUM — verbatim port)

    func test_displayTier_active_title_cased() {
        XCTAssertEqual(
            ElevenLabsCollector.displayTier("free_v2", status: "active"),
            "Free V2")
    }

    func test_displayTier_non_active_appends_status() {
        XCTAssertEqual(
            ElevenLabsCollector.displayTier("starter", status: "trialing"),
            "Starter · trialing")
    }

    func test_displayTier_nil_tier_falls_back_to_status() {
        XCTAssertEqual(
            ElevenLabsCollector.displayTier(nil, status: "trialing"),
            "trialing")
        XCTAssertNil(ElevenLabsCollector.displayTier(nil, status: nil))
        XCTAssertNil(ElevenLabsCollector.displayTier("", status: nil))
    }

    // MARK: - Counter formatting

    func test_formatCount_groups_with_commas() {
        XCTAssertEqual(ElevenLabsCollector.formatCount(1_234_567), "1,234,567")
        XCTAssertEqual(ElevenLabsCollector.formatCount(0), "0")
    }

    // MARK: - buildResult: .quota + reset ISO + tiers + overage

    func test_buildResult_quota_mapping_and_reset_iso_roundtrip() throws {
        let when = 1_750_000_000
        let r = try decode("""
        {"tier":"starter_v2","character_count":2500,"character_limit":10000,
         "status":"active","next_character_count_reset_unix":\(when)}
        """)
        let res = collector.buildResult(r)
        XCTAssertEqual(res.dataKind, .quota)
        let u = res.usage
        XCTAssertEqual(u.quota, 10_000)
        XCTAssertEqual(u.remaining, 7_500)
        XCTAssertEqual(u.today_usage, 2_500)
        XCTAssertEqual(u.plan_type, "Starter V2")  // active ⇒ no suffix
        let resetISO = try XCTUnwrap(u.reset_time)
        let parsed = try XCTUnwrap(sharedISO8601Parse(resetISO))
        XCTAssertEqual(parsed.timeIntervalSince1970, TimeInterval(when), accuracy: 1)
        // status_text contains the formatted counts.
        XCTAssertTrue(u.status_text.contains("2,500"))
        XCTAssertTrue(u.status_text.contains("10,000"))
        XCTAssertTrue(u.status_text.contains("characters"))
    }

    func test_buildResult_includes_voice_slot_tiers_when_present() throws {
        let r = try decode("""
        {"character_count":0,"character_limit":1000,
         "voice_slots_used":2,"voice_limit":10,
         "professional_voice_slots_used":1,"professional_voice_limit":3}
        """)
        let u = collector.buildResult(r).usage
        XCTAssertEqual(u.tiers.count, 3)
        XCTAssertEqual(u.tiers.first?.name, "Characters")
        XCTAssertEqual(u.tiers.first(where: { $0.name == "Voice slots" })?.remaining, 8)
        XCTAssertEqual(u.tiers.first(where: { $0.name == "Professional voices" })?.remaining, 2)
    }

    func test_buildResult_skips_voice_tiers_when_absent_or_zero() throws {
        let r = try decode(#"{"character_count":0,"character_limit":1000}"#)
        let u = collector.buildResult(r).usage
        XCTAssertEqual(u.tiers.count, 1)
        XCTAssertEqual(u.tiers.first?.name, "Characters")
    }

    func test_buildResult_appends_overage_to_status_text() throws {
        let r = try decode("""
        {"character_count":1000,"character_limit":1000,
         "current_overage":{"amount":"1.23","currency":"USD"}}
        """)
        let u = collector.buildResult(r).usage
        XCTAssertTrue(u.status_text.contains("Overage: 1.23 USD"))
    }

    func test_buildResult_no_overage_when_fields_missing() throws {
        let r = try decode(#"{"character_count":0,"character_limit":1000}"#)
        let u = collector.buildResult(r).usage
        XCTAssertFalse(u.status_text.contains("Overage"))
    }

    func test_buildResult_zero_limit_yields_nil_quota_and_no_tiers() throws {
        let r = try decode(#"{"character_count":0,"character_limit":0}"#)
        let u = collector.buildResult(r).usage
        XCTAssertNil(u.quota)
        XCTAssertTrue(u.tiers.isEmpty)
    }

    // MARK: - Availability

    func test_isAvailable_matrix() {
        XCTAssertFalse(collector.isAvailable(config: ProviderConfig(kind: .elevenLabs)))
        XCTAssertTrue(collector.isAvailable(
            config: ProviderConfig(kind: .elevenLabs, apiKey: "xi-key-test")))
        XCTAssertFalse(collector.isAvailable(
            config: ProviderConfig(kind: .elevenLabs, apiKey: "  ")))
    }

    // MARK: - New ProviderKind case (per the new-ProviderKind checklist)

    func test_providerKind_elevenLabs_case() {
        XCTAssertEqual(ProviderKind(rawValue: "ElevenLabs"), .elevenLabs)
        XCTAssertEqual(ProviderKind.elevenLabs.rawValue, "ElevenLabs")
        XCTAssertEqual(ProviderKind.elevenLabs.iconName, "waveform")
        XCTAssertTrue(ProviderKind.allCases.contains(.elevenLabs))
        XCTAssertEqual(collector.kind, .elevenLabs)
    }
}
#endif
