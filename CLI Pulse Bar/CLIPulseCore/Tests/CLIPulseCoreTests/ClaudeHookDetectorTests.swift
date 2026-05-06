import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Tests for `ClaudeHookDetector` — the Swift-side reader of
/// `~/.claude/settings.json` used to surface the "approval hook not
/// wired" banner in the Sessions tab.
///
/// The detector is read-only — actual mutation lives on the helper
/// Python side (`permissions_diagnose.install_claude_hook` with its
/// own test suite in `helper/test_permissions_diagnose.py`).
/// These tests verify the four states (`wired` / `notWired` /
/// `settingsMissing` / `parseError`) against tmp-dir fixtures so no
/// real `~/.claude/settings.json` is touched.
final class ClaudeHookDetectorTests: XCTestCase {

    private func tmpSettingsURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudeHookDetectorTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    func testReturnsSettingsMissingWhenFileAbsent() {
        let url = tmpSettingsURL()
        // Don't create it.
        XCTAssertEqual(ClaudeHookDetector.currentStatus(at: url), .settingsMissing)
    }

    func testReturnsNotWiredWhenHooksKeyMissing() throws {
        let url = tmpSettingsURL()
        let json = #"""
        {
          "permissions": { "allow": ["Bash(npm test:*)"] }
        }
        """#
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHookDetector.currentStatus(at: url), .notWired)
    }

    func testReturnsNotWiredWhenPermissionRequestArrayEmpty() throws {
        let url = tmpSettingsURL()
        let json = #"""
        {
          "hooks": { "PermissionRequest": [] }
        }
        """#
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHookDetector.currentStatus(at: url), .notWired)
    }

    func testReturnsNotWiredWhenOtherPermissionRequestHooksOnly() throws {
        let url = tmpSettingsURL()
        let json = #"""
        {
          "hooks": {
            "PermissionRequest": [
              { "type": "command", "command": "/usr/local/bin/audit-hook" }
            ]
          }
        }
        """#
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHookDetector.currentStatus(at: url), .notWired)
    }

    func testReturnsWiredWhenCliPulseHookPresent() throws {
        let url = tmpSettingsURL()
        let json = #"""
        {
          "hooks": {
            "PermissionRequest": [
              {
                "type": "command",
                "command": "python3 /path/to/cli_pulse_helper.py remote-approval-hook --provider claude"
              }
            ]
          }
        }
        """#
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHookDetector.currentStatus(at: url), .wired)
    }

    func testReturnsWiredWhenCliPulseHookCoexistsWithOtherHooks() throws {
        let url = tmpSettingsURL()
        let json = #"""
        {
          "hooks": {
            "PermissionRequest": [
              { "type": "command", "command": "/usr/local/bin/audit-hook" },
              {
                "type": "command",
                "command": "python3 /Users/me/repo/helper/cli_pulse_helper.py remote-approval-hook --provider claude"
              }
            ]
          }
        }
        """#
        try json.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ClaudeHookDetector.currentStatus(at: url), .wired)
    }

    func testReturnsParseErrorOnInvalidJSON() throws {
        let url = tmpSettingsURL()
        try "{ not valid json".write(to: url, atomically: true, encoding: .utf8)
        if case .parseError = ClaudeHookDetector.currentStatus(at: url) {
            // ok
        } else {
            XCTFail("expected .parseError for invalid JSON")
        }
    }

    func testReturnsParseErrorOnNonObjectRoot() throws {
        let url = tmpSettingsURL()
        try #"["array", "not", "object"]"#.write(to: url, atomically: true, encoding: .utf8)
        if case .parseError = ClaudeHookDetector.currentStatus(at: url) {
            // ok
        } else {
            XCTFail("expected .parseError for non-object root")
        }
    }

    func testHelperHookMarkerStableContract() {
        // Marker pinned: the Python helper's `install_claude_hook`
        // matches on this exact substring (helper test
        // `test_install_claude_hook_replaces_stale_entry` pins
        // identical detection logic on the helper side). The two
        // halves can NEVER drift — keep this assertion simple +
        // strong enough that any future refactor breaks both
        // suites at once.
        XCTAssertEqual(
            ClaudeHookDetector.helperHookMarker,
            "remote-approval-hook --provider claude"
        )
    }

    func testInstallCommandTemplateNonEmpty() {
        // The Sessions banner copies this onto the clipboard. If
        // it ever turns into an empty string the user clicks "Copy
        // command" and gets nothing — pin the contract so tests
        // catch that.
        XCTAssertFalse(ClaudeHookDetector.installCommandTemplate.isEmpty)
        XCTAssertTrue(
            ClaudeHookDetector.installCommandTemplate.contains("install-claude-hook"),
            "install command must invoke the install-claude-hook subcommand"
        )
    }
}

#endif
