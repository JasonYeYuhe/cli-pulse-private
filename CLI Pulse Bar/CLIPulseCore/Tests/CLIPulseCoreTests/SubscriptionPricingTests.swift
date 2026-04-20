import XCTest
@testable import CLIPulseCore

final class SubscriptionPricingTests: XCTestCase {

    // MARK: - SubscriptionPricing.monthlyCost

    func testKnownClaudePlans() {
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Pro"), 20)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Max 5x"), 100)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Max 20x"), 200)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Team"), 30)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Ultra"), 100)
    }

    func testKnownCodexPlans() {
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Codex", plan: "Plus"), 20)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Codex", plan: "Pro"), 200)
    }

    func testKnownGeminiPlans() {
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Gemini", plan: "Advanced"), 20)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Gemini", plan: "Business"), 30)
    }

    func testKnownCursorPlans() {
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Cursor", plan: "Pro"), 20)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Cursor", plan: "Business"), 40)
    }

    func testKnownCopilotPlans() {
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Copilot", plan: "Individual"), 10)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Copilot", plan: "Business"), 19)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Copilot", plan: "Enterprise"), 39)
    }

    func testEnterpriseCustomPricingReturnsZero() {
        // Enterprise plans have custom/negotiated pricing — stored as 0
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Enterprise"), 0)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Codex", plan: "Enterprise"), 0)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Gemini", plan: "Enterprise"), 0)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Cursor", plan: "Enterprise"), 0)
    }

    func testUnknownProviderReturnsNil() {
        XCTAssertNil(SubscriptionPricing.monthlyCost(provider: "UnknownAI", plan: "Pro"))
        XCTAssertNil(SubscriptionPricing.monthlyCost(provider: "", plan: "Pro"))
    }

    func testUnknownPlanReturnsNil() {
        XCTAssertNil(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Nonexistent"))
        XCTAssertNil(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "Free"))
    }

    func testNilPlanReturnsNil() {
        XCTAssertNil(SubscriptionPricing.monthlyCost(provider: "Claude", plan: nil))
    }

    func testEmptyPlanReturnsNil() {
        XCTAssertNil(SubscriptionPricing.monthlyCost(provider: "Claude", plan: ""))
    }

    func testWhitespacePlanIsTrimmed() {
        // "  Pro  " should match "Pro"
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Claude", plan: "  Pro  "), 20)
    }

    func testCaseInsensitiveMatching() {
        // Provider and plan keys are lowercased for comparison
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "claude", plan: "pro"), 20)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "CLAUDE", plan: "PRO"), 20)
        XCTAssertEqual(SubscriptionPricing.monthlyCost(provider: "Cursor", plan: "pro"), 20)
    }

    func testAllTableCostsAreNonNegative() {
        for (provider, plans) in SubscriptionPricing.table {
            for (plan, cost) in plans {
                XCTAssertGreaterThanOrEqual(cost, 0, "\(provider)/\(plan) should be >= 0")
            }
        }
    }

    func testTableIncludesExpectedProviders() {
        let expected = ["Claude", "Codex", "Gemini", "Cursor", "Copilot",
                        "JetBrains AI", "Warp", "Augment", "OpenRouter", "Ollama",
                        "Kilo", "Kimi", "Kimi K2", "Perplexity", "Amp"]
        for name in expected {
            XCTAssertNotNil(SubscriptionPricing.table[name], "\(name) should be in pricing table")
        }
    }

    // MARK: - ProviderKind.defaultCostRate

    func testDefaultCostRatesAreNonNegative() {
        for kind in ProviderKind.allCases {
            XCTAssertGreaterThanOrEqual(kind.defaultCostRate, 0, "\(kind.rawValue) costRate must be >= 0")
        }
    }

    func testOllamaIsFreeTier() {
        XCTAssertEqual(ProviderKind.ollama.defaultCostRate, 0)
    }

    func testClaudeAndVertexAIHaveHigherRate() {
        XCTAssertEqual(ProviderKind.claude.defaultCostRate, 0.003, accuracy: 0.0001)
        XCTAssertEqual(ProviderKind.vertexAI.defaultCostRate, 0.003, accuracy: 0.0001)
    }

    // MARK: - WebhookEventFilter.isEmpty

    func testDefaultFilterIsEmpty() {
        let filter = WebhookEventFilter()
        XCTAssertTrue(filter.isEmpty)
    }

    func testFilterWithSeveritiesIsNotEmpty() {
        let filter = WebhookEventFilter(severities: ["critical"])
        XCTAssertFalse(filter.isEmpty)
    }

    func testFilterWithTypesIsNotEmpty() {
        let filter = WebhookEventFilter(types: ["quota_low"])
        XCTAssertFalse(filter.isEmpty)
    }

    func testFilterWithProvidersIsNotEmpty() {
        let filter = WebhookEventFilter(providers: ["Claude"])
        XCTAssertFalse(filter.isEmpty)
    }

    func testFilterEquality() {
        let a = WebhookEventFilter(severities: ["warning"], types: [], providers: ["Codex"])
        let b = WebhookEventFilter(severities: ["warning"], types: [], providers: ["Codex"])
        XCTAssertEqual(a, b)
    }
}
