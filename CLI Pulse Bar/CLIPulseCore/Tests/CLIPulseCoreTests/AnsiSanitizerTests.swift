import XCTest
@testable import CLIPulseCore

final class AnsiSanitizerTests: XCTestCase {
    /// CSI SGR colour codes should disappear; the visible characters stay.
    func test_strips_sgr_colour_codes() {
        let input = "\u{1B}[38;2;215;119;87mhello\u{1B}[39m"
        XCTAssertEqual(AnsiSanitizer.strip(input), "hello")
    }

    /// CSI cursor-position sequences (CUF, CUB, CUU, CUD) should disappear.
    func test_strips_cursor_movement() {
        let input = "\u{1B}[2D\u{1B}[3B\u{1B}[1A\u{1B}[5Cstart"
        XCTAssertEqual(AnsiSanitizer.strip(input), "start")
    }

    /// CSI mode set/reset (e.g. bracketed-paste enable `?2004h`) should
    /// disappear. This is the dominant Claude-Code-startup-banner pattern.
    func test_strips_mode_set_sequences() {
        let input = "\u{1B}[?25h\u{1B}[?25l\u{1B}[?2004h\u{1B}[?1004hready"
        XCTAssertEqual(AnsiSanitizer.strip(input), "ready")
    }

    /// OSC sequences with BEL terminator (window title) should disappear.
    func test_strips_osc_with_bel_terminator() {
        let input = "\u{1B}]0;✳ Claude Code\u{0007}content"
        XCTAssertEqual(AnsiSanitizer.strip(input), "content")
    }

    /// OSC sequences with ST (ESC \\) terminator should also disappear.
    func test_strips_osc_with_st_terminator() {
        let input = "\u{1B}]2;title\u{1B}\\afterwards"
        XCTAssertEqual(AnsiSanitizer.strip(input), "afterwards")
    }

    /// Stand-alone ESC dispatchers (DECSC ESC 7, DECRC ESC 8) should
    /// disappear without eating real text.
    func test_strips_stray_esc_dispatchers() {
        let input = "\u{1B}7saved\u{1B}8restored"
        XCTAssertEqual(AnsiSanitizer.strip(input), "savedrestored")
    }

    /// A representative slice of Claude Code's startup banner. After
    /// stripping we expect the human-visible characters (Claude / Code /
    /// version / banner text) to remain even though border-painting
    /// will leave some residual whitespace.
    func test_claude_banner_chunk_becomes_readable() {
        let raw = "\u{1B}7\u{1B}[r\u{1B}8\u{1B}[?25h\u{1B}[?25l\u{1B}[?2004h" +
                  "\u{1B}]0;✳ Claude Code\u{0007}\u{1B}[38;2;215;119;87m" +
                  "Claude Code v2.1.126\u{1B}[39m"
        let cleaned = AnsiSanitizer.strip(raw)
        XCTAssertTrue(cleaned.contains("Claude Code v2.1.126"))
        XCTAssertFalse(cleaned.contains("\u{1B}"))
        XCTAssertFalse(cleaned.contains("[38;"))
    }

    /// Plain text passes through unchanged.
    func test_plain_text_unchanged() {
        let input = "hello world\nline two\tindented"
        XCTAssertEqual(AnsiSanitizer.strip(input), input)
    }

    /// Empty input is a no-op.
    func test_empty_string_pass_through() {
        XCTAssertEqual(AnsiSanitizer.strip(""), "")
    }

    /// The "hello" payload Jason saw in production: `hello` is buried
    /// inside cursor-position paint. After stripping, "hello" must be
    /// visible.
    func test_pasted_hello_in_input_field_becomes_readable() {
        let raw = "\u{1B}[2D\u{1B}[3B\r\u{1B}[2C\u{1B}[3Ahello                       \r"
        let cleaned = AnsiSanitizer.strip(raw)
        XCTAssertTrue(cleaned.contains("hello"))
        XCTAssertFalse(cleaned.contains("\u{1B}"))
    }

    // MARK: - stripJoiningWithSpaces

    /// v1.16: Claude TUI lays text out via cursor-move escapes (`\x1b[3C`,
    /// `\x1b[2A`, etc.) instead of literal whitespace. The default `strip`
    /// drops them and collapses adjacent words. `stripJoiningWithSpaces`
    /// replaces cursor-moves with a single space so the word boundary
    /// survives.
    func test_stripJoiningWithSpaces_recovers_word_boundary_at_cursor_move() {
        let raw = "official\u{1B}[3CCLI"
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "official CLI")
    }

    /// SGR (color / style) sequences must NOT inject spaces — they're
    /// purely cosmetic and inserting space inside `myVar` would fracture
    /// the identifier. (Gemini-flagged regression in v1.16 round 2 review.)
    func test_stripJoiningWithSpaces_sgr_color_does_not_fracture_word() {
        let raw = "my\u{1B}[34mVar\u{1B}[0m"
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "myVar")
    }

    /// OSC titles (`ESC ] ... BEL`) are also cosmetic — drop them
    /// without injecting space.
    func test_stripJoiningWithSpaces_osc_title_does_not_fracture() {
        let raw = "before\u{1B}]0;Window Title\u{0007}after"
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "beforeafter")
    }

    /// Adjacent cursor-moves should collapse to a single space, not
    /// produce visible runs of whitespace.
    func test_stripJoiningWithSpaces_collapses_runs_from_adjacent_moves() {
        let raw = "a\u{1B}[1C\u{1B}[2D\u{1B}[3Bb"
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "a b")
    }

    /// Newlines must survive the collapse — only inline spaces / tabs
    /// get squeezed.
    func test_stripJoiningWithSpaces_preserves_newlines() {
        let raw = "line1\u{1B}[2C\nline2"
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "line1 \nline2")
    }

    /// Erase / clear-line CSIs (K, J) count as spatial — preserve as
    /// space so text on the new line doesn't run into the prior tail.
    func test_stripJoiningWithSpaces_treats_erase_as_spatial() {
        let raw = "before\u{1B}[Kafter"
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "before after")
    }

    /// Plain text round-trips unchanged.
    func test_stripJoiningWithSpaces_plain_text_unchanged() {
        XCTAssertEqual(
            AnsiSanitizer.stripJoiningWithSpaces("hello world\nline 2"),
            "hello world\nline 2"
        )
    }

    /// v1.16.1 regression: DECSCUSR (cursor-style) sequences include an
    /// intermediate SPACE byte (0x20) before the final byte. Pre-fix
    /// regex `[0-9;?<>=]*[@-~]` skipped at the space and never matched,
    /// so `\x1b[0 q` leaked through into Codex iOS transcripts as `[0 q`.
    /// User-reported on 2026-05-09.
    func test_strips_csi_with_intermediate_space_byte_DECSCUSR() {
        // `\x1b[0 q` — Reset cursor style. SPACE is the intermediate byte.
        let raw = "before\u{1B}[0 qafter"
        XCTAssertEqual(AnsiSanitizer.strip(raw), "beforeafter")
        XCTAssertEqual(AnsiSanitizer.stripJoiningWithSpaces(raw), "beforeafter")
    }

    /// Other DECSCUSR variants (block/underline/bar cursors) all use
    /// `[N SP q]` form — none should leak.
    func test_strips_csi_all_DECSCUSR_styles() {
        for n in [0, 1, 2, 3, 4, 5, 6] {
            let raw = "x\u{1B}[\(n) qy"
            XCTAssertEqual(AnsiSanitizer.strip(raw), "xy", "DECSCUSR \(n) should strip cleanly")
        }
    }
}
