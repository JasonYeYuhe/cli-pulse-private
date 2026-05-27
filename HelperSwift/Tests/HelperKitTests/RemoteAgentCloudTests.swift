import XCTest
@testable import HelperKit

/// Phase 4E Slice 3 tests for `RemoteAgentCloud`, `EventUploader`,
/// `EventBatcher`, and `SupabaseRPCCaller`.
///
/// Mirrors the contract shape from `helper/test_remote_agent.py`
/// + `helper/test_remote_agent_submit.py`. We exercise dispatch,
/// fail-closed posture, status payload exactness, redaction, the
/// 256-event bounded queue, and the 5 s flush budget — all without
/// spawning a real `claude` binary or hitting Supabase.
final class RemoteAgentCloudTests: XCTestCase {

    // MARK: - fakes

    final class FakeRPCCaller: RPCCallable, @unchecked Sendable {
        struct Recorded {
            let name: String
            let params: [String: Any]
        }

        private let lock = NSLock()
        private(set) var calls: [Recorded] = []
        var responses: [String: (([String: Any]) -> Any)] = [:]
        var failKinds: Set<String> = []

        func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
            lock.lock()
            calls.append(Recorded(name: rpcName, params: params))
            let kind = (params["p_kind"] as? String) ?? ""
            let shouldFail = failKinds.contains(rpcName)
                || (rpcName == "remote_helper_post_event" && failKinds.contains("post_event_\(kind)"))
            let resolver = responses[rpcName]
            lock.unlock()
            if shouldFail {
                throw SupabaseRPCError.transport("simulated failure")
            }
            if let resolver {
                return resolver(params)
            }
            if rpcName == "remote_helper_pull_commands" {
                return [Any]()
            }
            return [String: Any]()
        }

