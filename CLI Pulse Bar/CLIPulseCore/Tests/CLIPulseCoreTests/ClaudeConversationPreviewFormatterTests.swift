import XCTest
@testable import CLIPulseCore

final class ClaudeConversationPreviewFormatterTests: XCTestCase {
    private typealias F = ClaudeConversationPreviewFormatter

    // MARK: - shouldKeep

    func test_keeps_user_prompt_echo() {
        XCTAssertTrue(F.shouldKeep("❯ hello"))
    }

    func test_keeps_assistant_response_marker() {
        XCTAssertTrue(F.shouldKeep("⏺ Hello! Ready when you are."))
    }

    func test_keeps_login_required_line() {
        XCTAssertTrue(F.shouldKeep("Please run /login to authenticate."))
    }

    func test_keeps_api_error_line() {
        XCTAssertTrue(F.shouldKeep("API Error: 401 Unauthorized"))
    }

    func test_keeps_authentication_error_line() {
        XCTAssertTrue(F.shouldKeep("authentication_error: invalid auth"))
    }

    func test_keeps_warning_line() {
        XCTAssertTrue(F.shouldKeep("Warning: model fallback engaged"))
    }

    // MARK: - drops

    func test_drops_processing_status_line() {
        XCTAssertFalse(F.shouldKeep("Processing..."))
    }

    func test_drops_smooshing_status_line() {
        XCTAssertFalse(F.shouldKeep("Smooshing tokens..."))
    }

    func test_drops_crunched_status_line() {
        XCTAssertFalse(F.shouldKeep("Crunched for 3s · 1.2k tokens"))
    }

    func test_drops_token_counter_line() {
        XCTAssertFalse(F.shouldKeep("↓ 2438 tokens"))
        XCTAssertFalse(F.shouldKeep("↑ 92 tokens"))
    }

    func test_drops_hook_status_line() {
        XCTAssertFalse(F.shouldKeep("running sp hook"))
    }

    func test_drops_status_bar_line() {
        XCTAssertFalse(F.shouldKeep("  ? for shortcuts                              ◉ xhigh · /effort"))
    }

    func test_drops_box_drawing_line() {
        XCTAssertFalse(F.shouldKeep("─────────────────────────────────────────────"))
    }

    func test_drops_bare_punctuation_fragment() {
        XCTAssertFalse(F.shouldKeep("·"))
    }

    func test_drops_orphan_ansi_body_after_scrub() {
        // The format() pipeline scrubs orphan CSI bodies before the
        // shouldKeep check; here we assert that a line consisting
        // solely of an orphan body, after format(), produces nothing.
        let preview = F.format(eventPayloads: ["[38;2;215;119;87m"])
        XCTAssertEqual(preview, F.emptyFallback)
    }

    // MARK: - placeholder filter

    func test_drops_claude_input_placeholder() {
        XCTAssertTrue(F.isPlaceholderEcho("❯ Try \"how does project.pbxproj work?\""))
        XCTAssertFalse(F.isPlaceholderEcho("❯ hello"))
    }

    // MARK: - end-to-end format()

