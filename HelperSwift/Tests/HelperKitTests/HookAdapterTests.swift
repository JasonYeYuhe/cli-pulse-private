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
        // No CLI_PULSE_LOCAL_* env vars set → tryLocalUdsHook
        // returns nil → run() emits `behavior: allow` (fail-open
        // path; lets non-managed terminal Claude sessions
        // continue using their settings.json rules).
        let parsed = HookAdapter.ClaudeHookInput(
            toolName: "Bash",
            toolInput: [:],
            summary: "$ x",
            cwdBasename: "tmp",
            risk: "medium"
        )
        let outcome = HookAdapter.tryLocalUdsHook(parsed: parsed)
        XCTAssertNil(outcome,
                     "missing env vars must return nil so run() can fail-open")
    }

    // MARK: - Codex P1.B redaction

    func testRedactedToolInputStripsApiKeyFromString() {
        let raw: [String: Any] = [
            "command": "curl https://api.example.com/?api_key=sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ123456",
            "description": "fetch with key",
        ]
        let out = HookAdapter.redactedToolInput(raw)
        let cmd = out["command"] as? String ?? ""
        XCTAssertFalse(cmd.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ"),
                       "api key must be stripped from redacted command")
        XCTAssertTrue(cmd.contains("sk-…"))
    }

    func testRedactedToolInputTruncatesLongStrings() {
        let huge = String(repeating: "x", count: 5000)
        let out = HookAdapter.redactedToolInput(["payload": huge])
        let s = out["payload"] as? String ?? ""
        XCTAssertLessThanOrEqual(s.count, 1024,
                                  "string fields must be truncated to 1024 chars")
    }

    func testRedactedToolInputCollapsesNestedStructures() {
        // Nested dict / array are flattened to length hints.
        // Preserves payload size + avoids exposing full sub-tree.
        let raw: [String: Any] = [
            "stack": ["a", "b", "c", "d"],
            "config": ["secret": "do not include", "x": 1],
        ]
        let out = HookAdapter.redactedToolInput(raw)
        XCTAssertEqual(out["stack"] as? String, "<list len=4>")
        XCTAssertEqual(out["config"] as? String, "<dict len=2>")
    }

    func testRedactedToolInputDropsUnderscoreKeys() {
        let raw: [String: Any] = [
            "command": "ls",
            "_internal": "should not leak",
        ]
        let out = HookAdapter.redactedToolInput(raw)
        XCTAssertNil(out["_internal"])
        XCTAssertEqual(out["command"] as? String, "ls")
    }

    func testRedactedToolInputPreservesScalars() {
        let raw: [String: Any] = [
            "count": 42,
            "ratio": 1.5,
            "ok": true,
        ]
        let out = HookAdapter.redactedToolInput(raw)
        XCTAssertEqual(out["count"] as? Int, 42)
        XCTAssertEqual(out["ratio"] as? Double, 1.5)
        XCTAssertEqual(out["ok"] as? Bool, true)
    }

    // MARK: - Codex P1.A fail-open semantics

    /// The `run()` function emits a JSON decision to stdout. We
    /// can't easily capture stdout in a unit test without a fork,
    /// but we CAN pin the in-memory Decision branches by checking
    /// `tryLocalUdsHook(parsed:)` returns:
    ///   * nil when env vars missing (run emits allow)
    ///   * Decision(deny) when env vars present but UDS broken
    func testTryLocalUdsHookDenyWhenManagedSessionButSocketMissing() {
        // Set env vars to a guaranteed-missing socket path.
        let bogusSocket = "/tmp/clipulse-helper-does-not-exist-\(UUID().uuidString).sock"
        setenv("CLI_PULSE_LOCAL_HELPER_SOCK", bogusSocket, 1)
        setenv("CLI_PULSE_LOCAL_SESSION_ID", "FAKE-SID", 1)
        setenv("CLI_PULSE_LOCAL_HOOK_TOKEN", "FAKE-TOKEN", 1)
        defer {
            unsetenv("CLI_PULSE_LOCAL_HELPER_SOCK")
            unsetenv("CLI_PULSE_LOCAL_SESSION_ID")
            unsetenv("CLI_PULSE_LOCAL_HOOK_TOKEN")
        }
        let parsed = HookAdapter.ClaudeHookInput(
            toolName: "Bash",
            toolInput: [:],
            summary: "$ x",
            cwdBasename: "tmp",
            risk: "medium"
        )
        let outcome = HookAdapter.tryLocalUdsHook(parsed: parsed)
        guard let decision = outcome else {
            XCTFail("env vars present but socket missing → must return Decision(deny), not nil")
            return
        }
        XCTAssertEqual(decision.behavior, .deny,
                       "managed session with broken helper must fail CLOSED")
        XCTAssertNotNil(decision.message)
        XCTAssertTrue((decision.message ?? "").contains("CLI Pulse helper"),
                      "deny message must explain the helper is unreachable")
    }
}
