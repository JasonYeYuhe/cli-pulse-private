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
}
