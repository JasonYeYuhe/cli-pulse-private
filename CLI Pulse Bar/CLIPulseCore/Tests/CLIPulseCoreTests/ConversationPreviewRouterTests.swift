import XCTest
@testable import CLIPulseCore

final class ConversationPreviewRouterTests: XCTestCase {
    private typealias R = ConversationPreviewRouter

    // MARK: - dispatch

    func test_routes_claude_to_claude_formatter() {
        let preview = R.format(provider: "claude", eventPayloads: ["⏺ Hello\n"])
        XCTAssertEqual(preview, "⏺ Hello")
    }

    func test_routes_codex_to_codex_formatter() {
        let preview = R.format(provider: "codex", eventPayloads: ["› hello\n"])
        XCTAssertEqual(preview, "› hello")
    }

    func test_routes_gemini_to_gemini_formatter() {
        let preview = R.format(provider: "gemini", eventPayloads: ["> hello\n"])
        XCTAssertEqual(preview, "> hello")
    }

    func test_unknown_provider_falls_back_to_claude() {
        // History bias — every pre-v1.15 row is `claude`. An unknown
        // provider on a future schema row should still render, not
        // blank out.
        let preview = R.format(provider: "totally-not-a-cli", eventPayloads: ["⏺ Hello\n"])
        XCTAssertEqual(preview, "⏺ Hello")
    }

    func test_dispatch_is_case_insensitive() {
        XCTAssertEqual(R.format(provider: "Codex", eventPayloads: ["› hi\n"]), "› hi")
        XCTAssertEqual(R.format(provider: "GEMINI", eventPayloads: ["> hi\n"]), "> hi")
    }

    func test_dispatch_trims_whitespace() {
        XCTAssertEqual(R.format(provider: "  codex ", eventPayloads: ["› hi\n"]), "› hi")
    }

    // MARK: - empty fallback

    func test_empty_fallback_per_provider() {
        XCTAssertEqual(
            R.emptyFallback(for: "claude"),
            ClaudeConversationPreviewFormatter.emptyFallback
        )
        XCTAssertEqual(
            R.emptyFallback(for: "codex"),
            CodexConversationPreviewFormatter.emptyFallback
        )
        XCTAssertEqual(
            R.emptyFallback(for: "gemini"),
            GeminiConversationPreviewFormatter.emptyFallback
        )
    }

    func test_empty_fallback_unknown_provider_returns_claude_fallback() {
        XCTAssertEqual(
            R.emptyFallback(for: "futurelm"),
            ClaudeConversationPreviewFormatter.emptyFallback
        )
    }

    // MARK: - header label

    func test_header_label_per_provider() {
        XCTAssertEqual(R.headerLabel(for: "claude"), "Claude conversation preview")
        XCTAssertEqual(R.headerLabel(for: "codex"), "Codex conversation preview")
        XCTAssertEqual(R.headerLabel(for: "gemini"), "Gemini conversation preview")
    }

    func test_header_label_unknown_provider_returns_claude() {
        XCTAssertEqual(R.headerLabel(for: "totally-not-a-cli"), "Claude conversation preview")
    }
}
