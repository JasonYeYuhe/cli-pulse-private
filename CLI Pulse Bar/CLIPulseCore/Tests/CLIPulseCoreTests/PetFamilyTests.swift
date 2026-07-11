// PetFamilyTests — v1.42 Pulse Cat M0.
//
// Locks the axis-1 vendor taxonomy + weight table:
//  • only the three big-vendor families map to named forms; everything else,
//    including model-agnostic tools and unknown providers, is `.other`;
//  • the weight = clamp(defaultCostRate × 1000, $0.5, $30) per Mtok in integer
//    micro-USD, so free/local providers are enfranchised (floor) and the math
//    is div-by-zero-safe and deterministic (Rust-port contract).

import XCTest
@testable import CLIPulseCore

final class PetFamilyTests: XCTestCase {

    // MARK: - Family mapping

    func test_named_family_members() {
        XCTAssertEqual(PetFamily.of(.claude), .anthropic)

        XCTAssertEqual(PetFamily.of(.codex), .openai)
        XCTAssertEqual(PetFamily.of(.openaiAdmin), .openai)
        XCTAssertEqual(PetFamily.of(.azureOpenAI), .openai)

        XCTAssertEqual(PetFamily.of(.gemini), .google)
        XCTAssertEqual(PetFamily.of(.vertexAI), .google)
        XCTAssertEqual(PetFamily.of(.antigravity), .google)
    }

    func test_model_agnostic_tools_and_aggregators_are_other() {
        // Coding tools / IDEs / aggregators reveal no model vendor → .other.
        for kind: ProviderKind in [.cursor, .copilot, .windsurf, .zed, .openRouter,
                                   .bedrock, .kilo, .warp, .amp, .droid, .openCode] {
            XCTAssertEqual(PetFamily.of(kind), .other, "\(kind.rawValue) must be .other")
        }
        // Non-big-3 vendors are also .other in v1 (no dedicated form yet).
        for kind: ProviderKind in [.grok, .deepseek, .mistral, .perplexity, .glm, .kimi] {
            XCTAssertEqual(PetFamily.of(kind), .other, "\(kind.rawValue) must be .other")
        }
    }

    func test_unknown_provider_string_is_other() {
        XCTAssertEqual(PetFamily.of(providerRaw: "Nonexistent Provider"), .other)
        XCTAssertEqual(PetFamily.of(providerRaw: ""), .other)
    }

    func test_raw_string_mapping_matches_kind_mapping() {
        // The string overload must agree with the enum overload for every case.
        for kind in ProviderKind.allCases {
            XCTAssertEqual(PetFamily.of(providerRaw: kind.rawValue), PetFamily.of(kind),
                           "raw/kind mapping diverged for \(kind.rawValue)")
        }
    }

    func test_exactly_seven_named_family_providers() {
        // Guards against a silent membership change: exactly the documented set.
        let anthropic = ProviderKind.allCases.filter { PetFamily.of($0) == .anthropic }
        let openai = ProviderKind.allCases.filter { PetFamily.of($0) == .openai }
        let google = ProviderKind.allCases.filter { PetFamily.of($0) == .google }
        XCTAssertEqual(Set(anthropic), [.claude])
        XCTAssertEqual(Set(openai), [.codex, .openaiAdmin, .azureOpenAI])
        XCTAssertEqual(Set(google), [.gemini, .vertexAI, .antigravity])
    }

    // MARK: - Weight table

    func test_weight_conversion_ktok_to_mtok() {
        // defaultCostRate is USD/Ktok; weight is micro-USD/Mtok = rate × 1000 × 1e6.
        XCTAssertEqual(PetWeightTable.microRatePerMtok(for: .claude), 3_000_000)  // 0.003 → $3/Mtok
        XCTAssertEqual(PetWeightTable.microRatePerMtok(for: .codex), 2_000_000)   // 0.002 → $2
        XCTAssertEqual(PetWeightTable.microRatePerMtok(for: .gemini), 1_000_000)  // 0.001 → $1
        XCTAssertEqual(PetWeightTable.microRatePerMtok(for: .vertexAI), 3_000_000)
    }

    func test_free_local_provider_hits_the_floor_not_zero() {
        // Ollama's rate is 0 → clamps to the $0.5 floor (enfranchised, no div-by-0).
        XCTAssertEqual(PetWeightTable.microRatePerMtok(for: .ollama), 500_000)
        XCTAssertEqual(PetWeightTable.microRatePerMtok(forProviderRaw: "Ollama"), 500_000)
    }

    func test_unknown_provider_string_gets_floor_weight() {
        XCTAssertEqual(PetWeightTable.microRatePerMtok(forProviderRaw: "Nope"), 500_000)
    }

    func test_ceiling_is_currently_slack_for_all_providers() {
        // No v1 provider's rate reaches the $30 ceiling; document that invariant
        // so a future premium rate that would clamp is a conscious change.
        for kind in ProviderKind.allCases {
            XCTAssertLessThanOrEqual(kind.defaultCostRate * 1000.0, PetWeightTable.maxRatePerMtokUSD,
                                     "\(kind.rawValue) rate would hit the weight ceiling")
        }
    }

    func test_weighted_score_is_deterministic_integer() {
        // 1,000,000 tokens on Claude ($3/Mtok) = 1e6 × 3e6 micro = 3e12.
        XCTAssertEqual(PetWeightTable.weightedScore(tokens: 1_000_000, providerRaw: "Claude"), 3_000_000_000_000)
        // Negative tokens clamp to 0.
        XCTAssertEqual(PetWeightTable.weightedScore(tokens: -50, providerRaw: "Claude"), 0)
        // Gemini floor vs Claude: same tokens, lower weight.
        let g = PetWeightTable.weightedScore(tokens: 100_000, providerRaw: "Gemini")
        let c = PetWeightTable.weightedScore(tokens: 100_000, providerRaw: "Claude")
        XCTAssertLessThan(g, c)
    }

    func test_int64_headroom_no_overflow_at_extreme_scale() {
        // 100 billion tokens × $30/Mtok weight stays inside Int64.
        let score = PetWeightTable.weightedScore(tokens: 100_000_000_000, providerRaw: "Claude")
        XCTAssertGreaterThan(score, 0)
        XCTAssertLessThan(score, Int64.max)
    }
}
