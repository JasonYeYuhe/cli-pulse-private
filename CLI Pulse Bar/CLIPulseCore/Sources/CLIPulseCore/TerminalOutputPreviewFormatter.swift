import Foundation

/// v1 pragmatic output preview for managed-Claude sessions. Sits on
/// top of `AnsiSanitizer.strip(...)`: after escape sequences are
/// removed the remaining text still contains TUI chrome — box borders,
/// separator dashes, status-bar lines ("esc to interrupt · /effort"),
/// spinner glyphs, blank repaint padding. Without filtering these the
/// output panel reads as noise.
///
/// This is **not** a terminal emulator. We do not track cursor cells,
/// SGR colours, scrollback regions, or repaint deltas. We just drop
/// lines that look like obvious chrome. Substantive prose — the user's
/// echoed prompt, Claude's response, error messages — passes through
/// unchanged.
///
/// Conservative defaults so future shell/Codex providers (PR-#10
/// scope is Claude only; codex/shell are Phase 2) do not get their
/// stdout shredded:
///   * keep any line with >= 8 alphanumeric characters
///   * keep any line containing "Error", "error:", "API", "Please"
///   * keep lines starting with `❯` (user prompt echo) or `⏺` (Claude
///     assistant response marker)
///
/// Drop heuristics (line is dropped if **any** matches):
///   * empty or whitespace-only after stripping
///   * ≥ 70% of non-whitespace chars are Unicode box-drawing
///     (U+2500..U+257F) or ASCII `-` `=` `_` (separator runs)
///   * contains a known TUI chrome marker (case-insensitive):
///     "esc to interrupt", "/effort", "for shortcuts",
///     "no auto-edits", "shift+tab to cycle"
///   * spinner-only line: ≤ 2 non-whitespace chars and all of them are
///     in the spinner glyph set ("·", "•", "✶", "✸", "*", "◉", "◯", "/")
///
/// Full terminal emulation — proper CUP-driven repaint, scrollback,
/// SGR-coloured output — is Phase 3 work; the local-mode UDS spike
/// already prepared the architecture for a richer client.
public enum TerminalOutputPreviewFormatter {
    private static let boxDrawingStart: UInt32 = 0x2500
    private static let boxDrawingEnd: UInt32   = 0x257F

    private static let separatorASCII: Set<Character> = ["-", "=", "_"]
    private static let spinnerGlyphs: Set<Character> = [
        "·", "•", "✶", "✸", "*", "/", "◉", "◯",
    ]

    private static let chromeMarkersLowercased: [String] = [
        "esc to interrupt",
        "/effort",
        "for shortcuts",
        "no auto-edits",
        "shift+tab to cycle",
    ]

    /// Strip ANSI then apply the chrome filter, returning a single
    /// string with surviving lines joined by '\n'. Trailing newline
    /// preserved if present in input.
    public static func format(_ raw: String) -> String {
        let stripped = AnsiSanitizer.strip(raw)
        return filterLines(stripped)
    }

    /// Apply the chrome filter to already-sanitized text. Exposed for
    /// callers that have run `AnsiSanitizer.strip` separately and for
    /// targeted unit tests.
    public static func filterLines(_ stripped: String) -> String {
        guard !stripped.isEmpty else { return stripped }
        // Splitting on both \n and \r so terminal repaints that use
        // bare CR are line-broken too.
        let lines = stripped.split(
            omittingEmptySubsequences: false,
            whereSeparator: { $0 == "\n" || $0 == "\r" }
        )
        var kept: [String] = []
        kept.reserveCapacity(lines.count)
        for line in lines {
            let s = String(line)
            if shouldKeep(s) {
                kept.append(s)
            }
        }
        return kept.joined(separator: "\n")
    }

    /// True iff the line should survive the chrome filter. Public for
    /// tests; production callers use `format` / `filterLines`.
    ///
    /// Order matters: chrome-marker drops are checked BEFORE the
    /// allow-list, because lines like "Press esc to interrupt" or
    /// "  ? for shortcuts  · /effort" are long enough to look like
    /// substantive prose by alnum count alone.
    public static func shouldKeep(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }

        // 1. TUI chrome markers always drop, even if the line is long.
        let lower = trimmed.lowercased()
        for marker in chromeMarkersLowercased where lower.contains(marker) {
            return false
        }

        // 2. Spinner-only line (≤ 2 non-whitespace chars, all in the
        // spinner glyph set).
        let nonWhitespace = trimmed.filter { !$0.isWhitespace }
        if nonWhitespace.count <= 2,
           !nonWhitespace.isEmpty,
           nonWhitespace.allSatisfy({ spinnerGlyphs.contains($0) }) {
            return false
        }

        // 3. Allow-list overrides the box-drawing-dominance heuristic
        // for prose / errors / known markers — but it's only applied
        // AFTER chrome-marker drops.
        if hasAllowMarker(trimmed) { return true }

        // 4. Box-drawing dominance (separator runs, decorative borders).
        if isBoxDrawingDominant(trimmed) { return false }

        return true
    }

    // MARK: - heuristic helpers

    private static func hasAllowMarker(_ trimmed: String) -> Bool {
        // Claude's user-prompt echo and assistant reply markers.
        if let first = trimmed.first, first == "❯" || first == "⏺" {
            return true
        }
        let lower = trimmed.lowercased()
        // Error / login / API surfaces — never drop these even if a
        // box-art heuristic would otherwise.
        let allowSubstrings = ["error", "api ", "please run", "warning"]
        for s in allowSubstrings where lower.contains(s) {
            return true
        }
        // Long enough to be substantive prose: ≥ 8 alphanumeric chars.
        let alnumCount = trimmed.unicodeScalars.reduce(0) { acc, sc in
            acc + (CharacterSet.alphanumerics.contains(sc) ? 1 : 0)
        }
        return alnumCount >= 8
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
}
