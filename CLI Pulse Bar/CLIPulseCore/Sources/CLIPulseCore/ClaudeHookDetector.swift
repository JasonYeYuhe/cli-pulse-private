#if os(macOS)
import Foundation

/// Phase 3 Iter 2B follow-up — detect whether the local
/// `~/.claude/settings.json` has CLI Pulse's PermissionRequest hook
/// wired up. Used by the Sessions tab to surface a subtle "approval
/// hook not wired" banner when the helper supports structured
/// approvals (advertises `capabilities.approvals == true`) but
/// Claude itself isn't pointing at the helper's hook script — in
/// that state, Claude shows its native PTY permission prompt
/// (`1. Yes, continue` chat text) instead of firing
/// `hook_create_approval`, and the macOS app's structured Approve /
/// Reject controls never light up.
///
/// This file is **read-only**. The actual `install-claude-hook`
/// flow lives on the Python helper side (idempotent JSON merge in
/// `permissions_diagnose.install_claude_hook`); the Swift surface
/// shows the detection + a copy-pasteable CLI command and lets the
/// user run it from their terminal where the helper checkout
/// already lives.
public enum ClaudeHookDetector {

    /// Detection states that drive the Sessions banner.
    public enum Status: Sendable, Equatable {
        /// Settings file present, parsed cleanly, contains a
        /// PermissionRequest hook whose command points at our
        /// helper script. Banner suppressed.
        case wired
        /// Settings file present + parses cleanly, but no entry in
        /// `hooks.PermissionRequest` matches our marker. The
        /// banner explains how to install.
        case notWired
        /// Settings file is missing entirely. Same banner as
        /// `notWired` (the install command handles the create
        /// case), but the diagnostic message can mention "no
        /// settings file yet" for clarity.
        case settingsMissing
        /// Settings file exists but couldn't be parsed (malformed
        /// JSON / non-object root / unreadable). Banner asks the
        /// user to fix the file by hand — the install CLI also
        /// refuses to overwrite a malformed file.
        case parseError(String)
    }

    /// Marker the helper writes into the hook command at install
    /// time. Unique enough that no other PermissionRequest hook
    /// would match (matches `helper/permissions_diagnose.py
    /// install_claude_hook`).
    public static let helperHookMarker = "remote-approval-hook --provider claude"

    /// Default path checked. macOS app sandbox may need an
    /// entitlement to read this; if it doesn't, callers can pass
    /// an explicit URL.
    public static let defaultSettingsURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }()

    /// Read the user's `~/.claude/settings.json` and report the
    /// hook-wired status. Synchronous + cheap; the macOS UI
    /// re-runs it from the Sessions `.task` polling loop.
    public static func currentStatus(at url: URL? = nil) -> Status {
        let location = url ?? defaultSettingsURL
        // Missing file is a common case (fresh install, never set
        // up Claude permissions). Don't surface as error.
        guard FileManager.default.fileExists(atPath: location.path) else {
            return .settingsMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: location)
        } catch {
            return .parseError("could not read \(location.path): \(error.localizedDescription)")
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data) else {
            return .parseError("\(location.lastPathComponent) is not valid JSON")
        }
        guard let dict = raw as? [String: Any] else {
            return .parseError("\(location.lastPathComponent) root is not a JSON object")
        }
        guard let hooks = dict["hooks"] as? [String: Any] else {
            return .notWired
        }
        guard let pr = hooks["PermissionRequest"] as? [[String: Any]] else {
            return .notWired
        }
        let hasCliPulse = pr.contains { entry in
            if let command = entry["command"] as? String,
               command.contains(Self.helperHookMarker) {
                return true
            }
            return false
        }
        return hasCliPulse ? .wired : .notWired
    }

    /// CLI command the user runs once to install the hook. The
    /// `<helper-path>` placeholder is filled in by the user; we
    /// don't try to discover the helper checkout from inside the
    /// sandboxed Mac app (it can live anywhere the user cloned
    /// `cli-pulse-private`).
    ///
    /// The Sessions banner offers a `Copy command` button that
    /// puts this exact string on the clipboard.
    public static let installCommandTemplate: String =
        "python3 <path-to-helper>/cli_pulse_helper.py remote-approvals install-claude-hook"
}
#endif