        func calls(for name: String) -> [Recorded] {
            lock.lock(); defer { lock.unlock() }
            return calls.filter { $0.name == name }
        }
    }

    private static let testCloudConfig = HelperConfigStore.CloudConfig(
        deviceId: "11111111-2222-3333-4444-555555555555",
        helperSecret: "stub-secret-for-tests",
        supabaseURL: "https://example.supabase.co",
        supabaseAnonKey: "anon-key-for-tests"
    )

    private func makeUploader(
        rpc: FakeRPCCaller
    ) -> EventUploader {
        return EventUploader(
            helperConfig: { Self.testCloudConfig },
            rpcCaller: rpc
        )
    }

    private func makeCloud(
        rpc: FakeRPCCaller,
        uploader: EventUploader,
        sessionManager: ManagedSessionManager
    ) -> RemoteAgentCloud {
        return RemoteAgentCloud(
            helperConfig: { Self.testCloudConfig },
            rpcCaller: rpc,
            sessionManager: sessionManager,
            uploader: uploader,
            broker: nil
        )
    }

    // MARK: - command dispatch

    // MARK: - v1.25 Phase 4 slice 2: input_raw / resize parsers

    func test_decodeInputRawPayload_accepts_base64() {
        let bytes = Data([0x68, 0x69, 0x03, 0x0A])  // "hi" + Ctrl-C + \n
        let b64 = bytes.base64EncodedString()
        XCTAssertEqual(RemoteAgentCloud.decodeInputRawPayload(b64), bytes)
    }

    func test_decodeInputRawPayload_rejects_empty() {
        XCTAssertNil(RemoteAgentCloud.decodeInputRawPayload(""))
    }

    func test_decodeInputRawPayload_rejects_non_base64() {
        XCTAssertNil(RemoteAgentCloud.decodeInputRawPayload("not base64!!"))
    }

    func test_decodeInputRawPayload_rejects_empty_base64_decoded() {
        // "" base64 → empty Data → reject so we don't enqueue a
        // no-op write.
        // The base64 encoding of "" is also "". Above test
        // already covers; pin a defensive non-"" input that
        // decodes to empty: not possible with valid base64,
        // but a single padding char "=" rejects.
        XCTAssertNil(RemoteAgentCloud.decodeInputRawPayload("="))
    }

    func test_decodeResizePayload_accepts_standard_dims() {
        let parsed = RemoteAgentCloud.decodeResizePayload("80x24")
        XCTAssertEqual(parsed?.cols, 80)
        XCTAssertEqual(parsed?.rows, 24)
    }

    func test_decodeResizePayload_accepts_large_iPad_dims() {
        let parsed = RemoteAgentCloud.decodeResizePayload("200x60")
        XCTAssertEqual(parsed?.cols, 200)
        XCTAssertEqual(parsed?.rows, 60)
    }

    func test_decodeResizePayload_rejects_zero_dims() {
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("0x24"))
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("80x0"))
    }

    func test_decodeResizePayload_rejects_negative_dims() {
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("-1x24"))
    }

    func test_decodeResizePayload_rejects_oversize() {
        // > UInt16.max would overflow the ioctl. Defend at parse.
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("80x99999"))
    }

    func test_decodeResizePayload_rejects_missing_separator() {
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("80,24"))
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("80 24"))
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("8024"))
    }

    func test_decodeResizePayload_rejects_non_numeric() {
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("eightyx24"))
        XCTAssertNil(RemoteAgentCloud.decodeResizePayload("80xtwenty-four"))
    }

    func test_dispatch_input_raw_for_unknown_session_completes_failed() async throws {
        // Mirror test_dispatch_stop_for_unknown_session_completes_failed —
        // the helper must report failure (not silently delivered) when
        // routing input_raw to a session it doesn't own. Otherwise a
        // stale iOS row would silently consume keystrokes that never
        // reach the user's PTY.
        let cmdId = UUID().uuidString
        let bytes = Data("ls\r".utf8).base64EncodedString()
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "input_raw",
                "payload": bytes,
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.count, 1)
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
        let err = (completes.first?.params["p_error"] as? String) ?? ""
        XCTAssertTrue(err.contains("session not running"),
                      "expected 'session not running' surfaced, got: \(err)")
    }

    // MARK: - v1.26 Phase B2: tail_snapshot parser + dispatch

    func test_decodeTailSnapshotPayload_acceptsDecimal() {
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("8192"), 8192)
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("0"), 0)
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("1"), 1)
    }

    func test_decodeTailSnapshotPayload_defaultsTo8192OnEmpty() {
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload(""), 8192)
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("   "), 8192)
    }

    func test_decodeTailSnapshotPayload_defaultsTo8192OnGarbage() {
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("not a number"), 8192)
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("8192bytes"), 8192)
    }

    func test_decodeTailSnapshotPayload_clampsTo65536() {
        // Ring buffer capacity. Larger requests truncate at parse.
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("999999"), 65536)
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("65536"), 65536)
        XCTAssertEqual(RemoteAgentCloud.decodeTailSnapshotPayload("-50"), 0)
    }

    func test_dispatch_tail_snapshot_for_unknown_session_completes_failed() async throws {
        // The helper must report failure when iOS requests a
        // snapshot of a session it doesn't own (e.g. wrong device,
        // session moved). Otherwise iOS waits the full 2 s timeout
        // for a snapshot that can never arrive.
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "tail_snapshot",
                "payload": "8192",
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.count, 1)
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
        let err = (completes.first?.params["p_error"] as? String) ?? ""
        XCTAssertTrue(err.contains("session not running"),
                      "expected 'session not running' surfaced, got: \(err)")
    }

    func test_dispatch_resize_for_unknown_session_completes_failed() async throws {
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "resize",
                "payload": "80x24",
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
    }

    func test_dispatch_unknown_kind_marks_failed() async throws {
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "explode",
                "payload": "",
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.count, 1)
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
        XCTAssertTrue(((completes.first?.params["p_error"] as? String) ?? "").contains("explode"))
    }

    func test_dispatch_start_rejects_non_claude_provider() async throws {
        let cmdId = UUID().uuidString
        let sid = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": sid,
                "kind": "start",
                "payload": #"{"provider":"codex"}"#,
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
    }

    func test_dispatch_start_rejects_invalid_session_id() async throws {
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": "not-a-uuid",
                "kind": "start",
                "payload": "",
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
        XCTAssertTrue(((completes.first?.params["p_error"] as? String) ?? "").contains("invalid session_id"))
    }

    func test_dispatch_stop_for_unknown_session_completes_failed() async throws {
        // PR #18 lesson: marking `delivered` on no-op stops obscured
        // stale-row bugs. Fail-closed posture must surface unknown.
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "stop",
                "payload": "",
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
        XCTAssertTrue(((completes.first?.params["p_error"] as? String) ?? "").contains("not running"))
    }

    func test_dispatch_interrupt_for_unknown_session_completes_failed() async throws {
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "interrupt",
                "payload": "",
            ]]
        }
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        _ = await cloud.tick()

        let completes = rpc.calls(for: "remote_helper_complete_command")
        XCTAssertEqual(completes.first?.params["p_status"] as? String, "failed")
    }

    func test_pull_commands_failure_is_swallowed() async throws {
        // Gate-off path: when Remote Control is disabled the RPC
        // raises 'Device not found or unauthorized'. The daemon
        // must keep running so a re-enable resumes dispatch.
        let rpc = FakeRPCCaller()
        rpc.failKinds.insert("remote_helper_pull_commands")
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let result = await cloud.tick()

        XCTAssertEqual(result.commandsProcessed, 0)
    }

    func test_unpaired_helper_skips_pull_commands() async throws {
        let rpc = FakeRPCCaller()
        let uploader = EventUploader(
            helperConfig: {
                HelperConfigStore.CloudConfig(deviceId: "", helperSecret: "", supabaseURL: "", supabaseAnonKey: "")
            },
            rpcCaller: rpc
        )
        let cloud = RemoteAgentCloud(
            helperConfig: {
                HelperConfigStore.CloudConfig(deviceId: "", helperSecret: "", supabaseURL: "", supabaseAnonKey: "")
            },
            rpcCaller: rpc,
            sessionManager: ManagedSessionManager(transport: PtyTransport()),
            uploader: uploader,
            broker: nil
        )
        _ = await cloud.tick()
        XCTAssertEqual(rpc.calls(for: "remote_helper_pull_commands").count, 0)
    }

    // MARK: - status payload exactness

    func test_post_status_payload_must_be_exactly_stopped_or_errored() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        await cloud.postStatus(sessionId: sid, status: "stopped")
        await cloud.postStatus(sessionId: sid, status: "errored")
        await cloud.postStatus(sessionId: sid, status: "running") // refused
        _ = await uploader.pumpOnce()

        let posted = rpc.calls(for: "remote_helper_post_event")
            .filter { ($0.params["p_kind"] as? String) == "status" }
        let payloads = posted.compactMap { $0.params["p_payload"] as? String }
        XCTAssertEqual(payloads, ["stopped", "errored"])
    }

    func test_post_status_seq_starts_at_one_per_session() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        await cloud.postStatus(sessionId: sid, status: "stopped")
        _ = await uploader.pumpOnce()

        let posted = rpc.calls(for: "remote_helper_post_event").first
        XCTAssertEqual(posted?.params["p_seq"] as? Int, 1)
    }

    func test_post_status_seq_monotonic_within_session_isolated_across_sessions() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sidA = UUID().uuidString
        let sidB = UUID().uuidString
        await cloud.registerTestSession(sessionId: sidA)
        await cloud.registerTestSession(sessionId: sidB)
        await cloud.postInfo(sessionId: sidA, detail: "first A")
        await cloud.postInfo(sessionId: sidA, detail: "second A")
        await cloud.postInfo(sessionId: sidB, detail: "first B")
        _ = await uploader.pumpOnce()

        let posted = rpc.calls(for: "remote_helper_post_event")
        let seqsA = posted.filter { ($0.params["p_session_id"] as? String) == sidA }
            .compactMap { $0.params["p_seq"] as? Int }
        let seqsB = posted.filter { ($0.params["p_session_id"] as? String) == sidB }
            .compactMap { $0.params["p_seq"] as? Int }
        XCTAssertEqual(seqsA, [1, 2])
        XCTAssertEqual(seqsB, [1])
    }

    // MARK: - redaction + size caps

    func test_post_info_redacts_and_caps() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        let secret = "Bearer eyJabcdef.eyJghijkl.eyJmnopqr-" + String(repeating: "X", count: 5000)
        await cloud.postInfo(sessionId: sid, detail: "spawn failed: \(secret)")
        _ = await uploader.pumpOnce()

        let posted = rpc.calls(for: "remote_helper_post_event").last
        let payload = (posted?.params["p_payload"] as? String) ?? ""
        XCTAssertFalse(payload.contains("Bearer eyJabcdef"))
        XCTAssertTrue(payload.contains("«REDACTED»"))
        XCTAssertLessThanOrEqual(payload.count, EventUploader.infoPayloadCapChars)
    }

    func test_post_info_skipped_for_empty_detail() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        await cloud.postInfo(sessionId: sid, detail: "")
        _ = await uploader.pumpOnce()

        XCTAssertEqual(rpc.calls(for: "remote_helper_post_event").count, 0)
    }

    func test_stdout_chunk_redacts_and_caps_at_4000_chars() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        let chunk = "sk-ant-supersecrettokenAAAAAAAAAAAA " + String(repeating: "x", count: 5000)
        await cloud.postStdoutChunk(sessionId: sid, chunk: chunk)
        _ = await uploader.pumpOnce()

        let posted = rpc.calls(for: "remote_helper_post_event").last
        let payload = (posted?.params["p_payload"] as? String) ?? ""
        XCTAssertFalse(payload.contains("supersecrettoken"))
        XCTAssertTrue(payload.contains("«REDACTED»"))
        XCTAssertLessThanOrEqual(payload.count, EventUploader.eventPayloadCapChars)
    }

    // MARK: - bounded queue + flush

    func test_event_uploader_drops_oldest_when_session_queue_overflows() async throws {
        let rpc = FakeRPCCaller()
        // Block all uploads so the queue has to overflow.
        rpc.failKinds.insert("remote_helper_post_event")
        var dropped: [(String, EventUploader.EventKind, EventUploader.DropReason)] = []
        let lock = NSLock()
        let uploader = EventUploader(
            helperConfig: { Self.testCloudConfig },
            rpcCaller: rpc,
            onDrop: { sid, kind, reason in
                lock.lock(); defer { lock.unlock() }
                dropped.append((sid, kind, reason))
            }
        )
        let sid = UUID().uuidString
        // Push 257 events — first should drop.
        for i in 0..<257 {
            await uploader.ingest(sessionId: sid, kind: .stdout, payload: "chunk-\(i)")
        }
        let count = await uploader.queuedCount(sessionId: sid)
        XCTAssertEqual(count, EventUploader.perSessionQueueCap)
        XCTAssertEqual(dropped.count, 1)
        XCTAssertEqual(dropped[0].2, .queueOverflow)
    }

    func test_event_uploader_seq_continues_after_overflow_drop() async throws {
        let rpc = FakeRPCCaller()
        rpc.failKinds.insert("remote_helper_post_event")
        let uploader = EventUploader(
            helperConfig: { Self.testCloudConfig },
            rpcCaller: rpc
        )
        let sid = UUID().uuidString
        for _ in 0..<260 {
            await uploader.ingest(sessionId: sid, kind: .stdout, payload: "x")
        }
        // After 260 ingests (4 dropped), the seq counter should be at 260 —
        // it's monotonic regardless of queue eviction. Verifies the seq is
        // assigned at ingest time, not at upload time.
        let seq = await uploader.currentSeq(sessionId: sid)
        XCTAssertEqual(seq, 260)
    }

    func test_event_uploader_flush_drains_within_budget() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let sid = UUID().uuidString
        for i in 0..<5 {
            await uploader.ingest(sessionId: sid, kind: .stdout, payload: "msg-\(i)")
        }
        let (posted, dropped) = await uploader.flush(timeout: 5.0)
        XCTAssertEqual(posted, 5)
        XCTAssertEqual(dropped, 0)
        let total = await uploader.totalQueued()
        XCTAssertEqual(total, 0)
    }

    func test_event_uploader_flush_drops_after_budget() async throws {
        let rpc = FakeRPCCaller()
        rpc.failKinds.insert("remote_helper_post_event")
        var dropped: [(String, EventUploader.EventKind, EventUploader.DropReason)] = []
        let lock = NSLock()
        let uploader = EventUploader(
            helperConfig: { Self.testCloudConfig },
            rpcCaller: rpc,
            onDrop: { sid, kind, reason in
                lock.lock(); defer { lock.unlock() }
                dropped.append((sid, kind, reason))
            }
        )
        let sid = UUID().uuidString
        for _ in 0..<3 {
            await uploader.ingest(sessionId: sid, kind: .stdout, payload: "x")
        }
        // 0.1 s budget — pump can't make progress because RPC fails;
        // events should be dropped with flushBudgetExceeded.
        let (_, droppedCount) = await uploader.flush(timeout: 0.1)
        XCTAssertEqual(droppedCount, 3)
        let total = await uploader.totalQueued()
        XCTAssertEqual(total, 0)
        let reasons = dropped.map { $0.2 }
        XCTAssertTrue(reasons.contains(.flushBudgetExceeded))
    }

    func test_event_uploader_pump_retains_on_failure_and_succeeds_after_recovery() async throws {
        let rpc = FakeRPCCaller()
        rpc.failKinds.insert("remote_helper_post_event")
        let uploader = makeUploader(rpc: rpc)
        let sid = UUID().uuidString
        await uploader.ingest(sessionId: sid, kind: .stdout, payload: "first")
        let postedFail = await uploader.pumpOnce()
        XCTAssertEqual(postedFail, 0)
        let queued = await uploader.queuedCount(sessionId: sid)
        XCTAssertEqual(queued, 1)
        // Recover.
        rpc.failKinds.remove("remote_helper_post_event")
        let postedOk = await uploader.pumpOnce()
        XCTAssertEqual(postedOk, 1)
    }

    // MARK: - exit observation

    func test_observe_exits_posts_stopped_for_clean_exit() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        // Manager has no session with this id → observeExits sees gone.
        let exited = await cloud.observeExitsForTesting()
        XCTAssertEqual(exited, 1)
        _ = await uploader.pumpOnce()
        let payloads = rpc.calls(for: "remote_helper_post_event")
            .filter { ($0.params["p_kind"] as? String) == "status" }
            .compactMap { $0.params["p_payload"] as? String }
        XCTAssertEqual(payloads, ["stopped"])
    }

    func test_observe_exits_posts_errored_when_exit_code_nonzero() async throws {
        let rpc = FakeRPCCaller()
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let sid = UUID().uuidString
        await cloud.registerTestSession(sessionId: sid)
        await cloud.recordExitForTesting(sessionId: sid, exitCode: 7)
        _ = await cloud.observeExitsForTesting()
        _ = await uploader.pumpOnce()

        let posted = rpc.calls(for: "remote_helper_post_event")
        let statusPayloads = posted.filter { ($0.params["p_kind"] as? String) == "status" }
            .compactMap { $0.params["p_payload"] as? String }
        XCTAssertEqual(statusPayloads, ["errored"])
        let infoPayloads = posted.filter { ($0.params["p_kind"] as? String) == "info" }
            .compactMap { $0.params["p_payload"] as? String }
        XCTAssertEqual(infoPayloads.count, 1)
        XCTAssertTrue((infoPayloads.first ?? "").contains("exit_code=7"))
    }

    // MARK: - batcher

    func test_batcher_flushes_when_size_threshold_trips() {
        let batcher = EventBatcher(flushBytes: 100, maxIdle: 10.0)
        XCTAssertNil(batcher.add(String(repeating: "a", count: 50)))
        let drained = batcher.add(String(repeating: "b", count: 60))
        XCTAssertNotNil(drained)
        XCTAssertEqual(drained?.count, 110)
    }

    func test_batcher_due_after_idle() {
        var clock: TimeInterval = 0.0
        let batcher = EventBatcher(
            flushBytes: 10_000,
            maxIdle: 0.5,
            nowProvider: { clock }
        )
        _ = batcher.add("hello")
        XCTAssertFalse(batcher.due())
        clock = 1.0
        XCTAssertTrue(batcher.due())
        let drained = batcher.drain()
        XCTAssertEqual(drained, "hello")
        XCTAssertFalse(batcher.due())
    }

    func test_batcher_caps_at_4096_chars() {
        let batcher = EventBatcher(flushBytes: 100)
        // add() returns the drained payload when the size threshold trips.
        let drained = batcher.add(String(repeating: "x", count: 5000))
        XCTAssertEqual(drained?.count, 4096)
        // Subsequent drain has nothing left.
        XCTAssertNil(batcher.drain())
    }

    // MARK: - wstatus → exit code conversion

    func test_wstatus_normal_exit_extracts_correct_code() {
        // Documents the POSIX wstatus layout the drainLoop relies
        // on. Codex P2 (Gemini Slice 3): direct unit test for the
        // bit-twiddling so a future kernel change is caught here
        // and not via downstream "errored vs stopped" misclassify.
        // For a normal exit with code N: wstatus = N << 8.
        let wstatusZero: Int32 = 0 << 8
        let wstatusSeven: Int32 = 7 << 8
        // Replicate the conversion inline so the test pins the
        // exact arithmetic the production code performs.
        func extract(_ status: Int32) -> Int32 {
            if (status & 0x7f) == 0 {
                return (status >> 8) & 0xff
            }
            return -1
        }
        XCTAssertEqual(extract(wstatusZero), 0)
        XCTAssertEqual(extract(wstatusSeven), 7)
        // Signaled (e.g. SIGTERM = 15): low 7 bits != 0 → -1
        let wstatusSignaled: Int32 = 0x0f
        XCTAssertEqual(extract(wstatusSignaled), -1)
    }

    // MARK: - dispatch_one event posting on completion failure

    func test_complete_command_failure_is_non_fatal() async throws {
        // RPC for complete_command fails — the tick must not crash.
        let cmdId = UUID().uuidString
        let rpc = FakeRPCCaller()
        rpc.responses["remote_helper_pull_commands"] = { _ in
            return [[
                "id": cmdId,
                "session_id": UUID().uuidString,
                "kind": "explode",
                "payload": "",
            ]]
        }
        rpc.failKinds.insert("remote_helper_complete_command")
        let uploader = makeUploader(rpc: rpc)
        let manager = ManagedSessionManager(transport: PtyTransport())
        let cloud = makeCloud(rpc: rpc, uploader: uploader, sessionManager: manager)

        let result = await cloud.tick()
        XCTAssertEqual(result.commandsProcessed, 1)
    }
}
