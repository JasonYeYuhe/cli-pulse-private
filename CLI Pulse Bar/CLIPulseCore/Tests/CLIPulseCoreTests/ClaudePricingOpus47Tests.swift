#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Regression tests for the Claude Opus 4.7 pricing gap and the
/// family-fallback safety net.
///
/// Background (May 2026): the user reported `Today: <$0.01` on the
/// macOS Claude card despite hundreds of millions of cache_read
/// tokens. Root cause was a pricing-table miss — every assistant
/// event in current Claude Code (Max 20x) traffic uses
/// `claude-opus-4-7`, and the dictionary stopped at `4-6`. The cost
/// path returned `nil` → `costNanos = 0` → the "Today" sum was
/// trivially 0.
///
/// Pricing source for the values asserted below: Anthropic's
/// official API pricing page
/// (https://platform.claude.com/docs/en/about-claude/pricing).
/// Opus 4.7 published rate is $5 / 1M input, $25 / 1M output,
/// $0.50 / 1M cache_read (10% of input), $6.25 / 1M cache_create
/// (1.25× input — Anthropic's standard 5-minute cache write
/// multiplier). Headline rate is unchanged from Opus 4.6.
///
/// These tests pin four guarantees:
///  1. `claude-opus-4-7` round-trips through the explicit dictionary
///     entry with the official $5/$25/$0.50/$6.25 rate card.
///  2. A future `claude-(opus|sonnet|haiku)-N-X` whose exact key
///     hasn't been added yet falls back to the highest-numbered
///     priced sibling in the same family — never $0.
///  3. The legacy `claude-sonnet-4-20250514` row (date suffix that
///     looks like a giant minor version) does NOT poison the
///     family-fallback comparison.
///  4. End-to-end: a synthetic Claude JSONL fixture run through
///     `parseClaudeFile` produces the expected per-day cost in cache
///     and surfaces it to the `CostUsageScanResult` consumer.
final class ClaudePricingOpus47Tests: XCTestCase {

    // MARK: - 1. Explicit Opus 4.7 entry

    func testOpus47_inputOutputCacheCostsMatchOfficialAnthropicRateCard() {
        // Per https://platform.claude.com/docs/en/about-claude/pricing
        // (Opus 4.7 row, May 2026):
        //   1,000,000 input        @ $5/M    → $5.00
        //   1,000,000 output       @ $25/M   → $25.00
        //   1,000,000 cache_read   @ $0.50/M → $0.50
        //   1,000,000 cache_create @ $6.25/M → $6.25
        //   ──────────────────────────────────────────
        //                                       $36.75
        let cost = CostUsageScanner.Pricing.claudeCostUSD(
            model: "claude-opus-4-7",
            inputTokens: 1_000_000,
            cacheReadInputTokens: 1_000_000,
            cacheCreationInputTokens: 1_000_000,
            outputTokens: 1_000_000
        )
        XCTAssertNotNil(cost, "Opus 4.7 must NOT return nil cost — that was the bug")
        XCTAssertEqual(cost ?? 0, 36.75, accuracy: 0.0001)
    }

    func testOpus47_priceMatchesOpus46Exactly() {
        // Anthropic's official pricing page lists Opus 4.7 at the same
        // headline rate as Opus 4.6 (May 2026). Lock that invariant in
        // so a future edit to one entry doesn't drift the other.
        let bundle = (
            input: 1_234_567,
            cacheRead: 9_876_543,
            cacheCreate: 2_222_222,
            output: 333_333
        )
        let opus47 = CostUsageScanner.Pricing.claudeCostUSD(
            model: "claude-opus-4-7",
            inputTokens: bundle.input,
            cacheReadInputTokens: bundle.cacheRead,
            cacheCreationInputTokens: bundle.cacheCreate,
            outputTokens: bundle.output
        )
        let opus46 = CostUsageScanner.Pricing.claudeCostUSD(
            model: "claude-opus-4-6",
            inputTokens: bundle.input,
            cacheReadInputTokens: bundle.cacheRead,
            cacheCreationInputTokens: bundle.cacheCreate,
            outputTokens: bundle.output
        )
        XCTAssertNotNil(opus47); XCTAssertNotNil(opus46)
        XCTAssertEqual(opus47 ?? 0, opus46 ?? -1, accuracy: 0.0001)
    }

