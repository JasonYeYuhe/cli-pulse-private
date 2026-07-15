import XCTest
@testable import HelperKit
import Foundation

/// Remote (Supabase) approval arm — Swift twin of the remote-arm behaviors
/// pinned in `helper/test_remote_hook.py`. The arm is what lets an EXTERNAL
/// (hand-launched) claude/codex session reach CLI Pulse approve/deny at all:
/// `remote_helper_create_permission_request` then a
/// `remote_helper_poll_permission_decision` loop.
final class HookAdapterRemoteApprovalTests: XCTestCase {

    /// Scripted RPC transport. Records every (name, params) call; each
    /// invocation pops the next scripted result (last one repeats).
    final class MockRPC: RPCCallable, @unchecked Sendable {
        struct Call { let name: String; let params: [String: Any] }
        private let lock = NSLock()
        private var script: [Result<Any, Error>]
        private(set) var calls: [Call] = []

        init(_ script: [Result<Any, Error>]) { self.script = script }

        func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
            lock.lock()
            calls.append(Call(name: rpcName, params: params))
            let result = script.count > 1 ? script.removeFirst() : script[0]
            lock.unlock()
            switch result {
            case .success(let v): return v
            case .failure(let e): throw e
            }
        }

        var recorded: [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    private func parsedInput(
        risk: String = "medium", event: String = "PreToolUse", sessionId: String = ""
    ) -> HookAdapter.ClaudeHookInput {
        HookAdapter.ClaudeHookInput(
            toolName: "Bash",
            toolInput: ["command": "ls -la"],
            summary: "$ ls -la",
            cwdBasename: "proj",
            risk: risk,
            eventName: event,
            sessionId: sessionId
        )
    }

    /// Tiny budget + no real sleeping so poll-loop tests run in milliseconds.
    private func fastConfig(timeoutS: Double = 0.5) -> HookAdapter.RemoteApprovalConfig {
        var cfg = HookAdapter.RemoteApprovalConfig()
        cfg.timeoutS = timeoutS
        cfg.pollIntervalS = 0.0
        cfg.requestTimeoutS = 2.5
        cfg.ttlSeconds = 60
        return cfg
    }

    private let pairing = (deviceId: "11111111-2222-3333-4444-555555555555",
                           helperSecret: "sekret")

    // MARK: - create-request param dict (test_remote_hook.py create-param pins)

    func testCreateParamsCarryFullContract() {
        let rpc = MockRPC([
            .success(["request_id": "x", "status": "pending"]),
            .success(["status": "approved", "decision": "approved", "scope": "once"]),
        ])
        _ = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "codex", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })

        let create = rpc.recorded[0]
        XCTAssertEqual(create.name, "remote_helper_create_permission_request")
        XCTAssertEqual(create.params["p_device_id"] as? String, pairing.deviceId)
        XCTAssertEqual(create.params["p_helper_secret"] as? String, pairing.helperSecret)
        XCTAssertEqual(create.params["p_provider"] as? String, "codex")
        XCTAssertEqual(create.params["p_tool_name"] as? String, "Bash")
        XCTAssertEqual(create.params["p_summary"] as? String, "$ ls -la")
        XCTAssertEqual(create.params["p_risk"] as? String, "medium")
        XCTAssertEqual(create.params["p_ttl_seconds"] as? Int, 60)
        // request id is a fresh lowercase UUID…
        let reqId = create.params["p_request_id"] as? String ?? ""
        XCTAssertNotNil(UUID(uuidString: reqId))
        XCTAssertEqual(reqId, reqId.lowercased())
        // p_payload is the EXACT Python shape: {tool_name, tool_input (redacted),
        // permission_suggestions_count} — NOT the bare redacted input dict.
        let payload = create.params["p_payload"] as? [String: Any]
        XCTAssertEqual(payload?["tool_name"] as? String, "Bash")
        XCTAssertEqual(payload?["permission_suggestions_count"] as? Int, 0)
        let toolInput = payload?["tool_input"] as? [String: Any]
        XCTAssertEqual(toolInput?["command"] as? String, "ls -la")
        // …and the SAME request id rides every poll (idempotency key).
        let poll = rpc.recorded[1]
        XCTAssertEqual(poll.name, "remote_helper_poll_permission_decision")
        XCTAssertEqual(poll.params["p_request_id"] as? String, reqId)
        XCTAssertEqual(poll.params["p_device_id"] as? String, pairing.deviceId)
    }

    func testSessionIdBindingPrefersEnvUUIDThenRawThenNull() {
        // 1) env UUID wins over the provider's raw session id
        let envUUID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        setenv("CLI_PULSE_REMOTE_SESSION_ID", envUUID, 1)
        defer { unsetenv("CLI_PULSE_REMOTE_SESSION_ID") }
        XCTAssertEqual(
            HookAdapter.resolveManagedSessionId(rawSessionId: "99999999-8888-7777-6666-555555555555"),
            envUUID)
        // 2) malformed env → fall back to raw (if UUID)
        setenv("CLI_PULSE_REMOTE_SESSION_ID", "not-a-uuid", 1)
        XCTAssertEqual(
            HookAdapter.resolveManagedSessionId(rawSessionId: "99999999-8888-7777-6666-555555555555"),
            "99999999-8888-7777-6666-555555555555")
        // 3) both invalid → nil (server accepts an unbound request)
        XCTAssertNil(HookAdapter.resolveManagedSessionId(rawSessionId: "sess-1"))
        unsetenv("CLI_PULSE_REMOTE_SESSION_ID")
        // 4) no env → raw
        XCTAssertNil(HookAdapter.resolveManagedSessionId(rawSessionId: ""))
    }

    func testCreateParamsSessionIdNullWhenUnresolvable() {
        unsetenv("CLI_PULSE_REMOTE_SESSION_ID")
        let rpc = MockRPC([
            .success(["request_id": "x", "status": "pending"]),
            .success(["status": "approved"]),
        ])
        _ = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(sessionId: "non-uuid-session"), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
        XCTAssertTrue(rpc.recorded[0].params["p_session_id"] is NSNull)
    }

    // MARK: - decision mapping (approve/deny round-trips)

    func testApprovedMapsToAllowWithoutMessage() {
        let rpc = MockRPC([
            .success(["request_id": "x", "status": "pending"]),
            .success(["status": "approved", "decision": "approved", "scope": "always"]),
        ])
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
        XCTAssertEqual(d.behavior, .allow)
        // allow must NOT carry a message (docs: message is for deny only) and
        // scope is force-downgraded to once — nothing else to emit.
        XCTAssertNil(d.message)
    }

    func testDeniedMapsToDenyWithDefaultMessage() {
        let rpc = MockRPC([
            .success(["request_id": "x", "status": "pending"]),
            .success(["status": "denied", "decision": "denied"]),
        ])
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
        XCTAssertEqual(d.behavior, .deny)
        // nil message → emit supplies "Denied remotely via CLI Pulse".
        XCTAssertNil(d.message)
        let out = HookAdapter.preToolUseOutput(d, failOpen: true, provider: "claude")!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecisionReason"] as? String, "Denied remotely via CLI Pulse")
    }

    // MARK: - timeout / expiry / errors → fallback (never allow, never hang)

    func testPendingForeverTimesOutToFallback() {
        var sleeps = 0
        let rpc = MockRPC([
            .success(["request_id": "x", "status": "pending"]),
            .success(["status": "pending"]),
        ])
        // Fake clock: starts at 0, each now() call advances 0.1s.
        var clock = 0.0
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(timeoutS: 0.35),
            now: { clock += 0.1; return clock },
            sleeper: { _ in sleeps += 1 })
        XCTAssertEqual(d.behavior, .fallback)
        XCTAssertEqual(d.message, HookAdapter.remoteTimedOutMessage)
        XCTAssertGreaterThanOrEqual(sleeps, 1, "poll loop must sleep between polls")
        XCTAssertGreaterThanOrEqual(rpc.recorded.count, 2, "create + at least one poll")
    }

    func testExpiredAndNotFoundMapToTimeoutFallback() {
        for terminal in ["expired", "not_found"] {
            let rpc = MockRPC([
                .success(["request_id": "x", "status": "pending"]),
                .success(["status": terminal]),
            ])
            let d = HookAdapter.tryRemoteApproval(
                parsed: parsedInput(), provider: "claude", rpc: rpc,
                pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
            XCTAssertEqual(d.behavior, .fallback, terminal)
            XCTAssertEqual(d.message, HookAdapter.remoteTimedOutMessage, terminal)
        }
    }

    func testCreateFailureFallsBackWithoutPolling() {
        let rpc = MockRPC([.failure(SupabaseRPCError.transport("boom"))])
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
        XCTAssertEqual(d.behavior, .fallback)
        XCTAssertEqual(d.message, HookAdapter.remoteUnavailableMessage)
        XCTAssertEqual(rpc.recorded.count, 1, "no poll after a failed create")
    }

    func testPollErrorFallsBack() {
        let rpc = MockRPC([
            .success(["request_id": "x", "status": "pending"]),
            .failure(SupabaseRPCError.http(status: 401, body: "Device not found or unauthorized")),
        ])
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
        XCTAssertEqual(d.behavior, .fallback)
        XCTAssertEqual(d.message, HookAdapter.remoteUnavailableMessage)
    }

    func testRemoteArmNeverAutoApprovesOnFailure() {
        // Safety invariant sweep: every non-decision path yields .fallback —
        // which emit() NEVER resolves to allow (pinned in HookAdapterTests).
        let scripts: [[Result<Any, Error>]] = [
            [.failure(SupabaseRPCError.notConfigured)],
            [.success(["request_id": "x"]), .failure(SupabaseRPCError.transport("net"))],
            [.success(["request_id": "x"]), .success(["status": "expired"])],
            [.success(["request_id": "x"]), .success(NSNull())],  // garbled reply → poll on, then budget out
        ]
        for (idx, script) in scripts.enumerated() {
            var clock = 0.0
            let d = HookAdapter.tryRemoteApproval(
                parsed: parsedInput(), provider: "codex", rpc: MockRPC(script),
                pairingOverride: pairing, config: fastConfig(timeoutS: 0.3),
                now: { clock += 0.1; return clock }, sleeper: { _ in })
            XCTAssertNotEqual(d.behavior, .allow, "script \(idx) must not auto-approve")
        }
    }

    // MARK: - end-to-end fallback resolution (external vs managed)

    func testExternalCodexRemoteFailureAbstains() {
        // External codex + remote arm down → .fallback resolves to ABSTAIN
        // (nil output) for PreToolUse — never "ask", never deny.
        let rpc = MockRPC([.failure(SupabaseRPCError.transport("down"))])
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "codex", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(), sleeper: { _ in })
        XCTAssertNil(HookAdapter.preToolUseOutput(d, failOpen: true, provider: "codex"))
    }

    func testExternalClaudeRemoteTimeoutAsks() {
        let rpc = MockRPC([
            .success(["request_id": "x"]),
            .success(["status": "pending"]),
        ])
        var clock = 0.0
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(timeoutS: 0.3),
            now: { clock += 0.1; return clock }, sleeper: { _ in })
        let out = HookAdapter.preToolUseOutput(d, failOpen: true, provider: "claude")!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "ask")
    }

    func testManagedRemoteTimeoutDeniesWithMessage() {
        let rpc = MockRPC([
            .success(["request_id": "x"]),
            .success(["status": "pending"]),
        ])
        var clock = 0.0
        let d = HookAdapter.tryRemoteApproval(
            parsed: parsedInput(), provider: "claude", rpc: rpc,
            pairingOverride: pairing, config: fastConfig(timeoutS: 0.3),
            now: { clock += 0.1; return clock }, sleeper: { _ in })
        let out = HookAdapter.preToolUseOutput(d, failOpen: false, provider: "claude")!
        let hso = out["hookSpecificOutput"] as! [String: Any]
        XCTAssertEqual(hso["permissionDecision"] as? String, "deny")
        XCTAssertEqual(hso["permissionDecisionReason"] as? String,
                       HookAdapter.remoteTimedOutMessage)
    }
}
