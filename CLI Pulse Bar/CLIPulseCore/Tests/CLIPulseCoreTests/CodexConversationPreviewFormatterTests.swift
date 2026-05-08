import XCTest
@testable import CLIPulseCore

final class CodexConversationPreviewFormatterTests: XCTestCase {
    private typealias F = CodexConversationPreviewFormatter

    // MARK: - shouldKeep

    func test_keeps_user_prompt_with_codex_marker() {
        XCTAssertTrue(F.shouldKeep("› hello"))
    }

    func test_keeps_assistant_prose_without_marker() {
        XCTAssertTrue(F.shouldKeep("Sure! I can help you set up that script."))
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

    func test_drops_short_status_fragment() {
        // 7 alnum < threshold of 8; not error keyword; nothing surfaces.
        XCTAssertFalse(F.shouldKeep("running"))
    }

    func test_drops_token_counter_glyph_lines() {
        XCTAssertFalse(F.shouldKeep("↓ 2438 tokens"))
        XCTAssertFalse(F.shouldKeep("↑ 92 tokens"))
    }

    func test_drops_box_drawing_line() {
        XCTAssertFalse(F.shouldKeep("─────────────────────────────────────────────"))
    }

    func test_drops_bare_punctuation_fragment() {
        XCTAssertFalse(F.shouldKeep("·"))
    }

    // MARK: - update wizard chrome

    func test_drops_update_available_banner() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Update available! 0.128.0 -> 0.129.0"))
    }

    func test_drops_release_notes_line() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Release notes: https://github.com/openai/codex/releases/latest"))
    }

    func test_drops_press_enter_to_continue_footer() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("Press enter to continue"))
    }

    func test_drops_numbered_menu_with_codex_selector() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("› 1. Update now (runs `brew upgrade --cask codex`)"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("› 2. Skip"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("› 3. Skip until next version"))
    }

    func test_drops_numbered_menu_without_selector() {
        // After the selector moves, the previously-active row is shown
        // without `›` but is still part of the wizard.
        XCTAssertTrue(F.shouldDropAsHelperChrome("1. Update now (runs `brew upgrade --cask codex`)"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("2. Skip"))
    }

    func test_drops_skip_until_next_version_substring() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("3. Skip until next version"))
    }

    func test_drops_bare_codex_selector() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("›"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("›   "))
    }

    func test_keeps_real_user_prompt_through_chrome_filter() {
        XCTAssertFalse(F.shouldDropAsHelperChrome("› hello"))
        XCTAssertFalse(F.shouldDropAsHelperChrome("› please write a haiku"))
    }

    // MARK: - polish: marker spacing

    func test_polishes_codex_marker_spacing() {
        XCTAssertEqual(F.polishLine("›hello"), "› hello")
    }

    func test_polish_idempotent_when_space_present() {
        XCTAssertEqual(F.polishLine("› hello"), "› hello")
    }

    // MARK: - format() pipeline

    func test_format_returns_fallback_for_empty_input() {
        XCTAssertEqual(F.format(eventPayloads: []), F.emptyFallback)
    }

    func test_format_returns_fallback_for_only_chrome() {
        let preview = F.format(eventPayloads: [
            "Update available! 0.128.0 -> 0.129.0\n",
            "› 1. Update now\n",
            "  2. Skip\n",
            "Press enter to continue\n",
        ])
        XCTAssertEqual(preview, F.emptyFallback)
    }

    func test_format_extracts_user_prompt_through_pipeline() {
        let preview = F.format(eventPayloads: [
            "› hello\n",
            "1. Update now\n",
            "Press enter to continue\n",
        ])
        XCTAssertEqual(preview, "› hello")
    }

    func test_format_keeps_assistant_prose_after_user_prompt() {
        let preview = F.format(eventPayloads: [
            "› hello\n",
            "Sure! I can help with that. What language?\n",
            "Press enter to continue\n",
        ])
        XCTAssertEqual(preview, "› hello\nSure! I can help with that. What language?")
    }

    func test_format_dedupes_consecutive_repaint_lines() {
        // TUI repaints emit the same `› hello` many times.
        let preview = F.format(eventPayloads: [
            "› hello\n› hello\n› hello\n",
        ])
        XCTAssertEqual(preview, "› hello")
    }

    func test_format_strips_orphan_csi_bodies() {
        // Standalone `[38;5;6;49m` body (ESC was stripped on a prior
        // pass) should not pollute the transcript.
        let preview = F.format(eventPayloads: ["[38;5;6;49m"])
        XCTAssertEqual(preview, F.emptyFallback)
    }

    func test_format_empty_payload_returns_fallback() {
        XCTAssertEqual(F.format(eventPayloads: [""]), F.emptyFallback)
    }

    // MARK: - real-fixture regression
    //
    // Synthesized from `/tmp/v1.15-fixtures/codex_hello.bin` — the first
    // 2KB of a real `codex` PTY launch on the dev host. Pre-strip the
    // sequence is mostly cursor-positioning (CUP) + the update wizard.
    // After AnsiSanitizer strips CSI/OSC, what remains is:
    //   `  ✨ Update available!0.128.0 -> 0.129.0`
    //   `Release notes: https://github.com/openai/codex/releases/latest`
    //   `› 1. Update now (runs `brew upgrade --cask codex`)`
    //   `2.Skip`
    //   `3.Skipuntilnextversion`
    //   `Press enter to continue`
    //
    // (The character-positioning chrome smushes "Skip until next version"
    // and "2. Skip" because Codex paints with absolute CUP per word.)
    //
    // For the v1 formatter we accept that the wizard is silenced and
    // the empty fallback shows. When the user later sends `hello`, the
    // `› hello` echo appears and survives.

    func test_format_codex_update_wizard_is_silenced() {
        let wizardEsc = "\u{001B}[1m\u{001B}[38;5;6;49m  ✨\u{001B}[2;5H \u{001B}[39;49mUpdate available!\u{001B}[2;24H\u{001B}[22m\u{001B}[2m\u{001B}[2m0.128.0 -> 0.129.0\u{001B}[4;3HRelease notes: https://github.com/openai/codex/releases/latest\u{001B}[6;1H\u{001B}[24m\u{001B}[22m\u{001B}[38;5;6;49m› 1. Update now (runs `brew upgrade --cask codex`)\u{001B}[7;3H\u{001B}[39;49m2.\u{001B}[7;6HSkip\u{001B}[8;3H3.\u{001B}[8;6HSkip\u{001B}[10;3H\u{001B}[2mPress enter to continue\u{001B}[39m\u{001B}[49m\u{001B}[0m"
        let preview = F.format(eventPayloads: [wizardEsc])
        XCTAssertEqual(preview, F.emptyFallback,
            "wizard chrome should not surface as conversation; " +
            "got:\n\(preview)")
    }
}
