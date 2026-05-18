// 1:1 XCTest port of steipete/CodexBar
// Tests/CodexBarTests/UsagePaceTextTests.swift
// (swift-testing `@Test`/`#expect`/`#require` → XCTest). Fixture
// coverage kept identical so future cherry-picks stay drop-in.
//
// UsagePaceText routes its phrases through L10n (G4); setUp() pins the
// in-app locale override to "en" so these English-literal assertions
// stay deterministic regardless of host language. tearDown() restores
// the previous override. (Mirrors ClaudePeakHoursTests.) See
// UsagePaceText.swift for the MIT attribution of the code under test.

import XCTest
@testable import CLIPulseCore

final class UsagePaceTextTests: XCTestCase {
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

    func test_weekly_pace_detail_provides_left_right_labels() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try XCTUnwrap(UsagePace.weekly(window: window, now: now))

        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

        XCTAssertEqual(detail.leftLabel, "7% in deficit")
        XCTAssertEqual(detail.rightLabel, "Runs out in 3d")
    }

    func test_weekly_pace_detail_reports_lasts_until_reset() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try XCTUnwrap(UsagePace.weekly(window: window, now: now))

        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

        XCTAssertEqual(detail.leftLabel, "33% in reserve")
        XCTAssertEqual(detail.rightLabel, "Lasts until reset")
    }

    func test_weekly_pace_summary_formats_single_line_text() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)
        let pace = try XCTUnwrap(UsagePace.weekly(window: window, now: now))

        let summary = UsagePaceText.weeklySummary(pace: pace, now: now)

        XCTAssertEqual(summary, "Pace: 7% in deficit · Runs out in 3d")
    }

    func test_weekly_pace_detail_formats_rounded_risk_when_available() {
        let now = Date(timeIntervalSince1970: 0)
        let pace = UsagePace(
            stage: .ahead,
            deltaPercent: 8,
            expectedUsedPercent: 42,
            actualUsedPercent: 50,
            etaSeconds: 2 * 24 * 3600,
            willLastToReset: false,
            runOutProbability: 0.683)

        let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

        XCTAssertEqual(detail.rightLabel, "Runs out in 2d · ≈ 70% run-out risk")
    }

    // MARK: - Session pace (5-hour window)

    func test_session_pace_detail_provides_left_right_labels() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute window, 2h remaining => 3h elapsed out of 5h
        // expected = 60%, actual = 80% => 20% ahead (in deficit)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.leftLabel, "20% in deficit")
        XCTAssertEqual(detail?.rightLabel, "Projected empty in 45m")
        XCTAssertEqual(detail?.stage, .farAhead)
    }

    func test_session_pace_detail_reports_lasts_until_reset() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute window, 2h remaining => 3h elapsed
        // expected = 60%, actual = 10% => far behind (in reserve)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        XCTAssertNotNil(detail)
        XCTAssertEqual(detail?.leftLabel, "50% in reserve")
        XCTAssertEqual(detail?.rightLabel, "Lasts until reset")
    }

    func test_session_pace_summary_formats_single_line_text() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let summary = UsagePaceText.sessionSummary(provider: .claude, window: window, now: now)

        XCTAssertEqual(summary, "Pace: 20% in deficit · Projected empty in 45m")
    }

    func test_session_pace_detail_hides_for_unsupported_provider() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .zai, window: window, now: now)

        XCTAssertNil(detail)
    }

    func test_session_pace_detail_hides_when_reset_is_missing() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        XCTAssertNil(detail)
    }
}
