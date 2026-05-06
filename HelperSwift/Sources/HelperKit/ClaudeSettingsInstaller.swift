import Foundation

/// Swift port of `helper/permissions_diagnose.py:install_claude_hook`.
///
/// Idempotently merges the CLI Pulse PermissionRequest hook into
/// `~/.claude/settings.json`. Mirrors the iter5 / iter6 / iter7
/// hardening work that landed in PR #18: canonical match-all
/// matcher, mixed-nested-hooks preservation, auto-heal on legacy
/// shape.
///
/// Schema reference (matches what Claude Code 2.1.128 + accepts):
///
///   {
///     "hooks": {
///       "PermissionRequest": [
///         {
///           "matcher": "",
///           "hooks": [
///             {"type": "command", "command": "<helper-path> remote-approval-hook --provider claude"}
///           ]
///         }
///       ]
///     }
///   }
///
/// The `matcher: ""` (canonical match-all) requirement is what
/// makes the hook intercept EVERY tool's permission prompt.
/// Narrower matchers (`"Bash"`, `"Read"`, …) silently drop
/// non-matching tools to Claude's native PTY prompt and break the
/// structured approval flow.
public enum ClaudeSettingsInstaller {

    /// Marker substring written into the hook command. Unique
    /// enough that no other PermissionRequest hook would use both
    /// the subcommand AND the argument shape — matching on this
    /// string alone is specific without false positives.
    public static let helperMarker = "remote-approval-hook --provider claude"

    public enum Action: String, Sendable, Equatable {
        case created    // file didn't exist; we wrote a fresh minimal one
        case added      // file existed with other keys/hooks; we appended ours
        case noop       // exact canonical entry already in place
        case replaced   // CLI Pulse hook present in non-canonical form; auto-healed
    }

    public struct InstallResult: Sendable, Equatable {
        public let settingsPath: String
        public let action: Action
        /// Was previously in the file (pre-install) — useful for
        /// the "Last install: replaced from <prev>" UX.
        public let previousCommand: String?
        /// What the file holds after install. Always populated.
        public let newCommand: String
    }

    public enum InstallError: Error, Equatable {
        case malformedSettings(String)
    }

