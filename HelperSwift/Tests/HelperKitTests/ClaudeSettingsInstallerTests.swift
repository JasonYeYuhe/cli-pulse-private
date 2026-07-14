import XCTest
@testable import HelperKit
import Foundation

/// Swift port of the iter5 / iter6 / iter7 install_claude_hook
/// invariants from `helper/test_permissions_diagnose.py`. Every
/// edge Codex review caught on PR #18 has a parity test here.
final class ClaudeSettingsInstallerTests: XCTestCase {

    private var tmp: URL!
    private var settingsPath: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstallerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        settingsPath = tmp.appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    private func read() throws -> [String: Any] {
        let data = try Data(contentsOf: settingsPath)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func cliPulseEntries(_ data: [String: Any]) -> [[String: Any]] {
        let hooks = data["hooks"] as? [String: Any] ?? [:]
        let pr = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        return pr.filter { ClaudeSettingsInstaller.entryCommand($0) != nil }
    }

    // MARK: - basic shape

    func testInstallCreatesFreshSettingsFile() throws {
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertEqual(result.action, .created)
        XCTAssertNil(result.previousCommand)
        XCTAssertTrue(result.newCommand.contains("remote-approval-hook --provider claude"))
        let written = try read()
        let pr = (written["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(pr?.count, 1)
        XCTAssertEqual(pr?.first?["matcher"] as? String, "")
        let nested = pr?.first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(nested?.count, 1)
        XCTAssertEqual(nested?.first?["type"] as? String, "command")
    }

    func testInstallNoopOnSecondCall() throws {
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        let again = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertEqual(again.action, .noop)
    }

    // MARK: - matcher canonicality (iter6)

    func testNarrowerMatcherReplaced() throws {
        // Pre-seed with a Bash-only matcher entry — same command,
        // wrong matcher. iter6 contract: must auto-heal to
        // canonical match-all.
        let target = ClaudeSettingsInstaller.recommendedHookCommand(
            helperPath: "/usr/local/bin/cli_pulse_helper"
        )
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "matcher": "Bash",
                        "hooks": [["type": "command", "command": target]],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seed)
            .write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertEqual(result.action, .replaced,
                       "narrower matcher must replace even when inner command matches")
        let written = try read()
        let pr = (written["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(pr?.count, 1)
        XCTAssertEqual(pr?.first?["matcher"] as? String, "")
    }

    func testMissingMatcherKeyReplaced() throws {
        let target = ClaudeSettingsInstaller.recommendedHookCommand(
            helperPath: "/usr/local/bin/cli_pulse_helper"
        )
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    // No matcher key.
                    ["hooks": [["type": "command", "command": target]]],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let r = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertEqual(r.action, .replaced)
        let written = try read()
        let pr = (written["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(pr?.first?["matcher"] as? String, "")
    }

    // MARK: - mixed-nested-hooks preservation (iter6)

    func testMixedNestedHooksPreservesUserHook() throws {
        let target = ClaudeSettingsInstaller.recommendedHookCommand(
            helperPath: "/usr/local/bin/cli_pulse_helper"
        )
        let auditCmd = "/usr/local/bin/security-audit-hook --emit jsonl"
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    [
                        "matcher": "",
                        "hooks": [
                            ["type": "command", "command": auditCmd],
                            ["type": "command", "command": target],
                        ],
                    ],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let r = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertEqual(r.action, .replaced)
        let written = try read()
        let pr = (written["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        // Audit hook must survive surgical removal of CLI Pulse.
        let auditPresent = pr.contains { entry in
            let nested = (entry["hooks"] as? [[String: Any]]) ?? []
            return nested.contains { ($0["command"] as? String) == auditCmd }
        }
        XCTAssertTrue(auditPresent, "user's audit hook must survive surgical removal")
        // Exactly one canonical CLI Pulse entry.
        let cliPulseCount = pr.filter { entry in
            ClaudeSettingsInstaller.entryCommand(entry) != nil
        }.count
        XCTAssertEqual(cliPulseCount, 1)
    }

    // MARK: - legacy flat schema auto-heal (iter5)

    func testLegacyFlatSchemaAutoHeal() throws {
        let target = ClaudeSettingsInstaller.recommendedHookCommand(
            helperPath: "/usr/local/bin/cli_pulse_helper"
        )
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "hooks": [
                "PermissionRequest": [
                    // Legacy flat shape — Claude Code's /doctor
                    // rejects this with "Expected array, but
                    // received undefined". Must auto-heal.
                    ["type": "command", "command": target],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let r = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertEqual(r.action, .replaced)
        let written = try read()
        let pr = (written["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(pr?.count, 1)
        XCTAssertNil(pr?.first?["type"] as? String,
                     "matcher-shape entries must NOT have a top-level `type`")
        XCTAssertNotNil(pr?.first?["matcher"])
        XCTAssertNotNil(pr?.first?["hooks"])
    }

    // MARK: - paths with spaces

    func testHelperPathWithSpacesGetsQuoted() throws {
        let r = try ClaudeSettingsInstaller.install(
            helperPath: "/Applications/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper",
            settingsPath: settingsPath
        )
        XCTAssertTrue(r.newCommand.hasPrefix("'"),
                      "path with spaces must be single-quoted; got: \(r.newCommand)")
        XCTAssertTrue(r.newCommand.contains("'/Applications/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper'"))
    }

    // MARK: - preserves unrelated keys

    func testInstallPreservesUnrelatedTopLevelKeys() throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: [String: Any] = [
            "permissions": ["allow": ["Bash(npm test:*)"], "deny": []],
            "model": "claude-sonnet-4-5",
            "extra": ["nested": ["deeply": true]],
        ]
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        let written = try read()
        XCTAssertEqual(written["model"] as? String, "claude-sonnet-4-5")
        let perms = written["permissions"] as? [String: Any]
        XCTAssertNotNil(perms)
        let extra = written["extra"] as? [String: Any]
        XCTAssertNotNil(extra)
    }

    // MARK: - mode preservation (iter5 P2)

    func testInstallPreservesExistingMode0600() throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let seed: [String: Any] = ["model": "x"]
        let data = try JSONSerialization.data(withJSONObject: seed)
        try data.write(to: settingsPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: settingsPath.path
        )
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: settingsPath.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600,
                       "existing 0600 mode must NOT be widened by install")
    }

    func testInstallNewFileDefaultsTo0600() throws {
        _ = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper",
            settingsPath: settingsPath
        )
        let attrs = try FileManager.default.attributesOfItem(atPath: settingsPath.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600)
    }

    // MARK: - malformed input

    func testInstallRejectsMalformedJson() throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{ not json".write(to: settingsPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeSettingsInstaller.install(
            helperPath: "/x", settingsPath: settingsPath
        )) { err in
            guard case ClaudeSettingsInstaller.InstallError.malformedSettings = err else {
                XCTFail("expected malformedSettings"); return
            }
        }
        // File untouched.
        let raw = try String(contentsOf: settingsPath, encoding: .utf8)
        XCTAssertEqual(raw, "{ not json")
    }

    func testInstallRejectsNonObjectRoot() throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "[1, 2, 3]".write(to: settingsPath, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeSettingsInstaller.install(
            helperPath: "/x", settingsPath: settingsPath
        )) { err in
            guard case ClaudeSettingsInstaller.InstallError.malformedSettings = err else {
                XCTFail("expected malformedSettings"); return
            }
        }
    }

    // MARK: - M1: both events (PermissionRequest + PreToolUse) + uninstall

    private func canonicalCmd(_ data: [String: Any], event: String) -> String? {
        let hooks = data["hooks"] as? [String: Any] ?? [:]
        guard let entries = hooks[event] as? [[String: Any]], entries.count == 1 else { return nil }
        return ClaudeSettingsInstaller.entryCommand(entries[0])
    }

    func testInstallWiresBothEvents() throws {
        let result = try ClaudeSettingsInstaller.install(
            helperPath: "/usr/local/bin/cli_pulse_helper", settingsPath: settingsPath)
        let data = try read()
        for event in ["PermissionRequest", "PreToolUse"] {
            XCTAssertNotNil(canonicalCmd(data, event: event), "\(event) not wired")
        }
        XCTAssertEqual(result.events, ["PermissionRequest": .created, "PreToolUse": .created])
        XCTAssertEqual(result.action, .created)
    }

    func testInstallNoopOnlyWhenBothWired() throws {
        try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        let result = try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        XCTAssertEqual(result.action, .noop)
        XCTAssertEqual(result.events, ["PermissionRequest": .noop, "PreToolUse": .noop])
    }

    func testInstallAddsPreToolUseToPermissionRequestOnlyFile() throws {
        // The SHIPPED state: only PermissionRequest wired. Re-install ADDS
        // PreToolUse without disturbing PermissionRequest.
        let cmd = ClaudeSettingsInstaller.recommendedHookCommand(helperPath: "/h")
        let seed: [String: Any] = ["hooks": ["PermissionRequest": [
            ["matcher": "", "hooks": [["type": "command", "command": cmd]]]]]]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        XCTAssertEqual(result.events, ["PermissionRequest": .noop, "PreToolUse": .added])
        XCTAssertEqual(result.action, .added)
        XCTAssertNotNil(canonicalCmd(try read(), event: "PreToolUse"))
    }

    func testInstallPreviousCommandFromReplacedEventNotNoop() throws {
        // PermissionRequest current (noop) + PreToolUse stale → aggregate
        // .replaced, previousCommand = the STALE PreToolUse command.
        let current = ClaudeSettingsInstaller.recommendedHookCommand(helperPath: "/h")
        let stale = "/old/cli_pulse_helper remote-approval-hook --provider claude"
        let seed: [String: Any] = ["hooks": [
            "PermissionRequest": [["matcher": "", "hooks": [["type": "command", "command": current]]]],
            "PreToolUse": [["matcher": "", "hooks": [["type": "command", "command": stale]]]]]]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        XCTAssertEqual(result.action, .replaced)
        XCTAssertEqual(result.previousCommand, stale)
    }

    func testUninstallRemovesBothEvents() throws {
        try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath)
        XCTAssertEqual(result.action, "removed")
        XCTAssertEqual(result.removed, 2)
        let data = try read()
        let hooks = data["hooks"] as? [String: Any] ?? [:]
        XCTAssertNil(hooks["PermissionRequest"])
        XCTAssertNil(hooks["PreToolUse"])
    }

    func testUninstallNoopWhenNothingInstalled() throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["model": "opus"]).write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath)
        XCTAssertEqual(result.action, "noop")
        XCTAssertEqual(try read()["model"] as? String, "opus")
    }

    func testUninstallNoopWhenFileMissing() throws {
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath)
        XCTAssertEqual(result.action, "noop")
        XCTAssertEqual(result.removed, 0)
    }

