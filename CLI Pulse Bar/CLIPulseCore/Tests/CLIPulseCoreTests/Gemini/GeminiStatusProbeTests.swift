// 1:1 XCTest port of steipete/CodexBar
// Tests/CodexBarTests/GeminiStatusProbeTests.swift
// (swift-testing → XCTest). The 4 `to usage snapshot …` tests are
// intentionally NOT ported — `toUsageSnapshot()` was dropped from the
// vendored probe; the equivalent Pro/Flash/FlashLite mapping is covered
// by CLIPulseCore's existing GeminiCollector + GeminiCollectorTests.
// See GeminiStatusProbe.swift for the MIT attribution of the code under test.

import Foundation
import XCTest
@testable import CLIPulseCore

final class GeminiStatusProbeTests: XCTestCase {
    /// Sample /stats output from Gemini CLI (actual format with box-drawing chars)
    static let sampleStatsOutput = """
    │  Model Usage                            Reqs                  Usage left  │
    │  ───────────────────────────────────────────────────────────────────────  │
    │  gemini-2.5-flash                          -   99.8% (Resets in 20h 37m)  │
    │  gemini-2.5-flash-lite                     -   99.8% (Resets in 20h 37m)  │
    │  gemini-2.5-pro                            -      100.0% (Resets in 24h)  │
    │  gemini-3-pro-preview                      -      100.0% (Resets in 24h)  │
    """

    // MARK: - Legacy CLI parsing tests (kept for fallback support)

