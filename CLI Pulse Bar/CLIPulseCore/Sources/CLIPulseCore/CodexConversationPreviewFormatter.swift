import Foundation

/// Codex-specific conversation preview formatter for the macOS / iOS
/// Sessions panel. Sibling to `ClaudeConversationPreviewFormatter`,
/// added in v1.15 when managed sessions gained Codex CLI support.
///
/// Codex CLI's TUI differs from Claude's in three ways the formatter
/// cares about:
///
///  1. **Prompt marker is `›` (U+203A)**, not `❯` (U+276F). It is also
///     re-used as the highlighted-row selector inside numbered menus
///     (update wizard, choice prompts), so a row starting with `›`
///     followed by a digit + period is chrome, not user input.
///
///  2. **Assistant responses have no leading marker.** Codex prints
///     the model's reply as plain text, optionally indented. There is
///     no equivalent to Claude's `⏺`. Without an anchor we can't
///     reliably separate model output from box-drawing borders, so
///     v1 keeps lines that look "substantive" (8+ alnum chars) when
///     they are not in the chrome blocklist.
///
///  3. **Update wizard fires on every launch** until dismissed. Lines
///     like `Update available!`, `Release notes: …`, `Press enter to
///     continue`, and numbered choices (`1. Update now`, `2. Skip`)
///     are TUI noise, not conversation, and must be dropped.
///
/// Design parity with Claude formatter:
///   * Single concat-then-sanitize pass over `[String]`.
///   * Strip orphan CSI bodies that survived event-boundary splits.
///   * Split on `\n` AND bare `\r` for cursor-only repaints.
///   * Collapse consecutive duplicate lines (TUI repaints).
///
/// Future tightening: this is a v1 against a small fixture set. The
/// `assistantContinuationChromeMarkers` table will grow as we observe
/// real production sessions through the Sessions tab.
public enum CodexConversationPreviewFormatter {
    public static let emptyFallback =
        "Codex is running. Waiting for conversational output…"

    /// Aggregate event payloads in order, sanitize once, extract only
    /// conversation-meaningful lines.
    public static func format(eventPayloads: [String]) -> String {
        guard !eventPayloads.isEmpty else { return emptyFallback }
        let blob = eventPayloads.joined()
        // v1.16 hotfix: cursor-move-laid-out text would otherwise
        // collapse adjacent words (`fooCLIbar`). See AnsiSanitizer
        // .stripJoiningWithSpaces docstring + ClaudeConversation
        // PreviewFormatter parity comment.
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
        if let first = trimmed.first, first == "›" {
            // User-prompt echo. The chrome filter has already stripped
            // numbered-menu rows (`› 1. …`).
            return true
        }
        let lower = trimmed.lowercased()
        let allowSubstrings = [
            "error", "api ", "please run", "warning",
            "unauthorized", "authentication_error",
            "not authenticated", "invalid auth",
            "not signed in", "login required",
        ]
        for s in allowSubstrings where lower.contains(s) {
            return true
        }
        // Without a marker for assistant text, fall back to a length /
        // structure heuristic so plain prose replies survive while
        // box-drawing fragments do not.
        return looksLikeAssistantProse(trimmed)
    }

    /// Codex update wizard + numbered-menu chrome.
    public static func shouldDropAsHelperChrome(_ trimmed: String) -> Bool {
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()

        // Numbered menu rows. With or without the `›` selector arrow,
        // both forms are wizard chrome.
        //   `› 1. Update now (runs `brew upgrade --cask codex`)`
        //   `1. Update now (runs `brew upgrade --cask codex`)`
        //   `2. Skip`
        if isNumberedMenuRow(trimmed) { return true }

        // Bare `›` selector mark or `›` + whitespace only.
        if trimmed == "›" { return true }
        if trimmed.first == "›" {
            let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if body.isEmpty { return true }
        }

        // Update wizard banner / footer.
        for prefix in updateWizardPrefixes where lower.hasPrefix(prefix) {
            return true
        }
        for marker in updateWizardMarkers where lower.contains(marker) {
            return true
        }

        // Spinner / status / box-drawing.
        if looksLikeSpinnerOnly(trimmed) { return true }
        if isBoxDrawingDominant(trimmed) { return true }

        // Bar-bracketed banner content. Codex's welcome banner paints
        // every interior row as `│ <text>          │`. The body is
        // mostly text (so `isBoxDrawingDominant` doesn't fire) but the
        // structural `│ … │` shape is reliably banner chrome, never
        // user-facing prose. Tight match: starts with `│`, ends with
        // `│`, and at least 3 chars long.
        if trimmed.count >= 3 {
            let first = trimmed.first!
            let last = trimmed.last!
            if first == "│" && last == "│" {
                return true
            }
        }

        return false
    }

