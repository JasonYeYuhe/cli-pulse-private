#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// H-10 (2026-06-07 review): the Rust desktop `pricing.rs` table carried
/// the gpt-5.5 Codex family, but the Swift `codexModels` table stopped at
/// `gpt-5.4-pro`. Codex emitted `model="gpt-5.5"` in the wild, so macOS
/// rendered those sessions at $0.00 (`codexCostUSD` returned nil →
/// dropped via compactMap) while Windows/Linux priced them — a silent
/// cross-runtime under-report on Today/Week/forecast/budget on Mac.
///
/// These tests pin the gpt-5.5 family as priced and equal to its gpt-5.4
/// siblings (OpenAI hasn't published official billing; both tables use
/// gpt-5.4 as the best-known approximation).
final class CodexPricingGpt55Tests: XCTestCase {

    private let input = 1_000_000
    private let cached = 400_000
    private let output = 500_000

    private func codexCost(_ model: String) -> Double? {
        CostUsageScanner.Pricing.codexCostUSD(
            model: model, inputTokens: input,
            cachedInputTokens: cached, outputTokens: output
        )
    }

    func testGpt55_isPricedNonZero_wasTheBug() {
        let cost = codexCost("gpt-5.5")
        XCTAssertNotNil(cost, "gpt-5.5 must NOT return nil — that was the macOS $0 bug")
        XCTAssertGreaterThan(cost ?? 0, 0)
    }

    func testGpt55Family_matchesGpt54Siblings() {
        // Each 5.5 variant mirrors a 5.4 entry's rate card exactly.
        let pairs: [(String, String)] = [
            ("gpt-5.5", "gpt-5.4"),
            ("gpt-5.5-codex", "gpt-5.4"),   // -codex shares the base rate
            ("gpt-5.5-mini", "gpt-5.4-mini"),
            ("gpt-5.5-nano", "gpt-5.4-nano"),
            ("gpt-5.5-pro", "gpt-5.4-pro"),
        ]
        for (newer, sibling) in pairs {
            let a = codexCost(newer)
            let b = codexCost(sibling)
            XCTAssertNotNil(a, "\(newer) must be priced")
            XCTAssertNotNil(b, "\(sibling) must be priced")
            XCTAssertEqual(a ?? -1, b ?? -2, accuracy: 1e-9,
                           "\(newer) must match \(sibling) exactly")
        }
    }

    func testGpt55Pro_cacheReadFallsBackToInputRate() {
        // -pro carries no cache-read rate (nil) → cached input bills at the
        // input rate, same as gpt-5.4-pro. Just assert it's priced & > 0.
        let cost = codexCost("gpt-5.5-pro")
        XCTAssertNotNil(cost)
        XCTAssertGreaterThan(cost ?? 0, 0)
    }
}
#endif