    func test_parses_minimum_percent_from_multiple_models() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        XCTAssertEqual(snap.dailyPercentLeft, 99.8)
        XCTAssertEqual(snap.resetDescription, "Resets in 20h 37m")
    }

    func test_parses_lower_percent_correctly() throws {
        let output = """
        │  Model Usage                                                  Reqs                  Usage left  │
        │  gemini-2.5-flash                                               10       85.5% (Resets in 12h)  │
        │  gemini-2.5-pro                                                  5       92.0% (Resets in 12h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)
        XCTAssertEqual(snap.dailyPercentLeft, 85.5)
        XCTAssertEqual(snap.resetDescription, "Resets in 12h")
    }

    func test_handles_zero_percent_usage() throws {
        let output = """
        │  gemini-2.5-flash                                               50        0.0% (Resets in 6h)  │
        │  gemini-2.5-pro                                                 20       15.0% (Resets in 6h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)
        XCTAssertEqual(snap.dailyPercentLeft, 0.0)
        XCTAssertEqual(snap.resetDescription, "Resets in 6h")
    }

    func test_handles_100_percent_remaining() throws {
        let output = """
        │  gemini-2.5-flash                                                -      100.0% (Resets in 24h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)
        XCTAssertEqual(snap.dailyPercentLeft, 100.0)
    }

    func test_throws_on_empty_output() {
        XCTAssertThrowsError(try GeminiStatusProbe.parse(text: "")) { error in
            XCTAssertTrue(error is GeminiStatusProbeError)
        }
    }

    func test_throws_on_no_usage_data() {
        let output = """
        Welcome to Gemini CLI!
        Type /help for available commands.
        """
        XCTAssertThrowsError(try GeminiStatusProbe.parse(text: output)) { error in
            XCTAssertTrue(error is GeminiStatusProbeError)
        }
    }

    func test_strips_ansi_codes_before_parsing() throws {
        let output =
            "\u{1B}[32m│\u{1B}[0m  gemini-2.5-flash                                                -       75.5% " +
            "(Resets in 18h)  │"
        let snap = try GeminiStatusProbe.parse(text: output)
        XCTAssertEqual(snap.dailyPercentLeft, 75.5)
    }

    func test_preserves_raw_text() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        XCTAssertEqual(snap.rawText, Self.sampleStatsOutput)
        XCTAssertNil(snap.accountEmail) // Legacy parse doesn't extract email
        XCTAssertNil(snap.accountPlan)
    }

    func test_parses_various_reset_descriptions() throws {
        let cases: [(String, String)] = [
            ("Resets in 24h", "Resets in 24h"),
            ("Resets in 1h 30m", "Resets in 1h 30m"),
            ("Resets tomorrow", "Resets tomorrow"),
        ]
        for (resetStr, expected) in cases {
            let output = """
            │  gemini-2.5-flash                                                -       50.0% (\(resetStr))  │
            """
            let snap = try GeminiStatusProbe.parse(text: output)
            XCTAssertEqual(snap.resetDescription, expected)
        }
    }

    func test_throws_not_logged_in_on_auth_prompt() {
        let authOutputs = [
            "Waiting for auth... (Press ESC or CTRL+C to cancel)",
            "Login with Google\nUse Gemini API key",
            "Some preamble\nWaiting for auth\nMore text",
        ]
        for output in authOutputs {
            XCTAssertThrowsError(try GeminiStatusProbe.parse(text: output)) { error in
                XCTAssertEqual(error as? GeminiStatusProbeError, .notLoggedIn)
            }
        }
    }

    // MARK: - Model quota grouping tests

    func test_parses_models_into_quota_array() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        // Should parse multiple models (exact count may change as Google adds/removes models)
        XCTAssertGreaterThanOrEqual(snap.modelQuotas.count, 2)

        // All model IDs should start with "gemini"
        for quota in snap.modelQuotas {
            XCTAssertTrue(quota.modelId.hasPrefix("gemini"))
        }
    }

    func test_lowest_percent_left_returns_minimum() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)
        // Flash models are 99.8%, Pro models are 100%, so min should be 99.8
        XCTAssertEqual(snap.lowestPercentLeft, 99.8)
    }

    func test_tier_grouping_by_keyword() throws {
        // Test that flash/pro keyword filtering works (model names may change)
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)

        let flashQuotas = snap.modelQuotas.filter { $0.modelId.contains("flash") && !$0.modelId.contains("flash-lite") }
        let flashLiteQuotas = snap.modelQuotas.filter { $0.modelId.contains("flash-lite") }
        let proQuotas = snap.modelQuotas.filter { $0.modelId.contains("pro") }

        // Should have at least one of each tier in sample
        XCTAssertFalse(flashQuotas.isEmpty)
        XCTAssertFalse(flashLiteQuotas.isEmpty)
        XCTAssertFalse(proQuotas.isEmpty)
    }

    func test_tier_minimum_calculation() throws {
        // Use controlled test data to verify min-per-tier logic
        // Model names must start with "gemini-" to match the parser regex
        let output = """
        │  gemini-a-flash                            10       85.0% (Resets in 24h)  │
        │  gemini-b-flash                             5       92.0% (Resets in 24h)  │
        │  gemini-c-pro                               2       95.0% (Resets in 24h)  │
        │  gemini-d-pro                               1       99.0% (Resets in 24h)  │
        """
        let snap = try GeminiStatusProbe.parse(text: output)

        let flashQuotas = snap.modelQuotas.filter { $0.modelId.contains("flash") }
        let proQuotas = snap.modelQuotas.filter { $0.modelId.contains("pro") }

        let flashMin = flashQuotas.min(by: { $0.percentLeft < $1.percentLeft })
        let proMin = proQuotas.min(by: { $0.percentLeft < $1.percentLeft })

        XCTAssertEqual(flashMin?.percentLeft, 85.0)
        XCTAssertEqual(proMin?.percentLeft, 95.0)
    }

    func test_quotas_have_reset_descriptions() throws {
        let snap = try GeminiStatusProbe.parse(text: Self.sampleStatsOutput)

        // At least some quotas should have reset descriptions
        let hasResets = snap.modelQuotas.contains { $0.resetDescription != nil }
        XCTAssertTrue(hasResets)
    }

    // MARK: - Live API test (env-gated; no-ops in CI)

    func test_live_gemini_fetch() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_GEMINI_FETCH"] == "1" else {
            return
        }
        let probe = GeminiStatusProbe()
        let snap = try await probe.fetch()
        print(
            """
            Live Gemini usage (via API):
            models: \(snap.modelQuotas.map { "\($0.modelId): \($0.percentLeft)%" }.joined(separator: ", "))
            lowest: \(snap.lowestPercentLeft ?? -1)% left
            """)
        XCTAssertFalse(snap.modelQuotas.isEmpty)
    }
}