    /// Default settings path: `~/.claude/settings.json`.
    public static func defaultSettingsPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }

    /// Build the hook command string. The Swift port doesn't need
    /// a python3 prefix — the binary IS the executable.
    public static func recommendedHookCommand(helperPath: String) -> String {
        // Quote paths with spaces so Claude Code's shell-parser
        // sees a single argv. Same precaution as the Python
        // helper's `shlex.quote` after iter5 review.
        if helperPath.contains(" ") {
            return "'\(helperPath)' \(helperMarker)"
        }
        return "\(helperPath) \(helperMarker)"
    }

    /// Build a single canonical hook entry: matcher = "", hooks =
    /// [{type: command, command: <cmd>}]. Single source of truth
    /// for both the install path AND the recommended-snippet
    /// path so the two can never drift on schema details.
    public static func canonicalHookEntry(command: String) -> [String: Any] {
        return [
            "matcher": "",
            "hooks": [
                ["type": "command", "command": command],
            ],
        ]
    }

    /// Idempotent install. Throws `InstallError.malformedSettings`
    /// if the existing file is non-JSON or non-object — we refuse
    /// to clobber the user's data; operator must fix by hand.
    @discardableResult
    public static func install(
        helperPath: String,
        settingsPath: URL? = nil
    ) throws -> InstallResult {
        let target = settingsPath ?? defaultSettingsPath()
        let targetCommand = recommendedHookCommand(helperPath: helperPath)

        var data: [String: Any] = [:]
        let fileExists = FileManager.default.fileExists(atPath: target.path)
        var fileHadContent = false
        if fileExists {
            do {
                let raw = try Data(contentsOf: target)
                if !raw.isEmpty {
                    fileHadContent = true
                    let parsed = try JSONSerialization.jsonObject(with: raw, options: [])
                    guard let dict = parsed as? [String: Any] else {
                        throw InstallError.malformedSettings(
                            "refusing to overwrite non-object JSON at \(target.path) (got \(type(of: parsed))). The file must be a JSON object."
                        )
                    }
                    data = dict
                }
            } catch let installErr as InstallError {
                throw installErr
            } catch {
                throw InstallError.malformedSettings(
                    "refusing to overwrite malformed JSON at \(target.path): \(error.localizedDescription). Fix the file by hand and retry."
                )
            }
        }

        // Locate / create hooks.PermissionRequest.
        var hooks = (data["hooks"] as? [String: Any]) ?? [:]
        var pr = (hooks["PermissionRequest"] as? [[String: Any]]) ?? []

        // Pass 1: classify entries + find previous_command.
        var previousCommand: String? = nil
        var cliPulseTouchedCount = 0
        var canonicalPureMatchingIndices: [Int] = []
        for (idx, entry) in pr.enumerated() {
            if isCliPulseLegacyEntry(entry) || matcherEntryHasOurHook(entry) {
                cliPulseTouchedCount += 1
            }
            if let cmd = entryCommand(entry), previousCommand == nil {
                previousCommand = cmd
            }
            if isCanonicalPureCliPulseEntry(entry),
               let nested = entry["hooks"] as? [[String: Any]],
               nested.count == 1,
               let cmd = nested[0]["command"] as? String,
               cmd == targetCommand {
                canonicalPureMatchingIndices.append(idx)
            }
        }
        let isNoop = cliPulseTouchedCount == 1 && canonicalPureMatchingIndices.count == 1

        let action: Action
        if isNoop {
            action = .noop
        } else {
            // Auto-heal rebuild: surgical removal of our hook from
            // every entry, then append exactly one canonical
            // CLI Pulse entry.
            var newPr: [[String: Any]] = []
            var hadUnrelated = false
            for entry in pr {
                if isCliPulseLegacyEntry(entry) {
                    // Pure CLI Pulse legacy → drop wholesale.
                    continue
                }
                if matcherEntryHasOurHook(entry) {
                    let nested = entry["hooks"] as? [[String: Any]] ?? []
                    let cleanedNested = nested.filter { !hookHasMarker($0) }
                    if cleanedNested.isEmpty {
                        // Entire nested array was CLI Pulse → drop entry.
                        continue
                    }
                    var preserved = entry
                    preserved["hooks"] = cleanedNested
                    newPr.append(preserved)
                    hadUnrelated = true
                } else {
                    newPr.append(entry)
                    hadUnrelated = true
                }
            }
            newPr.append(canonicalHookEntry(command: targetCommand))
            pr = newPr

            if previousCommand != nil {
                action = .replaced
            } else if hadUnrelated || fileHadContent {
                action = .added
            } else {
                action = .created
            }
        }

        hooks["PermissionRequest"] = pr
        data["hooks"] = hooks

        if action != .noop {
            try writeAtomically(data: data, to: target)
        }

        return InstallResult(
            settingsPath: target.path,
            action: action,
            previousCommand: previousCommand,
            newCommand: targetCommand
        )
    }

    // MARK: - shape predicates

    static func hookHasMarker(_ h: [String: Any]) -> Bool {
        guard let cmd = h["command"] as? String else { return false }
        return cmd.contains(helperMarker)
    }

    static func isCliPulseLegacyEntry(_ entry: [String: Any]) -> Bool {
        // Legacy flat shape: top-level command, no nested hooks.
        if entry["hooks"] is [Any] { return false }
        guard let cmd = entry["command"] as? String else { return false }
        return cmd.contains(helperMarker)
    }

    static func matcherEntryHasOurHook(_ entry: [String: Any]) -> Bool {
        guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
        return nested.contains { hookHasMarker($0) }
    }

    static func isCanonicalMatcher(_ entry: [String: Any]) -> Bool {
        // Canonical match-all is exactly the empty string. Any
        // other value (`"Bash"`, missing key, nil) is non-canonical.
        guard let matcher = entry["matcher"] as? String else { return false }
        return matcher.isEmpty
    }

    static func isCanonicalPureCliPulseEntry(_ entry: [String: Any]) -> Bool {
        guard isCanonicalMatcher(entry) else { return false }
        guard let nested = entry["hooks"] as? [[String: Any]],
              nested.count == 1 else { return false }
        return hookHasMarker(nested[0])
    }

    static func entryCommand(_ entry: [String: Any]) -> String? {
        if isCliPulseLegacyEntry(entry) {
            return entry["command"] as? String
        }
        if matcherEntryHasOurHook(entry),
           let nested = entry["hooks"] as? [[String: Any]] {
            for h in nested where hookHasMarker(h) {
                return h["command"] as? String
            }
        }
        return nil
    }

    // MARK: - atomic write with mode preservation

    private static func writeAtomically(data: [String: Any], to target: URL) throws {
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        // Detect existing mode so we don't widen 0600 → 0644 on
        // re-install. New files default to 0600 — settings often
        // contain machine-readable hook commands referencing $HOME
        // paths, and on multi-user systems the safer default is
        // owner-only.
        var modeToSet: Int = 0o600
        if let attrs = try? FileManager.default.attributesOfItem(atPath: target.path),
           let n = attrs[.posixPermissions] as? NSNumber {
            modeToSet = n.intValue & 0o777
        }
        let serialised = try JSONSerialization.data(
            withJSONObject: data,
            options: [.prettyPrinted, .sortedKeys]
        )
        var withTrailingNewline = serialised
        withTrailingNewline.append(0x0a)
        let tmp = target.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        try withTrailingNewline.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(modeToSet))],
            ofItemAtPath: tmp.path
        )
        let renameResult = Darwin.rename(
            (tmp.path as NSString).fileSystemRepresentation,
            (target.path as NSString).fileSystemRepresentation
        )
        if renameResult != 0 {
            throw InstallError.malformedSettings(
                "rename: \(String(cString: strerror(errno)))"
            )
        }
        // Re-chmod the destination defensively — `rename` may
        // preserve the destination's prior mode on some POSIX
        // implementations.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(modeToSet))],
            ofItemAtPath: target.path
        )
    }
}
