import XCTest
@testable import CLIPulseCore

final class ProviderConfigModelTests: XCTestCase {

    // MARK: - TokenFormatter.format

    func testTokenFormatterSmallNumbers() {
        XCTAssertEqual(TokenFormatter.format(0), "0")
        XCTAssertEqual(TokenFormatter.format(1), "1")
        XCTAssertEqual(TokenFormatter.format(999), "999")
    }

    func testTokenFormatterThousandsUnder10K() {
        XCTAssertEqual(TokenFormatter.format(1_000), "1.0K")
        XCTAssertEqual(TokenFormatter.format(1_500), "1.5K")
        XCTAssertEqual(TokenFormatter.format(9_500), "9.5K")
    }

    func testTokenFormatterThousandsAt10KAndAbove() {
        XCTAssertEqual(TokenFormatter.format(10_000), "10K")
        XCTAssertEqual(TokenFormatter.format(12_300), "12K")
        XCTAssertEqual(TokenFormatter.format(999_999), "1000K")
    }

    func testTokenFormatterMillionsUnder10M() {
        XCTAssertEqual(TokenFormatter.format(1_000_000), "1.0M")
        XCTAssertEqual(TokenFormatter.format(8_600_000), "8.6M")
    }

    func testTokenFormatterMillionsAt10MAndAbove() {
        XCTAssertEqual(TokenFormatter.format(10_000_000), "10M")
        XCTAssertEqual(TokenFormatter.format(81_000_000), "81M")
    }

    func testTokenFormatterBillions() {
        XCTAssertEqual(TokenFormatter.format(1_000_000_000), "1.0B")
        XCTAssertEqual(TokenFormatter.format(8_600_000_000), "8.6B")
        XCTAssertEqual(TokenFormatter.format(12_300_000_000), "12.3B")
    }

    // MARK: - SubscriptionUtilization

    func testSubscriptionUtilizationZeroSubscriptionCost() {
        let u = SubscriptionUtilization(provider: "Claude", plan: "Free", apiEquivCost: 5.0, subscriptionCost: 0.0)
        XCTAssertEqual(u.utilizationPercent, 0)
        XCTAssertEqual(u.valueMultiplier, "")
    }

    func testSubscriptionUtilizationBelowOneMultiplier() {
        // apiEquivCost < subscriptionCost → multiplier < 1 → empty string
        let u = SubscriptionUtilization(provider: "Codex", plan: "Plus", apiEquivCost: 5.0, subscriptionCost: 20.0)
        XCTAssertEqual(u.utilizationPercent, 25.0, accuracy: 0.001)
        XCTAssertEqual(u.valueMultiplier, "")
    }

    func testSubscriptionUtilizationAtExactlyOne() {
        // multiplier = 1.0 → "1x"
        let u = SubscriptionUtilization(provider: "Claude", plan: "Pro", apiEquivCost: 20.0, subscriptionCost: 20.0)
        XCTAssertEqual(u.utilizationPercent, 100.0, accuracy: 0.001)
        XCTAssertEqual(u.valueMultiplier, "1x")
    }

    func testSubscriptionUtilizationHighMultiplier() {
        // apiEquivCost = 230, subscriptionCost = 10 → multiplier = 23x
        let u = SubscriptionUtilization(provider: "Gemini", plan: "Pro", apiEquivCost: 230.0, subscriptionCost: 10.0)
        XCTAssertEqual(u.utilizationPercent, 2300.0, accuracy: 0.001)
        XCTAssertEqual(u.valueMultiplier, "23x")
        XCTAssertEqual(u.provider, "Gemini")
        XCTAssertEqual(u.plan, "Pro")
        XCTAssertEqual(u.apiEquivCost, 230.0, accuracy: 0.001)
        XCTAssertEqual(u.subscriptionCost, 10.0, accuracy: 0.001)
    }

    // MARK: - UsageTier.usagePercent

    func testUsageTierNilQuotaReturnsZero() {
        let tier = UsageTier(name: "Flash", usage: 100, quota: nil, remaining: nil, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 0.0, accuracy: 0.001)
    }

    func testUsageTierZeroQuotaReturnsZero() {
        let tier = UsageTier(name: "Pro", usage: 50, quota: 0, remaining: 0, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 0.0, accuracy: 0.001)
    }

    func testUsageTierNormalCase() {
        // quota=200, remaining=150 → used=50 → 50/200 = 0.25
        let tier = UsageTier(name: "Pro", usage: 50, quota: 200, remaining: 150, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 0.25, accuracy: 0.001)
    }

    func testUsageTierCapsAtOne() {
        // remaining=-50 means overage → used=250 > quota=200 → capped at 1.0
        let tier = UsageTier(name: "Session", usage: 250, quota: 200, remaining: -50, resetTime: nil)
        XCTAssertEqual(tier.usagePercent, 1.0, accuracy: 0.001)
    }

    // MARK: - ProviderRegistry

    func testRegistryDescriptorKnownKinds() {
        let codex = ProviderRegistry.descriptor(for: .codex)
        XCTAssertEqual(codex.kind, .codex)
        XCTAssertEqual(codex.displayName, "Codex (OpenAI)")
        XCTAssertTrue(codex.supportsExactCost)
        XCTAssertTrue(codex.supportsCredits)
        XCTAssertTrue(codex.requiresHelperBackend)
        XCTAssertEqual(codex.webDomain, "chatgpt.com")

        let ollama = ProviderRegistry.descriptor(for: .ollama)
        XCTAssertEqual(ollama.kind, .ollama)
        XCTAssertFalse(ollama.supportsQuota)
        XCTAssertFalse(ollama.supportsExactCost)
        XCTAssertEqual(ollama.category, .local)
    }

    func testRegistryAllKindsHaveDescriptors() {
        for kind in ProviderKind.allCases {
            let d = ProviderRegistry.descriptor(for: kind)
            XCTAssertEqual(d.kind, kind, "\(kind.rawValue) should have a registered descriptor")
            XCTAssertFalse(d.displayName.isEmpty, "\(kind.rawValue) should have a display name")
        }
    }

    func testRegistryDescriptorSupportedSourcesNonEmpty() {
        for kind in ProviderKind.allCases {
            let d = ProviderRegistry.descriptor(for: kind)
            XCTAssertFalse(d.supportedSources.isEmpty, "\(kind.rawValue) must support at least one source")
        }
    }
}