    // MARK: - 2 + 3. Family fallback safety net

    func testNormalize_unknownFutureOpusFallsBackToHighestKnownMinor() {
        // `claude-opus-4-8` doesn't exist yet. Without the family
        // fallback, the next minor release silently regresses cost
        // to $0 the day it ships.
        let normalized = CostUsageScanner.Pricing.normalizeClaudeModel("claude-opus-4-8")
        XCTAssertEqual(normalized, "claude-opus-4-7",
            "unknown opus minor should fall back to the highest priced sibling in the same family")
    }

    func testNormalize_unknownFutureSonnetFallsBackToHighestKnownMinor() {
        let normalized = CostUsageScanner.Pricing.normalizeClaudeModel("claude-sonnet-4-9")
        XCTAssertEqual(normalized, "claude-sonnet-4-6",
            "unknown sonnet minor should fall back to the highest priced sibling in the same family")
    }

    func testNormalize_unknownFutureHaikuFallsBackToHighestKnownMinor() {
        let normalized = CostUsageScanner.Pricing.normalizeClaudeModel("claude-haiku-4-9")
        XCTAssertEqual(normalized, "claude-haiku-4-5",
            "unknown haiku minor should fall back to the highest priced sibling in the same family")
    }

    func testFamilyFallback_doesNotPickUpDateSuffixSibling() {
        // The dict carries a legacy `claude-sonnet-4-20250514` entry
        // whose tail (`20250514`) parses as a giant integer. If the
        // fallback sorted naively by Int(tail), this would always
        // beat real minor versions like 5/6/7. Pin the bug closed.
        let fallback = CostUsageScanner.Pricing.familyFallback("claude-sonnet-4-99")
        XCTAssertEqual(fallback, "claude-sonnet-4-6")
        XCTAssertNotEqual(fallback, "claude-sonnet-4-20250514")
    }

    func testFamilyFallback_returnsNilForUnknownFamilyStem() {
        // We deliberately don't auto-fallback for non-claude family
        // stems or for malformed inputs — a typo shouldn't silently
        // bill against an unrelated model.
        XCTAssertNil(CostUsageScanner.Pricing.familyFallback("not-a-claude-thing"))
        XCTAssertNil(CostUsageScanner.Pricing.familyFallback("gpt-5-pro"))
    }

    func testNormalize_unchangedExplicitOpus47StillReturnsExplicitKey() {
        // Explicit dictionary hit beats the fallback path.
        XCTAssertEqual(
            CostUsageScanner.Pricing.normalizeClaudeModel("claude-opus-4-7"),
            "claude-opus-4-7"
        )
    }

    // MARK: - 4. End-to-end through parseClaudeFile + entriesFromClaudeCache