    func testUninstallPreservesUserHooks() throws {
        // Our hook co-resident with a user hook in the SAME PreToolUse matcher
        // entry, plus a standalone user PermissionRequest hook — both survive.
        let cmd = ClaudeSettingsInstaller.recommendedHookCommand(helperPath: "/h")
        let userHook: [String: Any] = ["type": "command", "command": "my-audit-logger"]
        let seed: [String: Any] = ["hooks": [
            "PreToolUse": [["matcher": "", "hooks": [userHook, ["type": "command", "command": cmd]]]],
            "PermissionRequest": [["matcher": "Bash", "hooks": [["type": "command", "command": "user-pr"]]]]]]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath)
        XCTAssertEqual(result.action, "removed")
        let data = try read()
        let hooks = data["hooks"] as! [String: Any]
        let ptu = hooks["PreToolUse"] as! [[String: Any]]
        // our hook stripped, user's audit hook preserved
        let nested = ptu[0]["hooks"] as! [[String: Any]]
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0]["command"] as? String, "my-audit-logger")
        // user's own PermissionRequest hook untouched
        XCTAssertNotNil(hooks["PermissionRequest"])
    }

    func testUninstallRefusesMalformedJSON() throws {
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{not json".data(using: .utf8)!.write(to: settingsPath)
        XCTAssertThrowsError(try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath))
    }

    func testInstallPreservesNonObjectArrayElements() throws {
        // A hooks array with a NON-object element (Python treats as list[Any]).
        // Install must preserve it verbatim, not clobber the whole array
        // (review: codex P1).
        let seed: [String: Any] = ["hooks": ["PermissionRequest": [
            "weird-string-element",
            ["matcher": "Bash", "hooks": [["type": "command", "command": "user-hook"]]]]]]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        let data = try read()
        let pr = (data["hooks"] as! [String: Any])["PermissionRequest"] as! [Any]
        XCTAssertTrue(pr.contains { ($0 as? String) == "weird-string-element" },
                      "non-object user element must survive install")
        // our canonical entry is also present
        XCTAssertTrue(pr.contains { ClaudeSettingsInstaller.matcherEntryHasOurHook(($0 as? [String: Any]) ?? [:]) })
    }

    func testUninstallDetectsHookInHeterogeneousNestedArray() throws {
        // Our hook co-resident with a non-object element in the nested `hooks`
        // array — must still be detected + removed, non-object preserved.
        let cmd = ClaudeSettingsInstaller.recommendedHookCommand(helperPath: "/h")
        let seed: [String: Any] = ["hooks": ["PreToolUse": [
            ["matcher": "", "hooks": [42, ["type": "command", "command": cmd]]]]]]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: seed).write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath)
        XCTAssertEqual(result.action, "removed")
        XCTAssertEqual(result.removed, 1)
        let ptu = (try read()["hooks"] as! [String: Any])["PreToolUse"] as! [Any]
        let nested = (ptu[0] as! [String: Any])["hooks"] as! [Any]
        XCTAssertEqual(nested.count, 1)
        XCTAssertEqual(nested[0] as? Int, 42)  // non-object preserved, our hook gone
    }

    func testInstallEmptyObjectFileReportsCreated() throws {
        // A `{}` file has bytes but is an empty object → .created (matches Python
        // bool(data)), not .added (review: codex P2).
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{}".data(using: .utf8)!.write(to: settingsPath)
        let result = try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        XCTAssertEqual(result.action, .created)
    }

    func testInstallUninstallRoundTripRestoresUserContent() throws {
        let original: [String: Any] = ["model": "opus", "hooks": ["Stop": [
            ["matcher": "", "hooks": [["type": "command", "command": "notify"]]]]]]
        try FileManager.default.createDirectory(
            at: settingsPath.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: original).write(to: settingsPath)
        try ClaudeSettingsInstaller.install(helperPath: "/h", settingsPath: settingsPath)
        try ClaudeSettingsInstaller.uninstall(settingsPath: settingsPath)
        let data = try read()
        XCTAssertEqual(data["model"] as? String, "opus")
        let hooks = data["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["Stop"])
        XCTAssertNil(hooks["PreToolUse"])
        XCTAssertNil(hooks["PermissionRequest"])
    }
}
