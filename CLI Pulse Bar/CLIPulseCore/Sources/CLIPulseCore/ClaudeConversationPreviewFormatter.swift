import Foundation

/// Narrow Claude-specific conversation preview for the macOS / iOS
/// Sessions panel. Replaces the earlier generic
/// `TerminalOutputPreviewFormatter` for managed-Claude sessions
/// because the generic chrome filter still leaked TUI noise:
///   * "Processing... / Smooshing... / Crunched for 3s"
///   * "↓ tokens / ↑ tokens" status counters
///   * Bare `[38;2;…m` ANSI fragments that escape the per-event
///     sanitizer when sequences split across event boundaries.
///   * "What would you like toworkon?" — words run together because
///     Claude's TUI repaints with cursor moves between events.
///
/// Strategy: extract ONLY conversation-meaningful lines, drop the
/// rest. Provider-scoped to `claude` since PR #10 managed sessions
/// only support that provider.
///
/// Crucially, this formatter takes the **list** of event payloads
/// rather than running per-event. Claude's TUI scatters output across
/// stdout chunks: a CSI sequence may straddle two events, a multi-line
/// response may split mid-sentence. Concatenating before sanitizing
/// catches both. The downside — words running together when cursor
/// moves are removed between text fragments — is accepted for v1;
/// full terminal emulation is Phase 3 / local-mode work.
///
/// Lines that survive:
///   * Start with `❯ ` AND don't look like Claude's placeholder hint
///     (`❯ Try "..."`).
///   * Start with `⏺ ` (Claude assistant response marker).
///   * Look like an error / login surface (case-insensitive substring
///     match against `Error`, `API`, `Please run`, `Warning`,
///     `Unauthorized`, `authentication_error`, `not authenticated`,
///     `invalid auth`).
///
/// Everything else drops, including:
///   * box-drawing borders (U+2500..U+257F)
///   * separator runs (──── / ----)
///   * "Processing..." / "Smooshing..." / "Crunched for…" / "Brewed…"
///   * "↓ N tokens" / "↑ N tokens" / "running sp hook"
///   * status bar: "esc to interrupt", "/effort", "for shortcuts"
///   * spinner glyphs
///   * isolated punctuation / glyph fragments
///   * orphan ANSI body fragments like "[38;2;215;119;87m"
public enum ClaudeConversationPreviewFormatter {
    public static let emptyFallback =
        "Claude is running. Waiting for conversational output…"

