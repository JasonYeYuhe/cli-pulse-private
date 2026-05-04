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
}
