import Foundation

/// Gemini-specific conversation preview formatter for the macOS / iOS
/// Sessions panel. Sibling to `ClaudeConversationPreviewFormatter`
/// and `CodexConversationPreviewFormatter`, added in v1.15 when
/// managed sessions gained Gemini CLI support.
///
/// Gemini CLI's TUI characteristics (observed in
/// `/tmp/v1.15-fixtures/gemini_banner.bin`):
///
///  1. **No leading prompt marker like `❯` / `›`.** The prompt area
///     uses a `>` input prefix when the user is typing, but the echo
///     line shipped through helper events is plain. Without an anchor
///     for "this is conversation", v1 falls back to a length /
///     structure heuristic plus chrome subtraction.
///
///  2. **First-launch trust prompt is verbose.** A fresh cwd asks
///     "Do you trust the files in this folder?" with three numbered
///     options + multi-line explanatory copy. All wizard chrome.
///
///  3. **Auth-pending banner is a multi-second steady state.** While
///     OAuth is mid-flight, Gemini paints "Waiting for authentication…
///     (Press Esc or Ctrl+C to cancel)" repeatedly. Filter as chrome,
///     not error — it is informational, not actionable.
///
///  4. **`Ready (<basename>)` is the cwd banner**, not a useful prompt.
///     Drop it — the user already knows their cwd from the picker.
///
/// Design parity with Claude / Codex formatters:
///   * Single concat-then-sanitize pass over `[String]`.
///   * Strip orphan CSI bodies surviving event-boundary splits.
///   * Split on `\n` AND bare `\r`.
///   * Collapse consecutive duplicate lines.
///
/// Future tightening: as with the Codex formatter, this is a v1
/// against a small fixture set. Real production traces will surface
/// further chrome lines to add to `wizardMarkers`.
public enum GeminiConversationPreviewFormatter {
    public static let emptyFallback =
        "Gemini is running. Waiting for conversational output…"

