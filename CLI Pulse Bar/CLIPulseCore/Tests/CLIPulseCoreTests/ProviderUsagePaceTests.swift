// Unit tests for the v1.23.0 G4 ProviderUsage→UsagePace UI bridge
// (`ProviderUsage+Pace.swift`). Covers the Gemini 3.1 Pro R1-adopted
// reset-anchor guard, the 0…1 → 0…100 scale conversion, provider
// gating, and seam equivalence (the bridge must delegate faithfully
// to the vendored engine). en-locale pinned (mirrors
// UsagePaceTextTests) so any literal text stays deterministic.

import XCTest
@testable import CLIPulseCore

final class ProviderUsagePaceTests: XCTestCase {
    private var savedLocaleOverride: String?

    override func setUp() {
        super.setUp()
        savedLocaleOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("en")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedLocaleOverride)
        super.tearDown()
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func usage(
        provider: String,
        quota: Int?,
        remaining: Int?,
        reset_time: String?) -> ProviderUsage
    {
        ProviderUsage(
            provider: provider,
            today_usage: 0, week_usage: 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "ok", cost_status_week: "ok",
            quota: quota, remaining: remaining,
            reset_time: reset_time,
            status_text: "",
            trend: [], recent_sessions: [], recent_errors: [])
    }

    // MARK: - Scale + reset anchor

    func test_paceRateWindow_scales_0to1_into_0to100() throws {
        let u = usage(provider: "Codex", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        let w = try XCTUnwrap(u.paceRateWindow(now: now))
        XCTAssertEqual(w.usedPercent, 60, accuracy: 0.0001)  // (100-40)/100 → 0.6 → ×100
        XCTAssertNil(w.windowMinutes)
        let resetsAt = try XCTUnwrap(w.resetsAt)
        XCTAssertEqual(resetsAt.timeIntervalSince(now), 3 * 24 * 3600, accuracy: 1)
    }

    func test_missing_reset_time_suppresses_pace() {            // Gemini R1 MEDIUM
        let u = usage(provider: "Codex", quota: 100, remaining: 40, reset_time: nil)
        XCTAssertNil(u.paceRateWindow(now: now))
        XCTAssertNil(u.paceSummary(now: now))
        XCTAssertNil(u.paceDetail(now: now))
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    func test_non_iso8601_reset_time_suppresses_pace() {        // Gemini R1 MEDIUM
        let u = usage(provider: "Codex", quota: 100, remaining: 40,
                      reset_time: "in 3 hours")
        XCTAssertNil(u.paceRateWindow(now: now))
        XCTAssertNil(u.paceSummary(now: now))
    }

    func test_past_reset_time_suppresses_pace() {               // Gemini R1 MEDIUM
        let u = usage(provider: "Codex", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(-3600)))
        XCTAssertNil(u.paceRateWindow(now: now))
        XCTAssertNil(u.paceSummary(now: now))
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    // MARK: - Provider gating

    func test_non_codex_claude_provider_yields_nil_pace() {
        let u = usage(provider: "Cursor", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        XCTAssertNotNil(u.paceRateWindow(now: now))   // window itself is provider-agnostic
        XCTAssertNil(u.paceSummary(now: now))         // engine gates to Codex/Claude
        XCTAssertNil(u.paceDetail(now: now))
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    func test_unknown_provider_string_yields_nil_pace() {
        let u = usage(provider: "Nonsense", quota: 100, remaining: 40,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        XCTAssertNil(u.paceSummary(now: now))         // providerKind == nil
        XCTAssertNil(u.paceMenuLabel(now: now))
    }

    // MARK: - Seam equivalence: bridge delegates faithfully to the engine

    func test_summary_detail_match_direct_engine_call() throws {
        let u = usage(provider: "Codex", quota: 100, remaining: 50,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        let w = try XCTUnwrap(u.paceRateWindow(now: now))
        XCTAssertEqual(
            u.paceSummary(now: now),
            UsagePaceText.sessionSummary(provider: .codex, window: w, now: now))
        XCTAssertEqual(
            u.paceDetail(now: now)?.leftLabel,
            UsagePaceText.sessionDetail(provider: .codex, window: w, now: now)?.leftLabel)
    }

    func test_menu_label_is_compact_and_stage_consistent() throws {
        let u = usage(provider: "Codex", quota: 100, remaining: 50,
                      reset_time: iso(now.addingTimeInterval(3 * 24 * 3600)))
        let w = try XCTUnwrap(u.paceRateWindow(now: now))
        let pace = UsagePaceText.sessionPace(provider: .codex, window: w, now: now)
        let label = u.paceMenuLabel(now: now)

        if let pace {
            let expectedPrefix: String
            switch pace.stage {
            case .onTrack: expectedPrefix = "≈"
            case .slightlyAhead, .ahead, .farAhead: expectedPrefix = "▲"
            case .slightlyBehind, .behind, .farBehind: expectedPrefix = "▼"
            }
            XCTAssertEqual(label?.hasPrefix(expectedPrefix), true)
            XCTAssertLessThanOrEqual(label?.count ?? 0, 6)  // ultra-compact menu form
        } else {
            XCTAssertNil(label)
        }
    }
}