    /// Build a synthetic JSONL with three assistant events (one Opus
    /// 4.7, one Sonnet 4.6, one synthetic-stream-chunk dup of the
    /// first) and prove that the public `CostUsageScanResult`
    /// surfaces a non-zero Today cost.
    func testEndToEnd_opus47SyntheticJsonlSurfacesNonZeroCost() throws {
        // 1. Build the fixture — schema-only, no real prompts.
        //
        // dayKey must stay inside the scanner's `daysToScan: 30` window,
        // which is relative to the wall clock. A hardcoded date silently
        // fell out of the window once >30 days elapsed and broke this test
        // in CI by calendar date (the entry was filtered → 0 buckets).
        // Anchor it to "now" like the sibling Codex/session tests do:
        // 3 days ago in UTC, comfortably within 30 days regardless of TZ.
        let dayKey: String = {
            let fmt = DateFormatter()
            fmt.calendar = Calendar(identifier: .gregorian)
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyy-MM-dd"
            return fmt.string(from: Date().addingTimeInterval(-3 * 86_400))
        }()
        let fixtureLines = [
            // Opus 4.7 — 100K cache_read + 1K output. At $0.50/M + $25/M
            // that's $0.05 + $0.025 = $0.075. We assert > $0 (the
            // pre-fix bug surfaced as exactly $0 here).
            #"{"type":"assistant","timestamp":"\#(dayKey)T12:00:00.000Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-opus-4-7","usage":{"input_tokens":0,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0,"output_tokens":1000}}}"#,
            // Same msg.id+requestId — must be deduped (token side).
            #"{"type":"assistant","timestamp":"\#(dayKey)T12:00:01.000Z","requestId":"req-1","message":{"id":"msg-1","model":"claude-opus-4-7","usage":{"input_tokens":0,"cache_read_input_tokens":100000,"cache_creation_input_tokens":0,"output_tokens":1000}}}"#,
            // Sonnet 4.6 — sanity check that already-priced models
            // continue to work.
            #"{"type":"assistant","timestamp":"\#(dayKey)T12:00:02.000Z","requestId":"req-2","message":{"id":"msg-2","model":"claude-sonnet-4-6","usage":{"input_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":500}}}"#,
        ]
        let body = (fixtureLines.joined(separator: "\n") + "\n").data(using: .utf8)!

        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cli-pulse-iter1-claude-pricing-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let projectsRoot = tmpDir.appendingPathComponent("projects", isDirectory: true)
        let projectDir = projectsRoot.appendingPathComponent("-Users-stub-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let fileURL = projectDir.appendingPathComponent("synthetic.jsonl")
        try body.write(to: fileURL)

        // Sandbox the Codex sessions root too. `CostUsageScanner.scan()`
        // ALWAYS scans Codex alongside Claude, and without an override it
        // falls back to the real `~/.codex/sessions/`. The Claude-only
        // assertions above stay correct (Claude roots are sandboxed), but
        // `result.totalCost(for:)` below sums cost across ALL providers, so
        // any real Codex usage dated `dayKey` (3 days ago) leaks into the
        // total. That made this test non-hermetic: green in CI (no Codex
        // data) yet failing locally with `0.0885 → 4.15…` whenever the dev
        // had real Codex sessions on that calendar day. An empty dir gives
        // the scanner a real, zero-file Codex root. Mirrors the sibling
        // CostUsageScannerSessionSynthTests setup.
        let codexSessionsRoot = tmpDir.appendingPathComponent("codex-sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: codexSessionsRoot, withIntermediateDirectories: true)

        // Use a separate cache root so we don't touch the user's
        // real CostUsageCache state. Force a fresh scan.
        let cacheRoot = tmpDir.appendingPathComponent("cache", isDirectory: true)
        var opts = CostUsageScanner.Options(
            codexSessionsRoot: codexSessionsRoot,
            claudeProjectsRoots: [projectsRoot],
            cacheRoot: cacheRoot,
            daysToScan: 30
        )
        opts.forceRescan = true
        opts.refreshMinIntervalSeconds = 0

        let result = CostUsageScanner.scan(options: opts)

        // 2. Assert the Opus 4.7 row exists and is non-zero cost.
        let opus47Entries = result.entries.filter {
            $0.provider == "Claude" && $0.model == "claude-opus-4-7"
        }
        XCTAssertEqual(opus47Entries.count, 1, "expected one (day, model) bucket for opus 4.7")
        let opus47 = opus47Entries[0]
        // Dedup must collapse the two opus events into one token bucket.
        XCTAssertEqual(opus47.inputTokens, 0)
        XCTAssertEqual(opus47.cachedTokens, 100_000)
        XCTAssertEqual(opus47.outputTokens, 1_000)
        // Cost: 100,000 * $0.50/M + 1,000 * $25/M = $0.05 + $0.025 = $0.075
        XCTAssertNotNil(opus47.costUSD, "Opus 4.7 cost must NOT be nil — that was the production bug")
        XCTAssertEqual(opus47.costUSD ?? 0, 0.075, accuracy: 0.0001)

        // 3. Sonnet 4.6 row still works (regression guard).
        let sonnetEntries = result.entries.filter {
            $0.provider == "Claude" && $0.model == "claude-sonnet-4-6"
        }
        XCTAssertEqual(sonnetEntries.count, 1)
        let sonnet = sonnetEntries[0]
        // 2,000 * $3/M + 500 * $15/M = $0.006 + $0.0075 = $0.0135
        XCTAssertEqual(sonnet.costUSD ?? 0, 0.0135, accuracy: 0.0001)

        // 4. Top-level Today cost sum is non-zero — what the user's
        // card binds to.
        let todayCost = result.totalCost(for: dayKey)
        XCTAssertGreaterThan(todayCost, 0)
        XCTAssertEqual(todayCost, 0.075 + 0.0135, accuracy: 0.0001)
    }
}
#endif