    /// Codex's update wizard paints with CUP (cursor positioning) and
    /// no newlines — after CSI stripping the whole wizard becomes one
    /// mega-line. Substring-match (not prefix-match) so the line drops
    /// even when wizard fragments appear concatenated.
    private static let updateWizardPrefixes: [String] = []

    private static let updateWizardMarkers: [String] = [
        // Update wizard.
        "release notes:",
        "press enter to continue",
        "update available",
        "press esc to dismiss",
        "skip until next version",
        // Hardening 2026-05-08 — observed in `codex_reply.bin` against
        // codex 0.128.0. CUP-paint smooshes status chrome into the same
        // mega-line as actual conversation; substring drop is the only
        // way to discard the line cleanly without splitting at `›`.
        "esc to interrupt",
        // Codex 0.128.0 actually writes the typo `inerrupt` in one
        // status line (`(0s• esc to inerrupt)`). Match both spellings
        // so the line drops regardless of which build the helper hit.
        "esc to inerrupt",
        "tab to queue message",
        "context left",
        "starting mcp server",
        "booting mcp server",
        "tip: try the codex app",
    ]

    /// Matches `1.`, `2.`, `3.`, optionally preceded by `›` and
    /// whitespace. Also matches `(1)` / `[1]` style if Codex ever
    /// emits them.
    private static let numberedMenuPattern: NSRegularExpression = {
        let pattern = "^›?\\s*(?:\\(\\d+\\)|\\[\\d+\\]|\\d+\\.)\\s+\\S"
        return try! NSRegularExpression(pattern: pattern, options: [])
    }()

    private static func isNumberedMenuRow(_ trimmed: String) -> Bool {
        let r = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return numberedMenuPattern.firstMatch(in: trimmed, options: [], range: r) != nil
    }

    private static let boxDrawingStart: UInt32 = 0x2500
    private static let boxDrawingEnd: UInt32 = 0x257F
    private static let separatorASCII: Set<Character> = ["-", "=", "_"]
    private static let spinnerGlyphs: Set<Character> = [
        "·", "•", "✶", "✸", "*", "/", "◉", "◯", "⠁", "⠂", "⠄", "⡀",
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
            } else if let ch = Character(String(sc)) as Character?,
                      separatorASCII.contains(ch) {
                border += 1
            }
        }
        guard nonSpace > 0 else { return false }
        return Double(border) / Double(nonSpace) >= 0.70
    }

    /// Heuristic for "this line is probably the model's prose reply".
    /// Without a `⏺`-style marker we have to guess. Conservative:
    ///   * 8+ alphanumerics so single glyphs / short status fragments
    ///     don't pass.
    ///   * Doesn't start with a numbered-menu bullet (already screened
    ///     by `shouldDropAsHelperChrome` but defense-in-depth).
    ///   * Doesn't look like a status counter (`↓ 12 tokens`).
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

    /// Conservative spacing repair. Restores space after `›` marker.
    public static func polishLine(_ line: String) -> String {
        insertSpaceAfterMarker(line)
    }

    /// `›hello` → `› hello`.
    private static func insertSpaceAfterMarker(_ s: String) -> String {
        guard let first = s.first, first == "›" else { return s }
        let rest = s.dropFirst()
        guard let next = rest.first, !next.isWhitespace else { return s }
        return "\(first) \(rest)"
    }

    // MARK: - shared helpers (parity with Claude formatter)

    private static let orphanCsiPattern: NSRegularExpression = {
        // v1.16.1 added `[ -/]*` intermediate-byte slot per ECMA-48 so
        // DECSCUSR (`[0 q`) and similar forms are stripped instead of
        // leaking into the rendered transcript.
        let pattern = "\\[[0-9;:?<>=]+[ -/]*[@-~]"
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
