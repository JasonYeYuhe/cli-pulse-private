import XCTest
@testable import HelperKit
import Foundation

/// M2p2 codex-Swift port — Swift twin of the codex block in
/// `helper/test_permissions_diagnose.py` (#357). Codex hooks are
/// Claude-compatible: `~/.codex/hooks.json` has the byte-identical
/// `{"hooks": {<event>: [...]}}` structure, so `ClaudeSettingsInstaller`
/// serves both providers via the marker parameter. These tests focus on
/// what's DIFFERENT: the codex marker in the command, the trust payload,
/// full isolation between claude + codex co-resident in one file, and the
/// two #357 hardenings (anti-clobber + type=="command" canonical check)
/// that apply to BOTH providers.
final class CodexSettingsInstallerTests: XCTestCase {

    private var tmpDir: URL!

    override func setUp() {
        super.setUp()
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexInstallerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmpDir)
        super.tearDown()
    }

    private var codexSettings: URL {
        tmpDir.appendingPathComponent(".codex").appendingPathComponent("hooks.json")
    }

    private var claudeSettings: URL {
        tmpDir.appendingPathComponent(".claude").appendingPathComponent("settings.json")
    }

    private var sharedSettings: URL {
        tmpDir.appendingPathComponent("shared.json")
    }

    private func readHooks(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (obj["hooks"] as? [String: Any]) ?? [:]
    }

    private func commands(in eventList: Any?) -> [String] {
        guard let entries = eventList as? [[String: Any]] else { return [] }
        var out: [String] = []
        for entry in entries {
            for h in (entry["hooks"] as? [[String: Any]]) ?? [] {
                if let cmd = h["command"] as? String { out.append(cmd) }
            }
        }
        return out
    }

    // MARK: - marker / command

    func testMarkerForDistinguishesProviders() {
        XCTAssertEqual(ClaudeSettingsInstaller.marker(for: "claude"),
                       "remote-approval-hook --provider claude")
        XCTAssertEqual(ClaudeSettingsInstaller.marker(for: "codex"),
                       "remote-approval-hook --provider codex")
        // helperMarker stays the claude constant — shipped callers unchanged.
        XCTAssertEqual(ClaudeSettingsInstaller.helperMarker,
                       ClaudeSettingsInstaller.marker(for: "claude"))
    }

    func testRecommendedHookCommandProviderCodex() {
        XCTAssertEqual(
            ClaudeSettingsInstaller.recommendedHookCommand(helperPath: "/abs/helper", provider: "codex"),
            "/abs/helper remote-approval-hook --provider codex")
        // Spaces still quoted.
        XCTAssertEqual(
            ClaudeSettingsInstaller.recommendedHookCommand(helperPath: "/a b/helper", provider: "codex"),
            "'/a b/helper' remote-approval-hook --provider codex")
    }

    func testDefaultSettingsPathPerProvider() {
        XCTAssertTrue(ClaudeSettingsInstaller.defaultSettingsPath(provider: "codex").path
            .hasSuffix(".codex/hooks.json"))
        XCTAssertTrue(ClaudeSettingsInstaller.defaultSettingsPath(provider: "claude").path
            .hasSuffix(".claude/settings.json"))
    }

    // MARK: - codex install / uninstall

    func testInstallCodexCreatesBothEventsWithCodexMarker() throws {
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: codexSettings, provider: "codex")
        XCTAssertEqual(result.action, .created)
        XCTAssertTrue(result.requiresManualTrust)
        XCTAssertEqual(result.trustCommand, "/hooks")
        let hooks = try readHooks(codexSettings)
        for event in ClaudeSettingsInstaller.hookEvents {
            let cmds = commands(in: hooks[event])
            XCTAssertEqual(cmds.count, 1, event)
            XCTAssertTrue(cmds[0].contains("remote-approval-hook --provider codex"), cmds[0])
        }
    }

    func testInstallCodexNoopOnReinstall() throws {
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: codexSettings, provider: "codex")
        let again = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: codexSettings, provider: "codex")
        XCTAssertEqual(again.action, .noop)
        // Trust payload present even on noop — the user may not have trusted yet.
        XCTAssertTrue(again.requiresManualTrust)
    }

    func testClaudeInstallCarriesNoTrustPayload() throws {
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: claudeSettings)
        XCTAssertFalse(result.requiresManualTrust)
        XCTAssertNil(result.trustCommand)
    }

    // MARK: - marker isolation (the critical guarantee)

    func testCodexAndClaudeCoexistInSameFile() throws {
        _ = try ClaudeSettingsInstaller.install(helperPath: "/h/helper", settingsPath: sharedSettings)
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: sharedSettings, provider: "codex")
        // codex APPENDS alongside claude (file already had our claude data).
        XCTAssertEqual(result.action, .added)
        let hooks = try readHooks(sharedSettings)
        for event in ClaudeSettingsInstaller.hookEvents {
            let cmds = commands(in: hooks[event])
            XCTAssertTrue(cmds.contains { $0.contains("--provider claude") }, "\(event): \(cmds)")
            XCTAssertTrue(cmds.contains { $0.contains("--provider codex") }, "\(event): \(cmds)")
        }
    }

    func testUninstallCodexLeavesClaudeUntouched() throws {
        _ = try ClaudeSettingsInstaller.install(helperPath: "/h/helper", settingsPath: sharedSettings)
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: sharedSettings, provider: "codex")
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: sharedSettings, provider: "codex")
        XCTAssertEqual(result.action, "removed")
        XCTAssertEqual(result.removed, 2)  // one codex hook per event
        let hooks = try readHooks(sharedSettings)
        for event in ClaudeSettingsInstaller.hookEvents {
            let cmds = commands(in: hooks[event])
            XCTAssertTrue(cmds.contains { $0.contains("--provider claude") }, "\(event): \(cmds)")
            XCTAssertFalse(cmds.contains { $0.contains("--provider codex") }, "\(event): \(cmds)")
        }
    }

    func testUninstallClaudeLeavesCodexUntouched() throws {
        _ = try ClaudeSettingsInstaller.install(helperPath: "/h/helper", settingsPath: sharedSettings)
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: sharedSettings, provider: "codex")
        _ = try ClaudeSettingsInstaller.uninstall(settingsPath: sharedSettings)
        let hooks = try readHooks(sharedSettings)
        for event in ClaudeSettingsInstaller.hookEvents {
            let cmds = commands(in: hooks[event])
            XCTAssertFalse(cmds.contains { $0.contains("--provider claude") }, "\(event): \(cmds)")
            XCTAssertTrue(cmds.contains { $0.contains("--provider codex") }, "\(event): \(cmds)")
        }
    }

    func testUninstallCodexRemovesBothEventsAndHooksKey() throws {
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: codexSettings, provider: "codex")
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: codexSettings, provider: "codex")
        XCTAssertEqual(result.action, "removed")
        XCTAssertEqual(result.removed, 2)
        let data = try Data(contentsOf: codexSettings)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNil(obj["hooks"], "emptied hooks key must be dropped")
    }

    func testUninstallCodexNoopWhenFileMissing() throws {
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: codexSettings, provider: "codex")
        XCTAssertEqual(result.action, "noop")
        XCTAssertEqual(result.removed, 0)
    }

    // MARK: - #357 hardening 1: anti-clobber for malformed hooks structures

    func testInstallRefusesNonDictHooksThatMayHoldUserData() throws {
        // A user who mis-nested the event array directly at `hooks` — real hook
        // data a silent `[:]` coercion would DISCARD. Applies to BOTH providers.
        for provider in ["claude", "codex"] {
            let target = tmpDir.appendingPathComponent("bad-\(provider).json")
            let body = #"{"hooks": [{"matcher": "", "hooks": [{"type": "command", "command": "user-audit"}]}]}"#
            try body.data(using: .utf8)!.write(to: target)
            XCTAssertThrowsError(try ClaudeSettingsInstaller.install(
                helperPath: "/h/helper", settingsPath: target, provider: provider)) { err in
                guard case ClaudeSettingsInstaller.InstallError.malformedSettings = err else {
                    return XCTFail("expected malformedSettings, got \(err)")
                }
            }
            // File untouched.
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), body, provider)
        }
    }

    func testInstallRefusesNonListEventValue() throws {
        let target = tmpDir.appendingPathComponent("bad-event.json")
        let body = #"{"hooks": {"PreToolUse": "not-an-array"}}"#
        try body.data(using: .utf8)!.write(to: target)
        XCTAssertThrowsError(try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: target, provider: "codex"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), body)
    }

    func testInstallStillCreatesWhenHooksAbsent() throws {
        // Boundary guard: a MISSING hooks key is NOT malformed — still installs.
        let target = tmpDir.appendingPathComponent("no-hooks.json")
        try #"{"model": "opus"}"#.data(using: .utf8)!.write(to: target)
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: target, provider: "codex")
        XCTAssertEqual(result.action, .added)
        let obj = try JSONSerialization.jsonObject(with: Data(contentsOf: target)) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "opus")
    }

    // MARK: - heterogeneous nested arrays (Python parity, review: codex P2)

    func testHealHeterogeneousNestedArrayReportsReplacedWithPreviousCommand() throws {
        // A nested hooks array holding our STALE hook plus a non-object element
        // (e.g. a user's stray string). The old whole-array [[String: Any]] cast
        // failed → Swift reported `added` with no previous_command while Python
        // reports `replaced` + the old command. Pin the Python behavior.
        let target = tmpDir.appendingPathComponent("hetero.json")
        let stale = "/old/helper remote-approval-hook --provider codex"
        let body: [String: Any] = ["hooks": [
            "PermissionRequest": [[
                "matcher": "",
                "hooks": [["type": "command", "command": stale], "user note"],
            ]],
            "PreToolUse": [[
                "matcher": "",
                "hooks": [["type": "command", "command": stale], "user note"],
            ]],
        ]]
        try JSONSerialization.data(withJSONObject: body).write(to: target)

        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/h/helper", settingsPath: target, provider: "codex")
        XCTAssertEqual(result.action, .replaced)
        XCTAssertEqual(result.previousCommand, stale)
        // The user's non-object element survives the heal verbatim.
        let hooks = try readHooks(target)
        for event in ClaudeSettingsInstaller.hookEvents {
            let entries = hooks[event] as! [[String: Any]]
            let preservedNested = entries.first { ($0["hooks"] as? [Any])?.contains { $0 is String } ?? false }
            XCTAssertNotNil(preservedNested, "\(event): user's non-object element must survive")
            // And the fresh canonical codex entry is present.
            XCTAssertTrue(commands(in: entries).contains {
                $0.contains("--provider codex") && $0.contains("/h/helper") }, event)
        }
    }

    // MARK: - #357 hardening 2: canonical noop requires type == "command"

    func testInstallHealsInertNonCommandTypeEntry() throws {
        // Correct marker + command but a hand-edited non-command type → INERT
        // (Claude/Codex only execute command hooks). Reinstall must HEAL it,
        // not report noop. Both providers.
        for provider in ["claude", "codex"] {
            let target = tmpDir.appendingPathComponent("inert-\(provider).json")
            let cmd = ClaudeSettingsInstaller.recommendedHookCommand(
                helperPath: "/h/helper", provider: provider)
            let body: [String: Any] = ["hooks": [
                "PermissionRequest": [["matcher": "", "hooks": [["type": "prompt", "command": cmd]]]],
                "PreToolUse": [["matcher": "", "hooks": [["type": "prompt", "command": cmd]]]],
            ]]
            try JSONSerialization.data(withJSONObject: body).write(to: target)

            let result = try ClaudeSettingsInstaller.install(
                helperPath: "/h/helper", settingsPath: target, provider: provider)
            XCTAssertEqual(result.action, .replaced, "\(provider): inert type must be healed, not noop")
            let hooks = try readHooks(target)
            for event in ClaudeSettingsInstaller.hookEvents {
                let entries = hooks[event] as! [[String: Any]]
                XCTAssertEqual(entries.count, 1, "\(provider)/\(event)")
                let inner = (entries[0]["hooks"] as! [[String: Any]])[0]
                XCTAssertEqual(inner["type"] as? String, "command", "\(provider)/\(event)")
                XCTAssertEqual(inner["command"] as? String, cmd, "\(provider)/\(event)")
            }
        }
    }
}
