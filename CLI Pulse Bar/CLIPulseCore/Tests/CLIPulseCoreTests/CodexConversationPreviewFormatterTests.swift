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

    // MARK: - v1.17 codex_exec markers

    /// v1.17 helper emits `• <reply>` for agent_message events. Without
    /// the explicit prefix match, short replies (`• OK`, `• 是`, `• 2`)
    /// fall through to `looksLikeAssistantProse` which requires alnum>=8
    /// and silently drops them. v1.17.2 fix: explicit `•` prefix kept.
    func test_keeps_short_agent_bullet_reply() {
        XCTAssertTrue(F.shouldKeep("• OK"))
        XCTAssertTrue(F.shouldKeep("• 2"))
        XCTAssertTrue(F.shouldKeep("• PONG"))
        XCTAssertTrue(F.shouldKeep("• Yes"))
    }

    func test_keeps_short_agent_bullet_reply_cjk() {
        // The original bug that drove v1.17 (CJK on iPhone). A bullet-
        // prefixed Chinese single-line reply must surface even when the
        // alnum count is 0 (CJK chars aren't in CharacterSet.alphanumerics).
        XCTAssertTrue(F.shouldKeep("• 是"))
        XCTAssertTrue(F.shouldKeep("• 你好"))
    }

    func test_keeps_long_agent_bullet_reply() {
        XCTAssertTrue(F.shouldKeep("• Hello! How can I help you with cli pulse today?"))
    }

    func test_drops_bare_bullet_with_only_whitespace() {
        // Empty bullet line (`• ` from helper splitlines on a blank line)
        // should still be dropped — chrome filter or shouldKeep, doesn't
        // matter which. Verify shouldKeep returns false so the contract
        // is explicit.
        XCTAssertFalse(F.shouldKeep("•"))
        XCTAssertFalse(F.shouldKeep("•   "))
    }

    func test_keeps_info_marker_lines() {
        XCTAssertTrue(F.shouldKeep("ℹ usage: 100 in / 5 out"))
        XCTAssertTrue(F.shouldKeep("ℹ codex ran: ls"))
    }

    func test_keeps_error_marker_lines() {
        XCTAssertTrue(F.shouldKeep("✗ codex spawn failed: file not found"))
        XCTAssertTrue(F.shouldKeep("✗ turn timed out"))
    }

    func test_keeps_warning_marker_line() {
        // `⚠` appears in Codex's inline TUI output (rate-limit banners
        // etc.). Even though the v1.17 codex_exec transport doesn't
        // emit it itself, raw warnings can still surface via Codex's
        // own stderr / stdin paths.
        XCTAssertTrue(F.shouldKeep("⚠ rate limit"))
    }

    func test_drops_empty_bodies_across_all_markers() {
        // Empty-body consistency for every marker we recognise.
        XCTAssertFalse(F.shouldKeep("›"))
        XCTAssertFalse(F.shouldKeep("›   "))
        XCTAssertFalse(F.shouldKeep("•"))
        XCTAssertFalse(F.shouldKeep("ℹ"))
        XCTAssertFalse(F.shouldKeep("✗"))
        XCTAssertFalse(F.shouldKeep("⚠"))
    }

    func test_polish_inserts_space_after_bullet() {
        // helper always emits `• <text>` with a space, but defensive:
        // if a stray `•reply` ever leaks through, polishLine should fix it.
        XCTAssertEqual(F.polishLine("•reply"), "• reply")
        XCTAssertEqual(F.polishLine("ℹsomething"), "ℹ something")
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

    // MARK: - real-fixture regression #2 (PR #42 hardening)
    //
    // Synthesized from `/tmp/v1.15-fixtures/codex_reply.bin` — codex
    // 0.128.0 launched in `~/Documents/cli pulse`, pressed `2` to
    // dismiss the update wizard, then sent `hello`. After ANSI / CSI
    // strip the surface includes:
    //   * the welcome banner (lines surrounded by `│ … │`)
    //   * status line: `Booting MCP server: computer-use(0s • esc to interrupt)›tab to queue message100% context left`
    //   * status line: `Tip: Try the Codex App. … Starting MCP servers (1/2): codx_apps (0s• esc to inerrupt)`
    //                  (note codex 0.128.0's `inerrupt` typo)
    //   * status bar: ` gpt-5.5 high · ~/Documents/cli pulse`
    //   * actual user prompt: `›hello`
    //   * actual warning: `⚠ Heads up, you have less than 25% of your weekly limit left. Run /status for a breakdown.`
    //
    // The v1 formatter accepted some of these as "assistant prose"
    // because alnum >= 8. Hardening adds substring drop markers for
    // `esc to interrupt` (and `inerrupt` typo), `tab to queue message`,
    // `context left`, `starting mcp server`, `booting mcp server`,
    // `tip: try the codex app`, AND a `│ ... │` bar-bracketed banner
    // detector. These tests pin the new behaviour.

    func test_drops_box_bracketed_banner_row() {
        // Real codex welcome-banner rows after CSI strip.
        XCTAssertTrue(F.shouldDropAsHelperChrome("│ >_ OpenAI Codex (v0.128.0)                 │"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("│ model:     gpt-5.5 high   /model to change │"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("│ directory: ~/Documents/cli pulse           │"))
        // Empty banner row (just the bars + spaces).
        XCTAssertTrue(F.shouldDropAsHelperChrome("│                                            │"))
    }

    func test_drops_esc_to_interrupt_status() {
        XCTAssertTrue(F.shouldDropAsHelperChrome(
            "Booting MCP server: computer-use(0s • esc to interrupt)"
        ))
    }

    func test_drops_codex_inerrupt_typo() {
        // codex 0.128.0 actual output has a typo: `inerrupt`. Our
        // chrome filter must catch it so the line still drops.
        XCTAssertTrue(F.shouldDropAsHelperChrome(
            "Starting MCP servers (1/2): codx_apps (0s• esc to inerrupt)"
        ))
    }

    func test_drops_tab_to_queue_message_status() {
        XCTAssertTrue(F.shouldDropAsHelperChrome(
            "›tab to queue message100% context left"
        ))
    }

    func test_drops_starting_and_booting_mcp_status() {
        XCTAssertTrue(F.shouldDropAsHelperChrome(
            "Starting MCP servers (1/2): codx_apps"
        ))
        XCTAssertTrue(F.shouldDropAsHelperChrome(
            "Booting MCP server: computer-use"
        ))
    }

    func test_drops_codex_app_tip_chrome() {
        XCTAssertTrue(F.shouldDropAsHelperChrome(
            "Tip: Try the Codex App. Run 'codex app' or visit https://chatgpt.com/codex?app-landing-page=true"
        ))
    }

    func test_format_codex_welcome_banner_is_silenced() {
        // Real lines from codex_reply.bin after CSI strip.
        let banner = """
        ╭────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.128.0)                 │
        │                                            │
        │ model:     gpt-5.5 high   /model to change │
        │ directory: ~/Documents/cli pulse           │
        ╰────────────────────────────────────────────╯
        """
        XCTAssertEqual(F.format(eventPayloads: [banner]), F.emptyFallback)
    }

    func test_format_real_status_megaline_is_silenced() {
        // Real CUP-painted mega-line from codex_reply.bin: includes
        // banner border, MCP boot status, queue hint, context counter.
        // No conversation content. Must drop.
        let mega = "╰─────────────────────────────────────────────────╯•Booting MCP server: computer-use(0s • esc to interrupt)›tab to queue message100% context leftMMMMMMMMM\n"
        XCTAssertEqual(F.format(eventPayloads: [mega]), F.emptyFallback)
    }

    func test_format_real_user_prompt_with_warning_survives() {
        // Real CUP-painted line from codex_reply.bin AFTER user typed
        // hello: contains the weekly-limit warning, the user prompt,
        // and the status bar all glued together. Substantive content
        // (warning + prompt) is what we want the user to see.
        let line = "⚠ Heads up, you have less than 25% of your weekly limit left. Run /status for a breakdown.›hello  gpt-5.5 high · ~/Documents/cli pulse"
        let preview = F.format(eventPayloads: [line])
        // The line is not empty fallback — substantive content
        // surfaces. Exact text intentionally not pinned: codex's
        // CUP-paint mashes the surfaces together and "perfect"
        // splitting is a v2 task. The minimum invariant: the prompt
        // and warning are preserved, even if status-bar text trails.
        XCTAssertNotEqual(preview, F.emptyFallback)
        XCTAssertTrue(preview.contains("hello"),
            "user's prompt 'hello' must survive in transcript; got:\n\(preview)")
        XCTAssertTrue(preview.contains("Heads up") || preview.contains("weekly limit"),
            "warning text must survive; got:\n\(preview)")
    }
}
