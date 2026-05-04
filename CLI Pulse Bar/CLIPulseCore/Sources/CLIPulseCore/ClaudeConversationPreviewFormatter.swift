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
        for raw in rawLines {
            let trimmed = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isPlaceholderEcho(trimmed) { continue }
            if shouldKeep(trimmed) {
                kept.append(trimmed)
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
    /// are not the user's actual input.
    public static func isPlaceholderEcho(_ trimmed: String) -> Bool {
        guard trimmed.first == "❯" else { return false }
        let body = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        // Claude's placeholder always starts with "Try " followed by
        // an example in quotes.
        return body.lowercased().hasPrefix("try ") &&
               (body.contains("\"") || body.contains("\u{201C}"))
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
