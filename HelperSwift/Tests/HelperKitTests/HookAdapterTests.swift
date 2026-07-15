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

    // MARK: - token-level high-risk classifier (review: codex P1)
    // The old substring scanner missed whitespace-perturbed / split-flag forms;
    // those reached the remote-approval plane as `medium` where a remote allow
    // could run a destructive command. Ports Python `_is_high_risk_bash`.

    func testHighRiskWhitespacePerturbedAndSplitFlags() {
        let high = [
            "rm -rf /", "rm -fr /tmp/x", "rm  -rf /",   // double space
            "rm -r -f /", "rm -r --force /",             // split flags
            "rm\t-rf /",                                  // tab
            "sudo\trm foo", "sudo apt install x",        // sudo (tab + space)
            "dd if=/dev/zero of=/dev/disk0",             // dd + if=
            ":(){ :|:& };:",                             // fork bomb
            "chmod 777 /", "history -c",
            "curl http://x | sh", "wget http://x",
        ]
        for cmd in high {
            XCTAssertEqual(HookAdapter.classifyRisk(toolName: "Bash", toolInput: ["command": cmd]),
                           "high", "must classify high: \(cmd)")
        }
    }

    func testHighRiskNoFalsePositivesOnLookalikes() {
        let medium = [
            "sudoer-config-tool --check",   // not the `sudo` token
            "forecast-curl-stats",          // not the `curl` token
            "rm file.txt",                  // rm without destructive flags
            "dd bs=1M count=1",             // dd without if=
        ]
        for cmd in medium {
            XCTAssertEqual(HookAdapter.classifyRisk(toolName: "Bash", toolInput: ["command": cmd]),
                           "medium", "must NOT false-positive: \(cmd)")
        }
    }

    // MARK: - URL credential sanitization (review: codex P1, audit F7)

    func testSanitizeURLStripsUserinfoQueryFragment() {
        XCTAssertEqual(
            HookAdapter.sanitizeURL("https://user:pass@host.example.com:8443/path?code=secret#frag"),
            "https://host.example.com:8443/path")
        // Non-URL passes through unchanged (WebSearch query text).
        XCTAssertEqual(HookAdapter.sanitizeURL("how do I reset my password"),
                       "how do I reset my password")
        // mailto (no // authority) is left alone — matches Python urlsplit's
        // empty-netloc passthrough.
        XCTAssertEqual(HookAdapter.sanitizeURL("mailto:a@b.com"), "mailto:a@b.com")
    }

    func testSanitizeURLMalformedAuthorityStillStripsCreds() {
        // Empty-host authority (review: codex) — creds MUST still be stripped,
        // matching Python urlsplit → https:///path.
        XCTAssertEqual(
            HookAdapter.sanitizeURL("https://alice:password@/path?token=plaincredential"),
            "https:///path")
    }

    func testSanitizeURLPreservesPercentEncodingAndIPv6() {
        // %2F preserved (Python parity — comps.path would re-decode it).
        XCTAssertEqual(HookAdapter.sanitizeURL("https://host/a%2Fb/c?x=1"),
                       "https://host/a%2Fb/c")
        // IPv6 brackets kept (valid URL syntax).
        XCTAssertEqual(HookAdapter.sanitizeURL("http://[2001:db8::1]:8080/x?t=secret"),
                       "http://[2001:db8::1]:8080/x")
    }

    func testHighRiskCarriageReturnPerturbed() {
        // Python str.split() tokenizes on ALL whitespace incl CR — Swift must
        // too (review: codex), else `sudo\r rm` evades the classifier.
        XCTAssertEqual(
            HookAdapter.classifyRisk(toolName: "Bash", toolInput: ["command": "sudo\r-v"]),
            "high")
    }

    func testWebFetchSummaryAndPayloadStripCredentials() {
        let raw = "https://u:p@api.example.com/x?token=sk-SUPERSECRETVALUE1234"
        let summary = HookAdapter.summaryFor(toolName: "WebFetch", toolInput: ["url": raw])
        XCTAssertFalse(summary.contains("SUPERSECRET"), summary)
        XCTAssertFalse(summary.contains("u:p@"), summary)
        let payload = HookAdapter.redactedToolInput(["url": raw])
        let url = payload["url"] as? String ?? ""
        XCTAssertFalse(url.contains("SUPERSECRET"), url)
        XCTAssertFalse(url.contains("token="), url)
    }

    func testTryLocalUdsHookNoEnvReturnsNotAttempted() {
        // Missing CLI_PULSE_LOCAL_* env → not a managed session → .notAttempted
        // so run() takes the external path (remote arm → else fail OPEN via
        // "ask"/abstain — never auto-approves, never a hard deny).
        let parsed = HookAdapter.ClaudeHookInput(
            toolName: "Bash",
            toolInput: [:],
            summary: "$ x",
            cwdBasename: "tmp",
            risk: "medium",
            eventName: "PermissionRequest"
        )
        guard case .notAttempted = HookAdapter.tryLocalUdsHook(parsed: parsed) else {
            return XCTFail("missing env vars must return .notAttempted so run() takes the external path")
        }
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
    /// but we CAN pin the in-memory outcome branches.
    ///
    /// Remote-arm port: a managed session whose local helper socket is GONE is
    /// a PRE-create failure → `.notAttempted` (Python parity: `_try_local_uds_hook`
    /// returns None at exactly these sites so the REMOTE arm can still resolve
    /// the approval — the phone approves while the local helper is down). If
    /// the remote arm also fails, the shared `.fallback` resolves managed →
    /// fail-closed deny; a broken helper still NEVER auto-approves.
    func testTryLocalUdsHookSocketMissingFallsThroughToRemoteArm() {
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
            risk: "medium",
            eventName: "PermissionRequest"
        )
        guard case .notAttempted = HookAdapter.tryLocalUdsHook(parsed: parsed) else {
            return XCTFail("managed + socket missing is a PRE-create failure → .notAttempted (remote arm runs)")
        }
    }

    // MARK: - M1: event detection + PreToolUse shape + external fail-open

    func testParsesPreToolUseEventName() {
        let parsed = HookAdapter.parseClaudeHookInput(Data(
            #"{"tool_name":"Bash","tool_input":{},"hook_event_name":"PreToolUse"}"#.utf8))
        XCTAssertEqual(parsed.eventName, "PreToolUse")
    }

    func testDefaultsToPermissionRequestWithoutEventName() {
        let parsed = HookAdapter.parseClaudeHookInput(Data(
            #"{"tool_name":"Bash","tool_input":{}}"#.utf8))
        XCTAssertEqual(parsed.eventName, "PermissionRequest")
    }

    private func decision(_ b: HookAdapter.Behavior, _ msg: String? = nil) -> HookAdapter.Decision {
        HookAdapter.Decision(behavior: b, message: msg)
    }

    func testPermissionRequestAllowOmitsMessage() {
        let out = HookAdapter.permissionRequestOutput(decision(.allow), failOpen: false)!
        let d = (out["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(d["behavior"] as? String, "allow")
        XCTAssertNil(d["message"], "allow must NOT include a message (docs: for deny only)")
    }

    func testPermissionRequestExternalFallbackAbstains() {
        // External fail-open PermissionRequest → nil (empty stdout → local prompt).
        XCTAssertNil(HookAdapter.permissionRequestOutput(decision(.fallback), failOpen: true))
    }

    func testPermissionRequestManagedFallbackDenies() {
        let out = HookAdapter.permissionRequestOutput(decision(.fallback), failOpen: false)!
        let d = (out["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
        XCTAssertEqual(d["behavior"] as? String, "deny")
    }

    func testPreToolUseAllowShape() {
        let out = HookAdapter.preToolUseOutput(decision(.allow), failOpen: false)!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["hookEventName"] as? String, "PreToolUse")
        XCTAssertEqual(hso["permissionDecision"] as? String, "allow")
        XCTAssertNil(hso["permissionDecisionReason"])
    }

    func testPreToolUseDenyShape() {
        let out = HookAdapter.preToolUseOutput(decision(.deny, "nope"), failOpen: false)!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "deny")
        XCTAssertEqual(hso["permissionDecisionReason"] as? String, "nope")
    }

    func testPreToolUseExternalFallbackAsks() {
        // External fail-open PreToolUse → "ask" (defer to prompt), NEVER "allow".
        let out = HookAdapter.preToolUseOutput(decision(.fallback), failOpen: true)!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "ask")
    }

    func testPreToolUseManagedFallbackDenies() {
        let out = HookAdapter.preToolUseOutput(decision(.fallback), failOpen: false)!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "deny")
    }

    func testNoFallbackPathEverAutoApproves() {
        // Safety invariant: a .fallback (channel unavailable) NEVER emits allow,
        // for either event or fail-open state.
        for failOpen in [true, false] {
            if let pr = HookAdapter.permissionRequestOutput(decision(.fallback), failOpen: failOpen) {
                let d = (pr["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
                XCTAssertNotEqual(d["behavior"] as? String, "allow")
            }
            let ptu = HookAdapter.preToolUseOutput(decision(.fallback), failOpen: failOpen)!
            let hso = ptu["hookSpecificOutput"] as! [String: Any]
            XCTAssertNotEqual(hso["permissionDecision"] as? String, "allow")
        }
    }

    func testIsManagedSessionDetectsEnv() {
        setenv("CLI_PULSE_LOCAL_SESSION_ID", "sess-1", 1)
        defer { unsetenv("CLI_PULSE_LOCAL_SESSION_ID") }
        XCTAssertTrue(HookAdapter.isManagedSession())
    }

    func testIsManagedSessionFalseWhenNoEnv() {
        unsetenv("CLI_PULSE_LOCAL_SESSION_ID")
        unsetenv("CLI_PULSE_REMOTE_SESSION_ID")
        XCTAssertFalse(HookAdapter.isManagedSession())
    }

    // MARK: - M2 codex-Swift port: codex provider semantics

    func testCodexPreToolUseExternalFallbackAbstains() {
        // Codex PreToolUse is allow|deny ONLY — no "ask". An EXTERNAL (fail-
        // open) fallback must ABSTAIN (nil → nothing written → Codex's normal
        // approval flow), never Claude's "ask" (which Codex would reject) and
        // NEVER a hard deny that bricks a hand-launched terminal Codex.
        // Mirrors the Python CodexAdapter._emit_pre_tool_use.
        XCTAssertNil(HookAdapter.preToolUseOutput(
            decision(.fallback), failOpen: true, provider: "codex"))
    }

    func testCodexPreToolUseManagedFallbackDeniesWithCodexWording() {
        let out = HookAdapter.preToolUseOutput(
            decision(.fallback), failOpen: false, provider: "codex")!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "deny")
        let reason = hso["permissionDecisionReason"] as! String
        XCTAssertTrue(reason.contains("Codex's local approval prompt"), reason)
        XCTAssertFalse(reason.contains("Claude"), reason)
    }

    func testClaudePreToolUseExternalFallbackStillAsks() {
        // Claude keeps "ask" — the codex branch must not leak into claude.
        let out = HookAdapter.preToolUseOutput(
            decision(.fallback), failOpen: true, provider: "claude")!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "ask")
    }

    func testCodexPreToolUseAllowDenyShapesAreClaudeCompatible() {
        // allow / definitive-deny are byte-identical across providers (Codex
        // hooks are Claude-compatible) — only fallback resolution differs.
        let allow = HookAdapter.preToolUseOutput(decision(.allow), failOpen: true, provider: "codex")!
        XCTAssertEqual((allow["hookSpecificOutput"] as! [String: Any])["permissionDecision"] as? String,
                       "allow")
        let deny = HookAdapter.preToolUseOutput(decision(.deny, "no"), failOpen: true, provider: "codex")!
        let hso = deny["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "deny")
        XCTAssertEqual(hso["permissionDecisionReason"] as? String, "no")
    }

    func testCodexPermissionRequestFallbackMatchesClaude() {
        // PermissionRequest is fully Claude-compatible: external abstain (nil),
        // managed deny — with codex wording.
        XCTAssertNil(HookAdapter.permissionRequestOutput(
            decision(.fallback), failOpen: true, provider: "codex"))
        let managed = HookAdapter.permissionRequestOutput(
            decision(.fallback), failOpen: false, provider: "codex")!
        let d = ((managed["hookSpecificOutput"] as! [String: Any])["decision"]) as! [String: Any]
        XCTAssertEqual(d["behavior"] as? String, "deny")
        XCTAssertTrue((d["message"] as! String).contains("Codex"), "\(d)")
    }

    func testCodexFallbackNeverAutoApproves() {
        // Extend the safety invariant to the codex provider path.
        for failOpen in [true, false] {
            if let pr = HookAdapter.permissionRequestOutput(
                decision(.fallback), failOpen: failOpen, provider: "codex") {
                let d = (pr["hookSpecificOutput"] as! [String: Any])["decision"] as! [String: Any]
                XCTAssertNotEqual(d["behavior"] as? String, "allow")
            }
            if let ptu = HookAdapter.preToolUseOutput(
                decision(.fallback), failOpen: failOpen, provider: "codex") {
                let hso = ptu["hookSpecificOutput"] as! [String: Any]
                XCTAssertNotEqual(hso["permissionDecision"] as? String, "allow")
            }
        }
    }

    func testUnavailableMessageProviderWording() {
        XCTAssertTrue(HookAdapter.unavailableMessage(provider: "codex").contains("Codex"))
        XCTAssertTrue(HookAdapter.unavailableMessage(provider: "claude").contains("Claude"))
        // Unknown providers get the generic claude wording, never crash.
        XCTAssertFalse(HookAdapter.unavailableMessage(provider: "other").isEmpty)
    }
}