    public static func format(eventPayloads: [String]) -> String {
        guard !eventPayloads.isEmpty else { return emptyFallback }
        let blob = eventPayloads.joined()
        // v1.16 hotfix: parity with Claude formatter — preserve word
        // boundaries laid out via cursor-move escapes so multi-word
        // model output doesn't collapse to `fooCLIbar`.
        let sanitized = AnsiSanitizer.stripJoiningWithSpaces(blob)
        let scrubbed = stripOrphanCsiBodies(sanitized)
        let rawLines = scrubbed.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        )
        var kept: [String] = []
        for raw in rawLines {
            let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if shouldDropAsHelperChrome(trimmed) { continue }
            if shouldKeep(trimmed) {
                kept.append(polishLine(trimmed))
            }
        }
        let collapsed = collapseConsecutiveDuplicates(kept)
        if collapsed.isEmpty { return emptyFallback }
        return collapsed.joined(separator: "\n")
    }

    // MARK: - heuristics

    /// True iff the trimmed line should be emitted to the transcript.
    public static func shouldKeep(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return false }
        if let first = trimmed.first, first == ">" {
            // User-prompt echo when Gemini repaints the input box with
            // the typed text; chrome filter has already screened the
            // empty `>` and `> ` placeholder forms.
            return true
        }
        let lower = trimmed.lowercased()
        let allowSubstrings = [
            "error", "api ", "please run", "warning",
            "unauthorized", "authentication_error",
            "not authenticated", "invalid auth",
            "not signed in", "login required", "rate limit",
        ]
        for s in allowSubstrings where lower.contains(s) {
            return true
        }
        return looksLikeAssistantProse(trimmed)
    }

    /// Gemini wizard / banner / cwd-trust / auth-pending chrome.
    public static func shouldDropAsHelperChrome(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()

        // Numbered menu rows from the trust wizard (1. / 2. / 3.).
        if isNumberedMenuRow(trimmed) { return true }

        // Bare `>` input cursor.
        if trimmed == ">" { return true }
        if trimmed.first == ">" {
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return true }
        }

        // Welcome / banner / cwd hint.
        for marker in wizardMarkers where lower.contains(marker) {
            return true
        }

        // Spinner / status / box-drawing.
        if looksLikeSpinnerOnly(trimmed) { return true }
        if isBoxDrawingDominant(trimmed) { return true }

        // Bar-bracketed banner content (parity with Codex). Gemini's
        // welcome banner + auth-pending banner both wrap interior
        // rows in `│ <text> │`. Body is mostly text so the dominance
        // check above won't fire, but the structural shape is
        // reliably chrome.
        if trimmed.count >= 3 {
            let first = trimmed.first!
            let last = trimmed.last!
            if first == "│" && last == "│" {
                return true
            }
        }

        return false
    }

    /// Substrings we treat as Gemini chrome regardless of position
    /// in the line. Matched lower-cased.
    private static let wizardMarkers: [String] = [
        // Auth-pending banner — repeats every few hundred ms while
        // the OAuth flow is open.
        "waiting for authentication",
        "press esc or ctrl+c to cancel",
        // Trust folder wizard (multi-line).
        "do you trust the files in this folder",
        "trusting a folder allows gemini cli",
        "trust folder (",
        "trust parent folder (",
        "don't trust",
        // Cwd banner.
        "ready (",
        // Common gemini-cli footer chrome.
        "press ctrl+c again to exit",
        "press tab to autocomplete",
        "press enter to send",
        // Hardening 2026-05-08 — observed in `gemini_reply.bin`
        // against gemini-cli 0.38.2. Substring drop catches each
        // chrome surface even when CUP-paint glues them together.
        "gemini cli v0.",
        "gemini cli v1.",
        "gemini cli v2.",
        "signed in with google",
        "gemini code assist in google",
        "gemini cli update available",
        "installed via homebrew",
        "? for shortcuts",
        "shift+tab to accept edits",
        "type your message",
        "@path/to/file",
    ]

    /// `1.`, `2.`, `3.`, `(1)`, `[1]`. Matches at line start with
    /// optional leading whitespace.
    private static let numberedMenuPattern: NSRegularExpression = {
        let pattern = "^\\s*(?:\\(\\d+\\)|\\[\\d+\\]|\\d+\\.)\\s+\\S"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func isNumberedMenuRow(_ trimmed: String) -> Bool {
        let r = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return numberedMenuPattern.firstMatch(in: trimmed, options: [], range: r) != nil
    }

    /// Box-drawing range covers `─│╭╮╰╯` etc. Block-element range
    /// (U+2580–259F) covers `▀▄▌▐▖▗▘▙▚▛▜▝▞▟` which gemini uses for
    /// its top/bottom separator strips. Both kinds of lines are
    /// chrome; treat them identically for the dominance heuristic.
    private static let boxDrawingStart: UInt32 = 0x2500
    private static let boxDrawingEnd: UInt32 = 0x257F
    private static let blockElementStart: UInt32 = 0x2580
    private static let blockElementEnd: UInt32 = 0x259F
    private static let separatorASCII: Set<Character> = ["-", "=", "_"]
    private static let spinnerGlyphs: Set<Character> = [
        "·", "•", "✶", "✸", "*", "/", "◉", "◯", "⠁", "⠂", "⠄", "⡀", "✦",
    ]

    private static func looksLikeSpinnerOnly(_ trimmed: String) -> Bool {
        let nonWhitespace = trimmed.filter { !$0.isWhitespace }
        return nonWhitespace.count <= 2
            && !nonWhitespace.isEmpty
            && nonWhitespace.allSatisfy { spinnerGlyphs.contains($0) }
    }

    private static func isBoxDrawingDominant(_ trimmed: String) -> Bool {
        var nonSpace = 0
        var border = 0
        for sc in trimmed.unicodeScalars {
            if sc.properties.isWhitespace { continue }
            nonSpace += 1
            let v = sc.value
            if v >= boxDrawingStart && v <= boxDrawingEnd {
                border += 1
            } else if v >= blockElementStart && v <= blockElementEnd {
                border += 1
            } else if let ch = Character(String(sc)) as Character?,
                      separatorASCII.contains(ch) {
                border += 1
            }
        }
        guard nonSpace > 0 else { return false }
        return Double(border) / Double(nonSpace) >= 0.70
    }

    /// Heuristic for "this line is probably the model's prose reply".
    /// 8+ alphanumerics, not a token-counter glyph row, not a numbered
    /// bullet (already screened above but defense-in-depth).
    private static func looksLikeAssistantProse(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return false }
        if let first = trimmed.first, first == "↓" || first == "↑" {
            return false
        }
        if isNumberedMenuRow(trimmed) { return false }
        let alnum = trimmed.unicodeScalars.reduce(0) { acc, sc in
            acc + (CharacterSet.alphanumerics.contains(sc) ? 1 : 0)
        }
        return alnum >= 8
    }

    // MARK: - polish

    /// Conservative spacing repair. Restores space after `>` marker.
    public static func polishLine(_ line: String) -> String {
        insertSpaceAfterMarker(line)
    }

    private static func insertSpaceAfterMarker(_ s: String) -> String {
        guard let first = s.first, first == ">" else { return s }
        let rest = s.dropFirst()
        guard let next = rest.first, !next.isWhitespace else { return s }
        return "\(first) \(rest)"
    }

    // MARK: - shared helpers (parity with sibling formatters)

    private static let orphanCsiPattern: NSRegularExpression = {
        // Terminator narrowed to `[a-zA-Z]` (was `[@-~]`) + trailing
        // `(?!\])` lookahead in v1.18.1. See ClaudeConversationPreview
        // Formatter for the full rationale; in short, alpha-only term
        // covers every real-world CSI final byte, and the lookahead
        // catches the `[1a]`-style footnote false-positive class.
        let pattern = "\\[[0-9;:?<>=]+[ -/]*[a-zA-Z](?!\\])"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    /// Internal (not private) so the orphan-CSI false-positive
    /// regression tests can target this helper directly without
    /// being confounded by the full `format()` pipeline.
    internal static func stripOrphanCsiBodies(_ s: String) -> String {
        guard !s.isEmpty else { return s }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return orphanCsiPattern.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: ""
        )
    }

    private static func collapseConsecutiveDuplicates(_ lines: [String]) -> [String] {
        var out: [String] = []
        out.reserveCapacity(lines.count)
        for line in lines where line != out.last {
            out.append(line)
        }
        return out
    }
}
