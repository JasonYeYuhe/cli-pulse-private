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

    /// M1: the events CLI Pulse wires the hook into. PreToolUse fires for EVERY
    /// tool call (the always-present lever a broad allowlist would otherwise
    /// suppress); PermissionRequest fires only when a permission dialog would
    /// show. Mirrors the Python `_CLI_PULSE_HOOK_EVENTS`.
    public static let hookEvents = ["PermissionRequest", "PreToolUse"]

    public enum Action: String, Sendable, Equatable {
        case created    // file didn't exist; we wrote a fresh minimal one
        case added      // file existed with other keys/hooks; we appended ours
        case noop       // exact canonical entry already in place
        case replaced   // CLI Pulse hook present in non-canonical form; auto-healed
    }

    public struct InstallResult: Sendable, Equatable {
        public let settingsPath: String
        /// Aggregate across both events.
        public let action: Action
        /// Was previously in the file (pre-install) — useful for
        /// the "Last install: replaced from <prev>" UX.
        public let previousCommand: String?
        /// What the file holds after install. Always populated.
        public let newCommand: String
        /// M1: per-event action detail (PermissionRequest / PreToolUse).
        public let events: [String: Action]
    }

    /// M1: result of removing the CLI Pulse hooks from both events.
    public struct UninstallResult: Sendable, Equatable {
        public let settingsPath: String
        /// `"removed"` when hooks were stripped, `"noop"` when none were present.
        public let action: String
        /// Total hook entries removed across both events.
        public let removed: Int
        /// Per-event removed counts.
        public let events: [String: Int]
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
                    let parsed = try JSONSerialization.jsonObject(with: raw, options: [])
                    guard let dict = parsed as? [String: Any] else {
                        throw InstallError.malformedSettings(
                            "refusing to overwrite non-object JSON at \(target.path) (got \(type(of: parsed))). The file must be a JSON object."
                        )
                    }
                    data = dict
                    // Match Python's `bool(data)`: a `{}` file has content bytes
                    // but is an EMPTY object → still a "created" (review: codex).
                    fileHadContent = !dict.isEmpty
                }
            } catch let installErr as InstallError {
                throw installErr
            } catch {
                throw InstallError.malformedSettings(
                    "refusing to overwrite malformed JSON at \(target.path): \(error.localizedDescription). Fix the file by hand and retry."
                )
            }
        }

        // M1: merge our canonical entry into BOTH events (PermissionRequest +
        // PreToolUse) with the same auto-heal / mixed-entry-preservation.
        var hooks = (data["hooks"] as? [String: Any]) ?? [:]
        var actions: [Action] = []
        var eventActions: [String: Action] = [:]
        var previousCommand: String? = nil
        for event in Self.hookEvents {
            let (newList, action, prev) = mergeCliPulseEvent(
                existing: hooks[event] as? [Any],
                targetCommand: targetCommand,
                fileHadContent: fileHadContent
            )
            hooks[event] = newList
            actions.append(action)
            eventActions[event] = action
            // Adopt `prev` ONLY from a .replaced event — a noop event returns
            // its current (matching) command, which would misreport the live
            // command as "previous" when the aggregate is .replaced because of
            // the OTHER event (Codex-review catch, mirrored from the Python).
            if action == .replaced, let p = prev, previousCommand == nil {
                previousCommand = p
            }
        }
        data["hooks"] = hooks
        let aggregate = Self.aggregateAction(actions, fileHadContent: fileHadContent)

        if aggregate != .noop {
            try writeAtomically(data: data, to: target)
        }

        return InstallResult(
            settingsPath: target.path,
            action: aggregate,
            previousCommand: previousCommand,
            newCommand: targetCommand,
            events: eventActions
        )
    }

    /// Idempotently merge one CLI Pulse entry into a SINGLE event's list. Pure —
    /// returns (newList, action, previousCommand), mirrors the Python
    /// `_merge_cli_pulse_event`. Same auto-heal semantics: drop legacy-flat
    /// entries, surgically strip our nested hook from mixed matcher entries
    /// (preserving the user's co-resident hooks), append one canonical entry.
    static func mergeCliPulseEvent(
        existing: [Any]?, targetCommand: String, fileHadContent: Bool
    ) -> (newList: [Any], action: Action, previousCommand: String?) {
        let pr = existing ?? []
        var previousCommand: String? = nil
        var cliPulseTouchedCount = 0
        var canonicalPureMatchingIndices: [Int] = []
        for (idx, element) in pr.enumerated() {
            guard let entry = element as? [String: Any] else { continue }  // non-object → unrelated
            if isCliPulseLegacyEntry(entry) || matcherEntryHasOurHook(entry) {
                cliPulseTouchedCount += 1
            }
            if let cmd = entryCommand(entry), previousCommand == nil {
                previousCommand = cmd
            }
            if isCanonicalPureCliPulseEntry(entry),
               let nested = entry["hooks"] as? [Any],
               nested.count == 1,
               let cmd = (nested[0] as? [String: Any])?["command"] as? String,
               cmd == targetCommand {
                canonicalPureMatchingIndices.append(idx)
            }
        }
        let isNoop = cliPulseTouchedCount == 1 && canonicalPureMatchingIndices.count == 1
        if isNoop {
            return (pr, .noop, previousCommand)
        }
        var newPr: [Any] = []
        var hadUnrelated = false
        for element in pr {
            guard let entry = element as? [String: Any] else {
                newPr.append(element); hadUnrelated = true; continue  // preserve non-object verbatim
            }
            if isCliPulseLegacyEntry(entry) { continue }
            if matcherEntryHasOurHook(entry) {
                let nested = entry["hooks"] as? [Any] ?? []
                let cleanedNested = nested.filter { !hookHasMarker($0) }
                if cleanedNested.isEmpty { continue }
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
        let action: Action
        if previousCommand != nil {
            action = .replaced
        } else if hadUnrelated || fileHadContent {
            action = .added
        } else {
            action = .created
        }
        return (newPr, action, previousCommand)
    }

    /// Combine per-event actions into one aggregate for the UI. Mirrors the
    /// Python `_aggregate_action`.
    static func aggregateAction(_ actions: [Action], fileHadContent: Bool) -> Action {
        let s = Set(actions)
        if s == [.noop] { return .noop }
        if s.contains(.replaced) { return .replaced }
        if !fileHadContent && !s.contains(.added) && !s.contains(.noop) { return .created }
        return .added
    }

    /// Remove EVERY CLI Pulse hook from a single event's list (uninstall).
    /// Preserves the user's co-resident hooks in mixed matcher entries. Mirrors
    /// the Python `_strip_cli_pulse_from_event`.
    static func stripCliPulseFromEvent(
        _ existing: [Any]?
    ) -> (newList: [Any], removed: Int) {
        let pr = existing ?? []
        var newPr: [Any] = []
        var removed = 0
        for element in pr {
            guard let entry = element as? [String: Any] else {
                newPr.append(element); continue  // preserve non-object verbatim
            }
            if isCliPulseLegacyEntry(entry) { removed += 1; continue }
            if matcherEntryHasOurHook(entry) {
                let nested = entry["hooks"] as? [Any] ?? []
                let cleaned = nested.filter { !hookHasMarker($0) }
                removed += nested.count - cleaned.count
                if cleaned.isEmpty { continue }
                var preserved = entry
                preserved["hooks"] = cleaned
                newPr.append(preserved)
            } else {
                newPr.append(entry)
            }
        }
        return (newPr, removed)
    }

    /// Remove the CLI Pulse hooks (both events) from `~/.claude/settings.json`,
    /// preserving the user's own hooks. The reversible other half of the opt-in.
    /// Mirrors the Python `uninstall_claude_hook`. Idempotent.
    @discardableResult
    public static func uninstall(
        settingsPath: URL? = nil
    ) throws -> UninstallResult {
        let target = settingsPath ?? defaultSettingsPath()
        let noop = UninstallResult(settingsPath: target.path, action: "noop",
                                   removed: 0, events: [:])
        guard FileManager.default.fileExists(atPath: target.path) else { return noop }
        let raw: Data
        do { raw = try Data(contentsOf: target) } catch { return noop }
        if raw.isEmpty { return noop }
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: raw, options: [])
        } catch {
            throw InstallError.malformedSettings(
                "refusing to overwrite malformed JSON at \(target.path): \(error.localizedDescription). Fix the file by hand and retry."
            )
        }
        guard var data = parsed as? [String: Any] else {
            throw InstallError.malformedSettings(
                "refusing to overwrite non-object JSON at \(target.path) (got \(type(of: parsed))). The file must be a JSON object."
            )
        }
        guard var hooks = data["hooks"] as? [String: Any] else { return noop }

        var perEvent: [String: Int] = [:]
        var totalRemoved = 0
        for event in Self.hookEvents {
            guard hooks[event] != nil else { continue }
            let (newList, removed) = stripCliPulseFromEvent(hooks[event] as? [Any])
            if removed == 0 { continue }
            perEvent[event] = removed
            totalRemoved += removed
            if newList.isEmpty {
                // Drop an emptied event array so we don't leave `"PreToolUse": []`.
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = newList
            }
        }
        if totalRemoved == 0 { return noop }

        if hooks.isEmpty {
            data.removeValue(forKey: "hooks")
        } else {
            data["hooks"] = hooks
        }
        try writeAtomically(data: data, to: target)
        return UninstallResult(settingsPath: target.path, action: "removed",
                               removed: totalRemoved, events: perEvent)
    }

    // MARK: - shape predicates

    static func hookHasMarker(_ h: Any) -> Bool {
        // Accepts Any so a nested `hooks` array containing a non-object element
        // (Python treats these arrays as list[Any]) doesn't fail a whole-array
        // cast and silently drop the user's data (review: codex).
        guard let d = h as? [String: Any], let cmd = d["command"] as? String else { return false }
        return cmd.contains(helperMarker)
    }

    static func isCliPulseLegacyEntry(_ entry: [String: Any]) -> Bool {
        // Legacy flat shape: top-level command, no nested hooks.
        if entry["hooks"] is [Any] { return false }
        guard let cmd = entry["command"] as? String else { return false }
        return cmd.contains(helperMarker)
    }

    static func matcherEntryHasOurHook(_ entry: [String: Any]) -> Bool {
        // `hooks` is treated as [Any] so a non-object element can't fail the cast
        // and hide our marker (which would duplicate on install + leak on
        // uninstall) (review: codex).
        guard let nested = entry["hooks"] as? [Any] else { return false }
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
