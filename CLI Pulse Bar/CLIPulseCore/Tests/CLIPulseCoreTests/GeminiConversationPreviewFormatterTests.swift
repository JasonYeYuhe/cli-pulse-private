import XCTest
@testable import CLIPulseCore

final class GeminiConversationPreviewFormatterTests: XCTestCase {
    private typealias F = GeminiConversationPreviewFormatter

    // MARK: - shouldKeep

    func test_keeps_user_prompt_with_gt_marker() {
        XCTAssertTrue(F.shouldKeep("> hello"))
    }

    func test_keeps_assistant_prose_without_marker() {
        XCTAssertTrue(F.shouldKeep("Hello! How can I help you today?"))
    }

    func test_keeps_login_required_line() {
        XCTAssertTrue(F.shouldKeep("Please run /login to authenticate."))
    }

    func test_keeps_api_error_line() {
        XCTAssertTrue(F.shouldKeep("API Error: 429 Rate Limit"))
    }

    func test_keeps_authentication_error_line() {
        XCTAssertTrue(F.shouldKeep("authentication_error: invalid auth"))
    }

    func test_keeps_warning_line() {
        XCTAssertTrue(F.shouldKeep("Warning: model fallback engaged"))
    }

    func test_keeps_rate_limit_notice() {
        XCTAssertTrue(F.shouldKeep("You have hit your daily rate limit for this account."))
    }

    // MARK: - drops

    func test_drops_short_status_fragment() {
        XCTAssertFalse(F.shouldKeep("loading"))
    }

    func test_drops_token_counter_glyph_lines() {
        XCTAssertFalse(F.shouldKeep("↓ 2438 tokens"))
        XCTAssertFalse(F.shouldKeep("↑ 92 tokens"))
    }

    func test_drops_box_drawing_line() {
        XCTAssertFalse(F.shouldKeep("─────────────────────────────────────────────"))
    }

    // MARK: - chrome surfaces (real fixtures)

    func test_drops_ready_cwd_banner() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Ready (v1.15-fixtures)"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("Ready (cli-pulse)"))
    }

    func test_drops_waiting_for_auth_banner() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Waiting for authentication... (Press Esc or Ctrl+C to cancel)"))
    }

    func test_drops_trust_folder_wizard_question() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Do you trust the files in this folder?"))
    }

    func test_drops_trust_folder_explanation() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Trusting a folder allows Gemini CLI to load its local configurations, including custom commands, hooks, MCP"))
    }

    func test_drops_trust_folder_numbered_choices() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("1. Trust folder (v1.15-fixtures)"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("2. Trust parent folder (tmp)"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("3. Don't trust"))
    }

    func test_drops_bare_input_marker() {
        XCTAssertTrue(F.shouldDropAsHelperChrome(">"))
        XCTAssertTrue(F.shouldDropAsHelperChrome(">   "))
    }

    func test_keeps_real_user_prompt_through_chrome_filter() {
        XCTAssertFalse(F.shouldDropAsHelperChrome("> hello"))
        XCTAssertFalse(F.shouldDropAsHelperChrome("> please write a haiku"))
    }

    // MARK: - polish: marker spacing

    func test_polishes_gt_marker_spacing() {
        XCTAssertEqual(F.polishLine(">hello"), "> hello")
    }

    func test_polish_idempotent_when_space_present() {
        XCTAssertEqual(F.polishLine("> hello"), "> hello")
    }

    // MARK: - format() pipeline

    func test_format_returns_fallback_for_empty_input() {
        XCTAssertEqual(F.format(eventPayloads: []), F.emptyFallback)
    }

    func test_format_returns_fallback_for_only_chrome() {
        let preview = F.format(eventPayloads: [
            "Ready (v1.15-fixtures)\n",
            "Waiting for authentication... (Press Esc or Ctrl+C to cancel)\n",
            "Do you trust the files in this folder?\n",
            "1. Trust folder (v1.15-fixtures)\n",
            "2. Trust parent folder (tmp)\n",
            "3. Don't trust\n",
        ])
        XCTAssertEqual(preview, F.emptyFallback)
    }

    func test_format_extracts_user_prompt() {
        let preview = F.format(eventPayloads: [
            "Ready (cli-pulse)\n",
            "> hello\n",
        ])
        XCTAssertEqual(preview, "> hello")
    }

    func test_format_keeps_assistant_prose_after_user_prompt() {
        let preview = F.format(eventPayloads: [
            "Ready (cli-pulse)\n",
            "> hello\n",
            "Hello! How can I help you today?\n",
        ])
        XCTAssertEqual(preview, "> hello\nHello! How can I help you today?")
    }

    func test_format_dedupes_consecutive_repaint_lines() {
        let preview = F.format(eventPayloads: [
            "> hello\n> hello\n> hello\n",
        ])
        XCTAssertEqual(preview, "> hello")
    }

    func test_format_strips_orphan_csi_bodies() {
        let preview = F.format(eventPayloads: ["[38;5;229m"])
        XCTAssertEqual(preview, F.emptyFallback)
    }

    func test_format_empty_payload_returns_fallback() {
        XCTAssertEqual(F.format(eventPayloads: [""]), F.emptyFallback)
    }

    // MARK: - real-fixture regression
    //
    // Synthesized from `/tmp/v1.15-fixtures/gemini_banner.bin` — an
    // actual gemini PTY launch on the dev host. After AnsiSanitizer
    // strips CSI/OSC, what remains is roughly:
    //   `Ready (v1.15-fixtures)`
    //   `Waiting for authentication... (Press Esc or Ctrl+C to cancel)`
    //   `Do you trust the files in this folder?`
    //   `Trusting a folder allows Gemini CLI to load its local configurations, ...`
    //   `1. Trust folder (v1.15-fixtures)`
    //   `2. Trust parent folder (tmp)`
    //   `3. Don't trust`
    //
    // None should surface — fallback is what the user gets until the
    // user dismisses the trust wizard inside the macOS Gemini CLI.

    func test_format_gemini_first_launch_chrome_is_silenced() {
        let raw = """
        \u{001B}[38;5;244mReady (v1.15-fixtures)\u{001B}[39m
        \u{001B}[38;5;244mWaiting for authentication... (Press Esc or Ctrl+C to cancel)\u{001B}[39m
        \u{001B}[38;5;231mDo you trust the files in this folder?\u{001B}[39m
        \u{001B}[38;5;231mTrusting a folder allows Gemini CLI to load its local configurations.\u{001B}[39m
        \u{001B}[38;5;194m1. Trust folder (v1.15-fixtures)\u{001B}[39m
        \u{001B}[38;5;231m2. Trust parent folder (tmp)\u{001B}[39m
        \u{001B}[38;5;231m3. Don't trust\u{001B}[39m
        """
        let preview = F.format(eventPayloads: [raw])
        XCTAssertEqual(preview, F.emptyFallback,
            "first-launch chrome should not surface as conversation; " +
            "got:\n\(preview)")
    }
}
