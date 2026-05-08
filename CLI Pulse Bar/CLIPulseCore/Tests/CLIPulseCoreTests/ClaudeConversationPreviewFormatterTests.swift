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

    // MARK: - placeholder filter / bare marker drop

    func test_drops_claude_input_placeholder_with_quote_space() {
        XCTAssertTrue(F.shouldDropAsHelperChrome("❯ Try \"how does project.pbxproj work?\""))
    }

    func test_drops_claude_input_placeholder_compressed() {
        // TUI compression eats the space between `Try` and `"` so the
        // line reads `❯ Try"create a util/logging.py that…"`. Still a
        // placeholder, must still drop.
        XCTAssertTrue(F.shouldDropAsHelperChrome(#"❯ Try"create a util/logging.py that..."#))
    }

    func test_drops_bare_prompt_marker() {
        // Empty input field repaints emit `❯` alone or `❯` + spaces.
        XCTAssertTrue(F.shouldDropAsHelperChrome("❯"))
        XCTAssertTrue(F.shouldDropAsHelperChrome("❯   "))
    }

    func test_keeps_real_user_prompt() {
        XCTAssertFalse(F.shouldDropAsHelperChrome("❯ hello"))
    }

    // MARK: - polish: marker spacing

    func test_polish_inserts_space_after_assistant_marker() {
        XCTAssertEqual(F.polishLine("⏺Hello"), "⏺ Hello")
    }

    func test_polish_inserts_space_after_user_marker() {
        XCTAssertEqual(F.polishLine("❯hello"), "❯ hello")
    }

    func test_polish_leaves_marker_alone_if_already_spaced() {
        XCTAssertEqual(F.polishLine("⏺ Hello"), "⏺ Hello")
        XCTAssertEqual(F.polishLine("❯ hello"), "❯ hello")
    }

    // MARK: - polish: sentence-ending punctuation

    func test_polish_inserts_space_after_period_before_capital() {
        XCTAssertEqual(F.polishLine("⏺ Ready to help.What"),
                       "⏺ Ready to help. What")
    }

    func test_polish_inserts_space_after_question_before_capital() {
        XCTAssertEqual(F.polishLine("⏺ How are you?What's next"),
                       "⏺ How are you? What's next")
    }

    func test_polish_inserts_space_after_exclaim_before_capital() {
        XCTAssertEqual(F.polishLine("⏺ Hi!What now"),
                       "⏺ Hi! What now")
    }

    func test_polish_does_not_break_decimals() {
        // "v2.1.126" must NOT get `2. 1. 126` — the next char after
        // each dot is a digit, not an uppercase letter.
        XCTAssertEqual(F.polishLine("⏺ Claude Code v2.1.126 ready"),
                       "⏺ Claude Code v2.1.126 ready")
    }

    // MARK: - polish: joined-word replacements (assistant lines only)

    func test_polish_splits_known_joined_words_in_assistant_line() {
        XCTAssertEqual(
            F.polishLine("⏺ wouldyoulike toworkon?"),
            "⏺ would you like to work on?"
        )
    }

    func test_polish_does_not_split_joined_words_in_user_line() {
        // User-typed text is left alone — a user might intentionally
        // omit spaces (e.g. tags, hashtags, deliberate typos).
        XCTAssertEqual(
            F.polishLine("❯ wouldyoulike toworkon?"),
            "❯ wouldyoulike toworkon?"
        )
    }

    func test_polish_two_word_replacements_apply_when_three_word_doesnt_match() {
        // `wouldyou tomorrow` doesn't have the 3-word `wouldyoulike`,
        // so the 2-word `wouldyou` rule fires.
        XCTAssertEqual(
            F.polishLine("⏺ wouldyou be free tomorrow?"),
            "⏺ would you be free tomorrow?"
        )
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

    func test_jasons_polish_sample_matches_expected() {
        // Jason's exact post-formatter preview (pre-polish) reads:
        //   ❯ Try"createautillogging.pythat..."
        //   ❯ hello
        //   ❯
        //   ⏺Hello! Ready to help.What wouldyoulike toworkon?
        //   ❯
        //
        // Construct events that produce this set of lines, then verify
        // the new polish reduces it to exactly:
        //   ❯ hello
        //   ⏺ Hello! Ready to help. What would you like to work on?
        let event1 = "❯ Try\"createautillogging.pythat...\"\n"
        let event2 = "❯ hello\n"
        let event3 = "❯\n"
        let event4 = "⏺Hello! Ready to help.What wouldyoulike toworkon?\n"
        let event5 = "❯\n"
        let preview = F.format(eventPayloads: [event1, event2, event3, event4, event5])
        XCTAssertEqual(
            preview,
            """
            ❯ hello
            ⏺ Hello! Ready to help. What would you like to work on?
            """,
            "preview must match Codex's expected polish: \(preview)"
        )
    }

    func test_jasons_polish_sample_v2_shouldwework_split() {
        // Jason's latest manual retest still showed `shouldwework`
        // joined in the assistant line. The visual line break in the
        // panel is SwiftUI Text width-wrapping, not a formatter
        // newline — so the underlying transcript is one logical line:
        //   `⏺ Hi! Ready when you are — what shouldwework on?`
        // Adding `shouldwework`, `shouldwe`, `wework` to the joined-
        // word list closes the gap.
        let event1 = "❯ hello\n"
        let event2 = "⏺ Hi! Ready when you are — what shouldwework on?\n"
        let preview = F.format(eventPayloads: [event1, event2])
        XCTAssertEqual(
            preview,
            """
            ❯ hello
            ⏺ Hi! Ready when you are — what should we work on?
            """,
            "shouldwework must split into 'should we work': \(preview)"
        )
    }

    func test_polish_splits_shouldwe_alone() {
        // `shouldwe` without trailing `work` falls through to the
        // 2-word rule.
        XCTAssertEqual(
            F.polishLine("⏺ shouldwe try a different angle?"),
            "⏺ should we try a different angle?"
        )
    }

    func test_polish_splits_wework_alone() {
        XCTAssertEqual(
            F.polishLine("⏺ wework on the parser"),
            "⏺ we work on the parser"
        )
    }

    func test_jasons_polish_sample_v3_readytohelp_split() {
        // Jason's latest manual retest — last polish before marking
        // PR #10 ready. The visual `●` Jason sees in the panel is
        // SwiftUI font fallback rendering of `⏺` (U+23FA — used
        // internally by Claude Code and by this formatter), not a
        // different code point in the underlying transcript.
        // Verify the conversation reduces to exactly Codex's expected.
        let event1 = "❯ hello\n"
        let event2 = "⏺ Hello! What would you like to work on?\n"
        let event3 = "❯ how is it going\n"
        let event4 = "⏺ Going well — readytohelp. What's up?\n"
        let preview = F.format(eventPayloads: [event1, event2, event3, event4])
        XCTAssertEqual(
            preview,
            """
            ❯ hello
            ⏺ Hello! What would you like to work on?
            ❯ how is it going
            ⏺ Going well — ready to help. What's up?
            """,
            "readytohelp must split into 'ready to help': \(preview)"
        )
    }

    func test_polish_splits_readyto_alone() {
        // 2-word fallback: `readyto` without trailing `help`.
        XCTAssertEqual(
            F.polishLine("⏺ readyto begin"),
            "⏺ ready to begin"
        )
    }

    func test_polish_splits_tohelp_alone() {
        // 2-word fallback: `tohelp` without leading `ready`.
        XCTAssertEqual(
            F.polishLine("⏺ Available tohelp anytime"),
            "⏺ Available to help anytime"
        )
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

    // MARK: - Multi-turn conversation regression (2026-05-08, iOS user report)

    /// Reported symptom: "first two turns display fine, by the 3rd turn
    /// nothing shows in the live tail." Pin the formatter against a
    /// realistic 3-turn TUI repaint trace where each new turn comes in as
    /// fresh stdout chunks while Claude's TUI repaints earlier turns from
    /// scrollback. All three user prompts and all three assistant replies
    /// must survive the format pipeline.
    func test_three_turn_conversation_keeps_all_messages() {
        // Turn 1: user types "first question", Claude answers. TUI
        // repaints the input line several times as the user types.
        let turn1Echo = "❯ first question\n❯ first question\n❯ first question\n"
        let turn1Reply = "⏺ Answer to first question.\n"
        // Turn 2: TUI keeps showing turn-1 history above as the user types
        // turn-2 input, then renders turn-2's reply. Status chrome lines
        // (Processing, token counters) interleave per repaint.
        let turn2Echo = """
        ❯ first question
        ⏺ Answer to first question.
        ❯ second question
        ❯ second question
        Processing...
        ↓ 142 tokens
        """
        let turn2Reply = """
        ❯ first question
        ⏺ Answer to first question.
        ❯ second question
        ⏺ Answer to second question.
        """
        // Turn 3: same shape — full history above + new typing + reply.
        let turn3Echo = """
        ❯ first question
        ⏺ Answer to first question.
        ❯ second question
        ⏺ Answer to second question.
        ❯ third question
        Processing...
        """
        let turn3Reply = """
        ❯ first question
        ⏺ Answer to first question.
        ❯ second question
        ⏺ Answer to second question.
        ❯ third question
        ⏺ Answer to third question.
        """
        let preview = F.format(eventPayloads: [
            turn1Echo, turn1Reply, turn2Echo, turn2Reply, turn3Echo, turn3Reply
        ])
        XCTAssertTrue(preview.contains("❯ first question"),
                      "turn 1 user input must survive: \(preview)")
        XCTAssertTrue(preview.contains("⏺ Answer to first question."),
                      "turn 1 assistant reply must survive: \(preview)")
        XCTAssertTrue(preview.contains("❯ second question"),
                      "turn 2 user input must survive: \(preview)")
        XCTAssertTrue(preview.contains("⏺ Answer to second question."),
                      "turn 2 assistant reply must survive: \(preview)")
        XCTAssertTrue(preview.contains("❯ third question"),
                      "turn 3 user input must survive: \(preview)")
        XCTAssertTrue(preview.contains("⏺ Answer to third question."),
                      "turn 3 assistant reply must survive: \(preview)")
        XCTAssertFalse(preview.contains("Processing"),
                       "chrome lines must drop across all turns: \(preview)")
    }

    /// Same scenario but Claude's TUI scrolls the oldest turn off the
    /// visible viewport — turn-1 lines stop appearing in later events.
    /// (Real behavior when terminal height < total transcript length.)
    /// We must still see all three turns because each came through the
    /// stream at some earlier point.
    func test_three_turn_conversation_with_viewport_scroll() {
        let turn1 = "❯ q1\n⏺ a1\n"
        // Turn 2: viewport still has both turns visible.
        let turn2 = "❯ q1\n⏺ a1\n❯ q2\n⏺ a2\n"
        // Turn 3: turn-1 has scrolled OFF the viewport, only q2/a2 + q3/a3
        // appear in the latest screen frames. This is the realistic
        // trace once the visible terminal fills up.
        let turn3 = "❯ q2\n⏺ a2\n❯ q3\n⏺ a3\n"
        let preview = F.format(eventPayloads: [turn1, turn2, turn3])
        XCTAssertTrue(preview.contains("❯ q1"),  "turn 1 user lost: \(preview)")
        XCTAssertTrue(preview.contains("⏺ a1"),  "turn 1 reply lost: \(preview)")
        XCTAssertTrue(preview.contains("❯ q2"),  "turn 2 user lost: \(preview)")
        XCTAssertTrue(preview.contains("⏺ a2"),  "turn 2 reply lost: \(preview)")
        XCTAssertTrue(preview.contains("❯ q3"),  "turn 3 user lost: \(preview)")
        XCTAssertTrue(preview.contains("⏺ a3"),  "turn 3 reply lost: \(preview)")
    }

    /// Stress: when the live-tail ring buffer is near-cap and the
    /// formatter sees a chatty TUI burst that contains MOSTLY chrome
    /// events with one substantive `❯`/`⏺` per cycle, the chrome must
    /// not crowd out the conversational lines. Pre-fix would still have
    /// passed this — including it as a defense for future refactors.
    func test_chatty_tui_chrome_does_not_crowd_out_conversation() {
        var payloads: [String] = []
        // 50 chrome-only repaint events.
        for _ in 0..<50 {
            payloads.append("Processing...\n↓ 100 tokens\nrunning sp hook\n")
        }
        // Then a substantive turn at the end.
        payloads.append("❯ late prompt\n⏺ late reply\n")
        let preview = F.format(eventPayloads: payloads)
        XCTAssertTrue(preview.contains("❯ late prompt"))
        XCTAssertTrue(preview.contains("⏺ late reply"))
        XCTAssertFalse(preview.contains("Processing"))
    }
}
