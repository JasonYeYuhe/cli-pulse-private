import Foundation

/// Strips terminal control sequences (ANSI/VT) from raw PTY output so
/// the macOS / iOS Sessions panel can display readable text instead
/// of `[2D[3B…` gibberish.
///
/// This is **not** a full terminal emulator — Claude Code paints its
/// TUI by interleaving content with cursor moves (CUP / CUB / CUD /
/// SGR / OSC titles / mode-set bracketed-paste). After stripping the
/// escape sequences we are left with the literal characters Claude
/// would have drawn, plus some redundant whitespace / cursor-spacing
/// fragments. That is enough for the user to see "the prompt I typed"
/// and "Claude's response" in the live-output panel until proper
/// terminal-emulation rendering lands in Phase 3.
///
/// Patterns covered:
///   * CSI (Control Sequence Introducer): `ESC [ params final` — covers
///     SGR colors, cursor moves, mode-set sequences, bracketed-paste
///     enable/disable, etc.
///   * OSC (Operating System Command): `ESC ] params BEL` or
///     `ESC ] params ESC \\` — terminal title, cwd hints, etc.
///   * Stand-alone ESC followed by a private-use char.
///   * Bracketed-paste markers `ESC [200~` / `ESC [201~` (handled by CSI).
///   * BEL character (``) which often trails OSC.
///
/// Things it deliberately does NOT do:
///   * No cursor emulation — `\r` / `\b` are passed through, so the
///     visible output may have extra spaces or backspaces. A future
///     pass can collapse `\r…\r` runs.
///   * No charset switching (G0/G1) — Claude doesn't use it.
///   * No DCS or APC sequences — Claude doesn't emit them.
public enum AnsiSanitizer {
    private static let csiPattern: NSRegularExpression = {
        // ESC [ <param bytes 0x30–0x3F>* <intermediate bytes 0x20–0x2F>* <final byte 0x40–0x7E>
        // Using literal hex because `\u{1B}` inside an NSRegularExpression
        // pattern is rejected by some NSRegularExpression variants on
        // macos-13. Build the pattern with the actual ESC character.
        let pattern = "\u{1B}\\[[0-9;?<>=]*[@-~]"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let oscPattern: NSRegularExpression = {
        // ESC ] ... BEL  OR  ESC ] ... ESC \
        let pattern = "\u{1B}\\][^\u{0007}\u{1B}]*(?:\u{0007}|\u{1B}\\\\)"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let strayEscPattern: NSRegularExpression = {
        // ESC followed by a single non-bracket dispatcher (e.g. ESC 7,
        // ESC 8 for save/restore cursor). Greedy enough to consume one
        // control byte without eating actual content.
        let pattern = "\u{1B}[7-9=>NOPVWXZ\\\\]?"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Remove ANSI/VT escape sequences from `raw`. Returns a string
    /// that is safe to render as plain monospace text. Preserves
    /// printable characters, line breaks, tabs, spaces.
    public static func strip(_ raw: String) -> String {
        return stripCore(raw)
    }

    /// Like `strip`, but cursor-move / erase CSI sequences are
    /// replaced with a single inline space instead of being dropped.
    /// SGR (color / style), OSC (title), mode-set, save-cursor, and
    /// stray ESC sequences are still removed entirely — those are
    /// purely cosmetic and dropping them is correct (replacing
    /// `\x1b[34mVar\x1b[0m` with spaces would fracture `myVar` to
    /// `my Var`). Consecutive runs of inline spaces (and tabs)
    /// produced by adjacent cursor-move replacements are then
    /// collapsed to a single space. Newlines, carriage returns, and
    /// the original spaces are preserved.
    ///
    /// Why this exists: Claude TUI lays text out using cursor-move
    /// escapes (CSI A/B/C/D/E/F/G/H/J/K etc.) rather than literal
    /// whitespace. The default `strip` drops those escapes, which
    /// collapses distinct words back-to-back: `Anthropic's official
    /// \x1b[…]CLI…` renders as `Anthropic's officialCLI…`. Replacing
    /// the cursor-move escapes (and only those) with a space recovers
    /// the intended word boundary without a full terminal emulator.
    /// Used by all three conversation preview formatters
    /// (`Claude/Codex/GeminiConversationPreviewFormatter`).
    public static func stripJoiningWithSpaces(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw
        // 1. Replace cursor-move / erase CSIs with a single space FIRST
        //    so word-boundary semantics are preserved.
        let r1 = NSRange(s.startIndex..<s.endIndex, in: s)
        s = cursorMoveCsiPattern.stringByReplacingMatches(
            in: s, options: [], range: r1, withTemplate: " "
        )
        // 2. Run the standard strip pipeline. This deletes everything
        //    else: SGR colors, mode-set, OSC titles, stray ESCs, BELs.
        //    The cursor-move escapes are already gone from step 1, so
        //    the CSI regex inside stripCore matches only what's left.
        s = stripCore(s)
        // 3. Collapse runs of inline spaces (NOT newlines/tabs-as-rows)
        //    that the cursor-move replacement may have introduced.
        return collapseInlineSpaces(s)
    }

    /// CSI sequences whose final byte indicates a position / spatial
    /// effect (cursor moves + erase commands). These are what TUIs use
    /// to lay text out; replacing them with a single space recovers
    /// the visual word boundary they imply.
    ///
    /// Final-byte alphabet derived from the ECMA-48 / VT-x spec subset
    /// Claude / Codex / Gemini TUIs actually use:
    ///   A CUU, B CUD, C CUF, D CUB, E CNL, F CPL, G CHA,
    ///   H CUP, J ED, K EL, L IL, M DL,
    ///   d VPA, e VPR, f HVP
    /// Final bytes that are NOT here (m=SGR, h/l=mode-set, r=scroll
    /// region, s/u=save/restore cursor, n=DSR, c=DA, p, q, t, ~, etc.)
    /// fall through to the standard `strip` pass which deletes them.
    private static let cursorMoveCsiPattern: NSRegularExpression = {
        let pattern = "\u{1B}\\[[0-9;?<>=]*[A-MdefH]"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static let inlineSpaceRunPattern: NSRegularExpression = {
        // Two-or-more spaces / tabs in a row. Newlines and CRs are
        // intentionally NOT in the class — line-break structure must
        // survive the collapse.
        try! NSRegularExpression(pattern: "[ \\t]{2,}", options: [])
    }()

    private static func collapseInlineSpaces(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return inlineSpaceRunPattern.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: " "
        )
    }

    private static func stripCore(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var s = raw

        let full = NSRange(s.startIndex..<s.endIndex, in: s)

        s = csiPattern.stringByReplacingMatches(
            in: s, options: [], range: full, withTemplate: ""
        )
        let full2 = NSRange(s.startIndex..<s.endIndex, in: s)
        s = oscPattern.stringByReplacingMatches(
            in: s, options: [], range: full2, withTemplate: ""
        )
        let full3 = NSRange(s.startIndex..<s.endIndex, in: s)
        s = strayEscPattern.stringByReplacingMatches(
            in: s, options: [], range: full3, withTemplate: ""
        )

        // Drop bare BEL — usually OSC trailer that the regex above
        // already consumed, but Claude emits standalone BELs too.
        s = s.replacingOccurrences(of: "\u{0007}", with: "")

        return s
    }
}
