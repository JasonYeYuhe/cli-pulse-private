import XCTest
@testable import HelperKit
import Foundation

/// Unit-level tests for the HookAdapter parser + redaction +
/// summary generation. End-to-end UDS round-trip is covered by
/// the `remote_hook` smoke test in the Python suite (and gets a
/// real-binary version in iter 10's e2e parity step).
final class HookAdapterTests: XCTestCase {

    func testParseClaudeHookInputBashSummary() {
        let json = #"""
        {
          "tool_name": "Bash",
          "tool_input": {"command": "ls -la /etc/hosts"},
          "session_id": "S",
          "cwd": "/Users/me/projects/cli pulse"
        }
        """#
        let parsed = HookAdapter.parseClaudeHookInput(Data(json.utf8))
        XCTAssertEqual(parsed.toolName, "Bash")
        XCTAssertEqual(parsed.summary, "$ ls -la /etc/hosts")
        XCTAssertEqual(parsed.cwdBasename, "cli pulse")
        XCTAssertEqual(parsed.risk, "medium")
    }

    func testParseClaudeHookInputBashHighRisk() {
        let json = #"""
        {"tool_name":"Bash","tool_input":{"command":"sudo rm -rf /tmp/xx"}}
        """#
        let parsed = HookAdapter.parseClaudeHookInput(Data(json.utf8))
        XCTAssertEqual(parsed.risk, "high",
                       "rm -rf must classify as high risk")
    }

    func testParseClaudeHookInputReadLowRisk() {
        let json = #"""
        {"tool_name":"Read","tool_input":{"file_path":"/Users/me/.config/file"}}
        """#
        let parsed = HookAdapter.parseClaudeHookInput(Data(json.utf8))
        XCTAssertEqual(parsed.risk, "low")
        XCTAssertEqual(parsed.summary, "Read file")
    }

    func testRedactStripsApiKey() {
        let s = "API_KEY=sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"))
        XCTAssertTrue(red.contains("sk-…"))
    }

    func testRedactStripsBearer() {
        let s = "Authorization: Bearer eyJhbGciOiJSUzI1NiIs"
        let red = HookAdapter.redact(s)
        XCTAssertTrue(red.contains("Bearer …"))
        XCTAssertFalse(red.contains("eyJhbGci"))
    }

    func testRedactStripsPassword() {
        let s = "psql --password=hunter2 --user=foo"
        let red = HookAdapter.redact(s)
        XCTAssertTrue(red.contains("password=…"))
        XCTAssertFalse(red.contains("hunter2"))
    }

    func testTruncateRespectsLimit() {
        let s = String(repeating: "x", count: 1000)
        let t = HookAdapter.truncate(s, limit: 256)
        XCTAssertEqual(t.count, 256)
        XCTAssertTrue(t.hasSuffix("…"))
    }

    func testClassifyRiskHighRiskShellTokens() {
        XCTAssertEqual(
            HookAdapter.classifyRisk(
                toolName: "Bash",
                toolInput: ["command": "shutdown -h now"]
            ),
            "high"
        )
    }

    func testTryLocalUdsHookNoEnvReturnsNil() {
        // No CLI_PULSE_LOCAL_* env vars set → caller falls back
        // to "Remote approval unavailable" deny. Pin the
        // shortcut behaviour.
        let parsed = HookAdapter.ClaudeHookInput(
            toolName: "Bash",
            toolInput: [:],
            summary: "$ x",
            cwdBasename: "tmp",
            risk: "medium"
        )
        // Run with the env vars unset (this test process won't
        // have the helper-spawn env). Expect nil.
        let outcome = HookAdapter.tryLocalUdsHook(parsed: parsed)
        XCTAssertNil(outcome,
                     "missing env vars must cause local UDS path to be skipped (caller emits fallback)")
    }
}
