import XCTest
@testable import HelperKit
import Foundation

/// Phase 4D iter10 (Codex P1③.A): managed sessions inject the
/// PermissionRequest hook at spawn time via `claude --settings
/// <inline-json>` instead of writing the hook into the user's
/// `~/.claude/settings.json`. These tests pin the inline-JSON
/// shape Claude Code's `--settings` flag consumes so terminal-
/// launched Claude users never see CLI Pulse's hook by accident.
final class ManagedSessionInjectionTests: XCTestCase {

    func testInlineSettingsContainsCanonicalHookEntry() throws {
        let helperPath = "/Applications/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper"
        let json = ManagedSessionManager.buildInlineSettingsForManagedSession(
            helperPath: helperPath
        )
        XCTAssertNotNil(json)
        let parsed = try JSONSerialization.jsonObject(with: Data(json!.utf8)) as! [String: Any]
        let hooks = parsed["hooks"] as? [String: Any]
        let pr = hooks?["PermissionRequest"] as? [[String: Any]]
        XCTAssertEqual(pr?.count, 1)
        XCTAssertEqual(pr?.first?["matcher"] as? String, "",
                        "matcher must be canonical empty (match all PermissionRequest events)")
        let nested = pr?.first?["hooks"] as? [[String: Any]]
        XCTAssertEqual(nested?.count, 1)
        XCTAssertEqual(nested?.first?["type"] as? String, "command")
        // Helper path should be referenced verbatim (with proper quoting).
        let cmd = nested?.first?["command"] as? String ?? ""
        XCTAssertTrue(cmd.contains(helperPath))
        XCTAssertTrue(cmd.contains("remote-approval-hook"))
        XCTAssertTrue(cmd.contains("--provider claude"))
    }

    func testInlineSettingsHandlesPathsWithSpaces() throws {
        let helperPath = "/Users/me/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper"
        let json = ManagedSessionManager.buildInlineSettingsForManagedSession(
            helperPath: helperPath
        )
        XCTAssertNotNil(json)
        let parsed = try JSONSerialization.jsonObject(with: Data(json!.utf8)) as! [String: Any]
        let pr = (parsed["hooks"] as! [String: Any])["PermissionRequest"] as! [[String: Any]]
        let cmd = (pr.first!["hooks"] as! [[String: Any]]).first!["command"] as! String
        // Path with spaces must be single-quoted (matches
        // ClaudeSettingsInstaller.recommendedHookCommand).
        XCTAssertTrue(cmd.contains("'\(helperPath)'"),
                      "path with spaces must appear single-quoted: \(cmd)")
    }

    func testInlineSettingsIsValidJsonForClaudeSettingsFlag() throws {
        // The wire shape is what gets passed as the literal
        // argument to `claude --settings`. Round-trip parse to
        // confirm it's valid JSON Claude Code can consume.
        let json = ManagedSessionManager.buildInlineSettingsForManagedSession(
            helperPath: "/usr/local/bin/cli_pulse_helper"
        )!
        XCTAssertNoThrow(
            try JSONSerialization.jsonObject(with: Data(json.utf8))
        )
    }
}
