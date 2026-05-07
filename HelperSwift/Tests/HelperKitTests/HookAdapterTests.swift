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

    // MARK: - P1③.B redaction (full Python parity)

    func testRedactStripsAnthropicSkAnt() {
        let s = "API_KEY=sk-ant-abcdefghijklmnopq"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("abcdefghijklmnopq"))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func testRedactStripsGithubToken() {
        let s = "git push https://x:ghp_abcdefghijklmnopqrstuvwxyz0123@github.com/foo/bar"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("ghp_abcdef"))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func testRedactStripsGithubPat() {
        let s = "AUTH=github_pat_11ABC1234567890123456_abcdefghij"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("github_pat_11ABC"))
    }

    func testRedactStripsGoogleApiKey() {
        let s = "GMAPS=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ-abc"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("AIzaSyABCDEFG"))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func testRedactStripsAwsAccessKey() {
        let s = "AKIAIOSFODNN7EXAMPLE plus other text"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("AKIAIOSFODNN7"))
    }

    func testRedactStripsBearer() {
        let s = "Authorization: Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("eyJhbGciOiJSUzI1Ni"))
    }

    func testRedactStripsJwt() {
        let s = "Refreshing token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("eyJhbGciOiJIUz"))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func testRedactStripsLongHex() {
        let s = "helper_secret_hash_for_review = 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("0123456789abcdef0123"))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func testRedactStripsAuthorizationHeader() {
        let s = #"curl -H "Authorization: Basic dXNlcjpwYXNz" https://example.com"#
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("Basic dXNlcjpwYXNz"))
        XCTAssertTrue(red.contains("Authorization:"),
                       "key prefix preserved so user knows what was scrubbed")
    }

    func testRedactStripsCookieHeader() {
        let s = #"--header "Cookie: session=abc123; foo=bar""#
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("session=abc123"))
    }

    func testRedactStripsXApiKeyHeader() {
        let s = #"-H 'X-API-Key: my-secret-key-xyz'"#
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("my-secret-key-xyz"))
    }

    func testRedactStripsAccessTokenJson() {
        let s = #"{"access_token":"abc123xyz","ok":true}"#
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("abc123xyz"))
    }

    func testRedactStripsClientSecretShellArg() {
        let s = "curl --data 'client_secret=topsecretvalue123'"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("topsecretvalue123"))
    }

    func testRedactStripsAllCapsEnvKey() {
        let s = "GITHUB_TOKEN=ghp_realtokenvaluewouldbehere bar=baz"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("ghp_realtokenvalue"))
        XCTAssertFalse(red.contains("realtokenvalue"))
    }

    func testRedactStripsPassword() {
        let s = "psql --password=hunter2 --user=foo"
        let red = HookAdapter.redact(s)
        XCTAssertFalse(red.contains("hunter2"))
    }

    func testRedactDoesNotMatchOnNonSensitiveLongString() {
        // Long lower-case ascii like a project name should NOT
        // be redacted (only the long-hex pattern triggers).
        let s = "CLIPulseHelperFrameworkInternalLogicallyValidLongIdentifier"
        let red = HookAdapter.redact(s)
        XCTAssertEqual(red, s, "non-token long strings must survive verbatim")
    }

    func testRedactIdempotent() {
        let s = "Bearer eyJabc.eyJxyz.eyJqwe AKIAIOSFODNN7EXAMPLE"
        let once = HookAdapter.redact(s)
        let twice = HookAdapter.redact(once)
        XCTAssertEqual(once, twice, "redact must be idempotent")
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
        // P1③.A revert: missing CLI_PULSE_LOCAL_* env vars now
        // means run() emits `behavior: deny` with a diagnostic
        // message — NOT `behavior: allow`. The latter would
        // auto-approve every Bash/Read/Write etc. on terminal-
        // launched Claude. Phase 4D iter10 stops global hook
        // install entirely; this branch is now reachable only
        // on misconfiguration / leftover stale hook entries.
        let parsed = HookAdapter.ClaudeHookInput(
            toolName: "Bash",
            toolInput: [:],
            summary: "$ x",
            cwdBasename: "tmp",
            risk: "medium"
        )
        let outcome = HookAdapter.tryLocalUdsHook(parsed: parsed)
        XCTAssertNil(outcome,
                     "missing env vars must return nil so run() can fail-closed")
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
        XCTAssertTrue(cmd.contains("«REDACTED»"))
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
