import XCTest
@testable import CLIPulseCore

/// Pins the providers-tab search predicate: empty-query passthrough,
/// case/diacritic-insensitive substring matching, and multi-field OR. Pure.
final class ProviderSearchFilterTests: XCTestCase {

    func testEmptyOrWhitespaceQueryMatchesEverything() {
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Claude", query: ""))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Claude", query: "   "))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Claude", query: "\n\t"))
    }

    func testSubstringAndPrefixMatch() {
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Claude", query: "Cla"))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "OpenRouter", query: "Router"))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "AWS Bedrock", query: "bedrock"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Claude", query: "CLAUDE"))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "GLM", query: "glm"))
    }

    func testDiacriticInsensitive() {
        // a query without accents should still match accented names and vice versa
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Café", query: "cafe"))
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Cafe", query: "café"))
    }

    func testNonMatch() {
        XCTAssertFalse(ProviderSearchFilter.matches(providerName: "Claude", query: "gpt"))
        XCTAssertFalse(ProviderSearchFilter.matches(providerName: "Gemini", query: "zzz"))
    }

    func testMultiFieldMatchesAny() {
        XCTAssertTrue(ProviderSearchFilter.matches(query: "agent", in: ["Antigravity", "Coding Agent"]))
        XCTAssertFalse(ProviderSearchFilter.matches(query: "agent", in: ["Claude", "Codex"]))
        // empty field set + non-empty query → no match
        XCTAssertFalse(ProviderSearchFilter.matches(query: "x", in: []))
    }

    func testQueryIsTrimmedBeforeMatching() {
        XCTAssertTrue(ProviderSearchFilter.matches(providerName: "Cursor", query: "  cursor  "))
    }
}