    /// Aggregate event payloads in order, sanitize once, extract only
    /// conversation-meaningful lines. Returns a transcript string
    /// suitable for a monospaced text view, or `emptyFallback` if no
    /// conversation lines surfaced yet.
    public static func format(eventPayloads: [String]) -> String {
        guard !eventPayloads.isEmpty else { return emptyFallback }
        // Concatenate WITHOUT a separator: text spanning event
        // boundaries reads naturally and CSI sequences split across
        // events get re-assembled for the sanitizer to match.
        let blob = eventPayloads.joined()
        let sanitized = AnsiSanitizer.strip(blob)
        // Strip orphan ANSI body fragments (e.g. "[38;2;215;119;87m")
        // that survive when the leading ESC was stripped on a prior
        // pass or never present. Standalone bracket-prefixed sequences
        // like `[38;2;…m` or `[?2004h` are noise; remove them.
        let scrubbed = stripOrphanCsiBodies(sanitized)
        // Split on \n AND bare \r so cursor-only repaints break lines.
        let rawLines = scrubbed.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        )
        var kept: [String] = []
        var inAssistantBlock = false
        for raw in rawLines {
            let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if shouldDropAsHelperChrome(trimmed) {
                if trimmed.first == "❯" {
                    inAssistantBlock = false
                }
                continue
            }
            if shouldKeep(trimmed) {
                kept.append(polishLine(trimmed))
                inAssistantBlock = trimmed.first == "⏺"
                continue
            }
            if inAssistantBlock, shouldKeepAssistantContinuation(trimmed) {
                kept.append(polishAssistantContinuation(trimmed))
            }
        }
        // Deduplicate runs of identical lines (TUI repaints emit the
        // same `❯ hello` many times as the user types each char).
        let collapsed = collapseConsecutiveDuplicates(kept)
        if collapsed.isEmpty { return emptyFallback }
        return collapsed.joined(separator: "\n")
    }

    // MARK: - heuristics

    /// True iff the trimmed line should be emitted to the transcript.
    /// Public for tests; production callers use `format`.
    public static func shouldKeep(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return false }
        if let first = trimmed.first {
            if first == "❯" { return true }
            if first == "⏺" { return true }
        }
        let lower = trimmed.lowercased()
        let allowSubstrings = [
            "error", "api ", "please run", "warning",
            "unauthorized", "authentication_error",
            "not authenticated", "invalid auth",
        ]
        for s in allowSubstrings where lower.contains(s) {
            return true
        }
        return false
    }

    /// Claude's empty input field shows a faded placeholder like
    /// `❯ Try "how does project.pbxproj work?"`. We drop those — they
    /// are not the user's actual input. Also drops bare `❯` markers
    /// (empty input field repaint) and TUI-compressed forms like
    /// `❯ Try"create a util/logging.py that…"` where the space
    /// between `Try` and `"` was eaten by cursor repaint.
    public static func shouldDropAsHelperChrome(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, first == "❯" else { return false }
        let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        if body.isEmpty { return true }
        // Claude's input-field placeholder always starts with `Try`
        // (with or without a trailing space, with or without a quote
        // separator after TUI compression).
        let lower = body.lowercased()
        if lower.hasPrefix("try") {
            // Be lenient: `Try ` (with space), `Try"…"` (no space),
            // `Try'…'`, and `Try…` (compressed) all count as
            // placeholder. But "Try" alone — extremely short — is too
            // ambiguous to drop confidently; require at least one
            // following character so a real user prompt of just
            // `❯ Try` survives (rare but possible).
            return body.count > 3
        }
        return false
    }

    /// Backward-compatible alias retained for tests written against
    /// the earlier API. Production callers use `shouldDropAsHelperChrome`.
    public static func isPlaceholderEcho(_ trimmed: String) -> Bool {
        shouldDropAsHelperChrome(trimmed)
    }

    /// Claude frequently wraps assistant prose and paths onto physical
    /// terminal rows that no longer carry the leading `⏺` marker. Keep
    /// those continuation rows only while we are inside an assistant
    /// block, and only when the row still looks substantive rather than
    /// TUI status chrome.
    private static func shouldKeepAssistantContinuation(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return false }
        if let first = trimmed.first, first == "❯" || first == "⏺" {
            return false
        }

        let lower = trimmed.lowercased()
        for prefix in assistantContinuationChromePrefixes where lower.hasPrefix(prefix) {
            return false
        }
        for marker in assistantContinuationChromeMarkers where lower.contains(marker) {
            return false
        }
        if looksLikeTokenCounter(trimmed) { return false }
        if looksLikeSpinnerOnly(trimmed) { return false }
        if isBoxDrawingDominant(trimmed) { return false }

        let alnumCount = trimmed.unicodeScalars.reduce(0) { acc, sc in
            acc + (CharacterSet.alphanumerics.contains(sc) ? 1 : 0)
        }
        return alnumCount >= 8
    }

    private static let assistantContinuationChromePrefixes: [String] = [
        "processing",
        "smooshing",
        "crunched for",
        "brewed",
    ]

    private static let assistantContinuationChromeMarkers: [String] = [
        // 2026-05-08 production trace fix: Claude TUI emits both
        //   `running stop hook` AND `running sp hook` depending on the
        // hook category. Older marker list only had the `sp` variant,
        // so the `stop hook` chrome flooded the assistant continuation
        // path on real sessions. Both forms are now caught.
        "running stop hook",
        "running sp hook",
        "running sub hook",
        "running pre hook",
        "running post hook",
        // Crunched/Brewed/etc. status timers without the spinner
        // sometimes inline with the rest of a misting line.
        "crunched for",
        "brewed for",
        "baked for",
        "churned for",
        "esc to interrupt",
        "/effort",
        "for shortcuts",
        "no auto-edits",
        "shift+tab to cycle",
        // Inline token counters with downward / upward arrow when
        // they appear MID-LINE (not as a leading char). Example:
        //   "✻ Misting… (running stop hook · 2s · ↓ 13 tokens)"
        // looksLikeTokenCounter() requires `↓`/`↑` first char, so
        // these slip through. Match the suffix instead.
        "↓ ",
        "↑ ",
    ]

    private static let boxDrawingStart: UInt32 = 0x2500
    private static let boxDrawingEnd: UInt32 = 0x257F
    private static let separatorASCII: Set<Character> = ["-", "=", "_"]
    private static let spinnerGlyphs: Set<Character> = [
        "·", "•", "✶", "✸", "*", "/", "◉", "◯",
    ]

    private static func looksLikeTokenCounter(_ trimmed: String) -> Bool {
        let lower = trimmed.lowercased()
        return (trimmed.first == "↓" || trimmed.first == "↑")
            && lower.contains("token")
    }

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
            } else if let ch = Character(String(sc)) as Character?,
                      separatorASCII.contains(ch) {
                border += 1
            }
        }
        guard nonSpace > 0 else { return false }
        return Double(border) / Double(nonSpace) >= 0.70
    }

    // MARK: - polish

    /// Conservative spacing repair on a single kept line. Restores
    /// space after the `⏺` / `❯` markers, after sentence-ending
    /// punctuation when followed by an uppercase letter, and a small
    /// hard-coded list of TUI-joined word pairs (only applied to
    /// assistant `⏺` lines so user prompts and error text keep the
    /// caller's literal characters).
    public static func polishLine(_ line: String) -> String {
        var s = line
        s = insertSpaceAfterMarker(s)
        s = insertSpaceAfterSentencePunctuation(s)
        if s.first == "⏺" {
            s = applyJoinedWordReplacements(s)
        }
        return s
    }

    private static func polishAssistantContinuation(_ line: String) -> String {
        var s = line
        s = insertSpaceAfterSentencePunctuation(s)
        s = applyJoinedWordReplacements(s)
        return s
    }

    /// `⏺Hello` → `⏺ Hello`, `❯hello` → `❯ hello`.
    private static func insertSpaceAfterMarker(_ s: String) -> String {
        guard let first = s.first, first == "⏺" || first == "❯" else { return s }
        let rest = s.dropFirst()
        guard let next = rest.first, !next.isWhitespace else { return s }
        return "\(first) \(rest)"
    }

    /// `.What` → `. What`, `?What` → `? What`, `!What` → `! What`.
    /// Only triggers when the punctuation is immediately followed by
    /// an uppercase ASCII letter (heuristic for sentence boundary).
    private static let sentencePunctPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: "([\\.!?])([A-Z])", options: [])
    }()

    private static func insertSpaceAfterSentencePunctuation(_ s: String) -> String {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return sentencePunctPattern.stringByReplacingMatches(
            in: s, options: [], range: range, withTemplate: "$1 $2"
        )
    }

    /// Specific TUI-joined word patterns we have observed in Claude
    /// responses. Applied longest-first so the 3-word merges resolve
    /// before the 2-word ones. Conservative list — broad dictionary-
    /// based splitting is explicitly out of scope.
    private static let joinedWordReplacements: [(String, String)] = [
        // 3-word merges first (longest-first ordering)
        ("wouldyoulike", "would you like"),
        ("shouldwework", "should we work"),
        ("readytohelp",  "ready to help"),
        ("toworkon",     "to work on"),
        // 2-word merges
        ("wouldyou", "would you"),
        ("youlike",  "you like"),
        ("liketo",   "like to"),
        ("workon",   "work on"),
        ("shouldwe", "should we"),
        ("wework",   "we work"),
        ("readyto",  "ready to"),
        ("tohelp",   "to help"),
    ]

    private static func applyJoinedWordReplacements(_ s: String) -> String {
        var out = s
        for (joined, split) in joinedWordReplacements {
            out = out.replacingOccurrences(of: joined, with: split)
        }
        return out
    }

    /// Removes orphan CSI bodies — `[<params>...<final>` sequences
    /// that survive when the leading ESC is stripped or split across
    /// an event boundary. Matches the same final-byte alphabet as
    /// `AnsiSanitizer`'s CSI regex but without the ESC anchor.
    /// Conservative: only strips if the body looks like a pure ANSI
    /// sequence (params are digits / `;:?<>=` only and final byte is
    /// in `@-~`). User text containing `[42]` survives.
    private static let orphanCsiPattern: NSRegularExpression = {
        // Numeric / semicolon body, then a single final byte. Greedy
        // body so longer sequences match instead of leaving fragments.
        let pattern = "\\[[0-9;:?<>=]+[@-~]"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func stripOrphanCsiBodies(_ s: String) -> String {
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
