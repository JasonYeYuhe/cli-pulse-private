// 1:1 XCTest port of steipete/CodexBar
// Tests/CodexBarTests/ClaudePlanResolverTests.swift
// (swift-testing `@Test`/`#expect` → XCTest). Fixture coverage kept
// identical so future cherry-picks of added cases stay drop-in.
// See ClaudePlan.swift for the MIT attribution of the code under test.

import XCTest
@testable import CLIPulseCore

final class ClaudePlanTests: XCTestCase {

    func test_oauth_rate_limit_tier_maps_to_branded_plan() {
        XCTAssertEqual(ClaudePlan.oauthLoginMethod(rateLimitTier: "default_claude_max_20x"), "Claude Max")
        XCTAssertEqual(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_pro"), "Claude Pro")
        XCTAssertEqual(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_team"), "Claude Team")
        XCTAssertEqual(ClaudePlan.oauthLoginMethod(rateLimitTier: "claude_enterprise"), "Claude Enterprise")
    }

    func test_oauth_subscription_type_overrides_generic_rate_limit_tier() {
        XCTAssertEqual(
            ClaudePlan.oauthLoginMethod(subscriptionType: "pro", rateLimitTier: "default_claude_ai"),
            "Claude Pro")
        XCTAssertEqual(
            ClaudePlan.oauthLoginMethod(subscriptionType: "team", rateLimitTier: "default_claude_max_5x"),
            "Claude Team")
        XCTAssertNil(ClaudePlan.oauthLoginMethod(subscriptionType: nil, rateLimitTier: "default_claude_ai"))
    }

    func test_web_fallback_preserves_stripe_claude_compatibility() {
        XCTAssertEqual(
            ClaudePlan.webLoginMethod(
                rateLimitTier: "default_claude",
                billingType: "stripe_subscription"),
            "Claude Pro")
    }

    func test_compatibility_parser_understands_current_labels() {
        XCTAssertEqual(ClaudePlan.fromCompatibilityLoginMethod("Claude Max"), .max)
        XCTAssertEqual(ClaudePlan.fromCompatibilityLoginMethod("Max"), .max)
        XCTAssertEqual(ClaudePlan.fromCompatibilityLoginMethod("Claude Pro"), .pro)
        XCTAssertEqual(ClaudePlan.fromCompatibilityLoginMethod("Ultra"), .ultra)
        XCTAssertEqual(ClaudePlan.fromCompatibilityLoginMethod("Claude Team"), .team)
        XCTAssertEqual(ClaudePlan.fromCompatibilityLoginMethod("Claude Enterprise"), .enterprise)
    }

    func test_cli_projection_keeps_compact_compatibility_and_unknown_fallback() {
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Claude Max Account"), "Max")
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Team"), "Team")
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Claude Enterprise Account"), "Enterprise")
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Claude Ultra Account"), "Ultra")
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Experimental"), "Experimental")
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Profile"), "Profile")
        XCTAssertEqual(ClaudePlan.cliCompatibilityLoginMethod("Browser profile"), "Browser profile")
    }

    func test_subscription_compatibility_preserves_ultra_and_excludes_enterprise() {
        XCTAssertTrue(ClaudePlan.isSubscriptionLoginMethod("Claude Max"))
        XCTAssertTrue(ClaudePlan.isSubscriptionLoginMethod("Pro"))
        XCTAssertTrue(ClaudePlan.isSubscriptionLoginMethod("Ultra"))
        XCTAssertTrue(ClaudePlan.isSubscriptionLoginMethod("Team"))
        XCTAssertFalse(ClaudePlan.isSubscriptionLoginMethod("Claude Enterprise"))
        XCTAssertFalse(ClaudePlan.isSubscriptionLoginMethod("Profile"))
        XCTAssertFalse(ClaudePlan.isSubscriptionLoginMethod("Browser profile"))
        XCTAssertFalse(ClaudePlan.isSubscriptionLoginMethod("API"))
    }
}
