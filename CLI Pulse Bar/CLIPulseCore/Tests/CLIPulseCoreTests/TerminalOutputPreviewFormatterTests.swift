import XCTest
@testable import CLIPulseCore

final class TerminalOutputPreviewFormatterTests: XCTestCase {
    private func keep(_ s: String) -> Bool {
        TerminalOutputPreviewFormatter.shouldKeep(s)
    }

    // MARK: - allow-list

    func test_keeps_user_prompt_echo() {
        XCTAssertTrue(keep("❯ hello"))
    }

    func test_keeps_claude_assistant_marker() {
        XCTAssertTrue(keep("⏺ Hello! Ready when you are."))
    }

    func test_keeps_long_prose_line() {
        XCTAssertTrue(keep("Welcome back Jason — your session is ready."))
    }

    func test_keeps_login_required_error() {
        XCTAssertTrue(keep("Please run /login to authenticate."))
    }

    func test_keeps_api_error_line() {
        XCTAssertTrue(keep("API Error: 401 Unauthorized"))
    }

    func test_keeps_warning_line() {
        XCTAssertTrue(keep("Warning: model fallback engaged"))
    }

    // MARK: - drop heuristics

    func test_drops_empty_line() {
        XCTAssertFalse(keep(""))
    }

    func test_drops_whitespace_only_line() {
        XCTAssertFalse(keep("                "))
    }

    func test_drops_box_drawing_separator() {
        let line = "─────────────────────────────────────────────────────"
        XCTAssertFalse(keep(line))
    }

    func test_drops_dash_separator_run() {
        XCTAssertFalse(keep("--------------------------------------"))
    }

    func test_drops_box_corner_decoration() {
        XCTAssertFalse(keep("╭───────────────────────────────────────╮"))
    }

    func test_drops_status_bar_with_effort() {
        XCTAssertFalse(keep("  ? for shortcuts                         ◉ xhigh · /effort"))
    }

    func test_drops_esc_to_interrupt_marker() {
        XCTAssertFalse(keep("Press esc to interrupt"))
    }

    func test_drops_no_auto_edits_marker() {
        XCTAssertFalse(keep(" no auto-edits"))
    }

    func test_drops_spinner_only_line() {
        XCTAssertFalse(keep("✶"))
        XCTAssertFalse(keep(" · "))
        XCTAssertFalse(keep("◉"))
    }

    // MARK: - boundary cases

    func test_keeps_short_word_under_alnum_threshold() {
        // 5 chars; below 8 alphanumeric threshold but also doesn't
        // match any drop heuristic. Conservative default = keep.
        XCTAssertTrue(keep("hello"))
    }

    func test_keeps_dollar_value_string() {
        // Numbers in shell output should not be filtered as TUI chrome.
        XCTAssertTrue(keep("$2902.50"))
    }

    func test_keeps_path_like_string() {
        // shell/codex provider output may include paths — must not be
        // filtered just because there are slashes.
        XCTAssertTrue(keep("/Users/jason/code/project.swift"))
    }

    // MARK: - end-to-end format()

    func test_jasons_sample_reduces_to_readable_lines() {
        // Simulated session output: ANSI-coloured banner + box borders +
        // status bar + the actual user prompt + Claude's response.
        // After format() we expect just the substantive lines.
        let raw = """
        \u{1B}[?25h\u{1B}[?2004h\u{1B}]0;✳ Claude Code\u{0007}\u{1B}[38;2;215;119;87m╭─────────────────────────╮\u{1B}[39m
        \u{1B}[38;2;215;119;87m│ \u{1B}[1mClaude Code v2.1.126\u{1B}[22m │\u{1B}[39m
        ─────────────────────────────────────────────
          ? for shortcuts                              ◉ xhigh · /effort
        ❯ hello
        ⏺ Hello! Ready when you are — what would you like to work on?
        """

        let preview = TerminalOutputPreviewFormatter.format(raw)
        XCTAssertTrue(preview.contains("❯ hello"),
                      "user prompt echo should survive: \(preview)")
        XCTAssertTrue(preview.contains("⏺ Hello! Ready"),
                      "Claude reply should survive: \(preview)")
        XCTAssertTrue(preview.contains("Claude Code v2.1.126"),
                      "banner version line should survive (substantive prose)")
        XCTAssertFalse(preview.contains("─────"),
                       "long box-drawing run should be dropped: \(preview)")
        XCTAssertFalse(preview.contains("for shortcuts"),
                       "status bar should be dropped: \(preview)")
        XCTAssertFalse(preview.contains("\u{1B}"),
                       "no escape sequences should remain")
    }

    func test_login_error_sample_remains_visible() {
        let raw = """
        \u{1B}[31m✗ Authentication failed\u{1B}[0m
        Please run /login to continue
        ──────────────────────────────────────────
        """
        let preview = TerminalOutputPreviewFormatter.format(raw)
        XCTAssertTrue(preview.contains("Please run /login"),
                      "login error must survive filter: \(preview)")
        XCTAssertTrue(preview.contains("Authentication failed"),
                      "auth error must survive filter: \(preview)")
        XCTAssertFalse(preview.contains("─────"))
    }

    func test_does_not_overfilter_shell_provider_output() {
        // Future shell/Codex provider stdout should pass through. No
        // box art, no spinner glyphs, just plain command output.
        let raw = """
        $ ls
        Package.swift
        Sources
        Tests
        $ swift test
        Test Suite 'All tests' passed
        Executed 0 tests
        """
        let preview = TerminalOutputPreviewFormatter.format(raw)
        for line in ["Package.swift", "Sources", "Tests", "Test Suite 'All tests' passed"] {
            XCTAssertTrue(preview.contains(line),
                          "shell stdout '\(line)' must survive: \(preview)")
        }
    }
}