    func test_jasons_sample_extracts_conversation_only() {
        // Mock Claude TUI output across 3 events. Includes the box
        // banner, status bar, an `❯ hello` echo, a `⏺` reply, and
        // chrome lines that must drop. Each event ends with \n —
        // production stdout chunks always carry the line-terminator
        // bytes; helper byte-chunking does not strip them.
        let event1 = "\u{1B}[?2004h\u{1B}]0;✳ Claude Code\u{0007}\u{1B}[38;2;215;119;87m╭───────────╮\u{1B}[39m\n"
            + "\u{1B}[38;2;215;119;87m│ Claude Code v2.1.126 │\u{1B}[39m\n"
            + "─────────────────────────────────────────────\n"
            + "  ? for shortcuts                              ◉ xhigh · /effort\n"
        let event2 = "❯ hello\n⏺ Hello! What would you like to work on?\nProcessing...\n↓ 142 tokens\n"
        let event3 = "running sp hook\nCrunched for 2s\n"
        let preview = F.format(eventPayloads: [event1, event2, event3])
        // Conversation lines survive.
        XCTAssertTrue(preview.contains("❯ hello"),
                      "user echo must survive: \(preview)")
        XCTAssertTrue(preview.contains("⏺ Hello! What would you like to work on?"),
                      "Claude reply must survive: \(preview)")
        // Chrome and status drops.
        XCTAssertFalse(preview.contains("─────"),
                       "separator must drop: \(preview)")
        XCTAssertFalse(preview.contains("for shortcuts"),
                       "status bar must drop: \(preview)")
        XCTAssertFalse(preview.contains("Processing"),
                       "Processing... must drop: \(preview)")
        XCTAssertFalse(preview.contains("tokens"),
                       "token counter must drop: \(preview)")
        XCTAssertFalse(preview.contains("running sp hook"),
                       "hook line must drop: \(preview)")
        XCTAssertFalse(preview.contains("Crunched"),
                       "Crunched line must drop: \(preview)")
        XCTAssertFalse(preview.contains("\u{1B}"),
                       "no escape sequences should remain: \(preview)")
        XCTAssertFalse(preview.contains("[38;"),
                       "no orphan ANSI body should remain: \(preview)")
        XCTAssertFalse(preview.contains("Claude Code v2.1.126"),
                       "banner version drops in conversation-only mode: \(preview)")
    }

    func test_login_error_sample_preserved() {
        // Backend rejected the OAuth token. Important to surface to
        // user so they know to re-login.
        let raw = """
        \u{1B}[31m✗ Authentication failed\u{1B}[0m
        Please run /login to authenticate
        API Error: 401 Unauthorized
        Invalid authentication credentials
        ──────────────────────────────────────────
        Processing...
        """
        let preview = F.format(eventPayloads: [raw])
        XCTAssertTrue(preview.contains("Please run /login"),
                      "login instruction must survive: \(preview)")
        XCTAssertTrue(preview.contains("API Error: 401"),
                      "API error must survive: \(preview)")
        XCTAssertTrue(preview.contains("Invalid authentication credentials"),
                      "auth detail must survive: \(preview)")
        XCTAssertFalse(preview.contains("─────"))
        XCTAssertFalse(preview.contains("Processing"))
    }

    func test_empty_input_returns_fallback() {
        XCTAssertEqual(F.format(eventPayloads: []), F.emptyFallback)
    }

    func test_only_chrome_returns_fallback() {
        let raw = """
        ╭─────╮
        │ Claude Code v2.1.126 │
        ──────────
        Processing...
        ↓ 100 tokens
        """
        XCTAssertEqual(F.format(eventPayloads: [raw]), F.emptyFallback)
    }

    func test_collapses_repeated_user_input_repaints() {
        // Claude TUI repaints the input field as the user types each
        // character — the same `❯ hello` may appear many times. We
        // collapse consecutive duplicates so the transcript reads once.
        let raw = """
        ❯ hello
        ❯ hello
        ❯ hello
        ⏺ Hello!
        """
        let preview = F.format(eventPayloads: [raw])
        // exactly one occurrence of `❯ hello` in the preview.
        let occurrences = preview.components(separatedBy: "❯ hello").count - 1
        XCTAssertEqual(occurrences, 1, "expected dedup of repaint runs: \(preview)")
        XCTAssertTrue(preview.contains("⏺ Hello!"))
    }

    func test_aggregates_csi_split_across_events() {
        // `\u{1B}[31m` (red SGR) split across two events. Per-event
        // strip would leave "[31m" in the output. Aggregating first
        // catches the full sequence.
        let event1 = "Hello \u{1B}"
        let event2 = "[31mError: bad input\u{1B}[0m"
        let preview = F.format(eventPayloads: [event1, event2])
        XCTAssertTrue(preview.contains("Error: bad input"))
        XCTAssertFalse(preview.contains("[31"),
                       "CSI body split across events must be removed: \(preview)")
    }
}
