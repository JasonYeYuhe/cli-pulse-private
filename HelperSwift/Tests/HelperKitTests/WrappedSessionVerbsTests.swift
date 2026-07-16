import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// M4.4a PR-D: the manager attach path + UDS verbs that wire TmuxTransport +
/// ShellIntegration into the app's terminal surface. Real end-to-end where
/// tmux is available (attach → the app's send_input_raw/get_tail_snapshot drive
/// the wrapped session); pure otherwise.
final class WrappedSessionVerbsTests: XCTestCase {

    private var sockDir: URL!
    private var server: LocalSessionServer?
    private var manager: ManagedSessionManager?

    override func setUp() {
        super.setUp()
        let parent = FileManager.default.fileExists(atPath: "/tmp") ? "/tmp" : NSTemporaryDirectory()
        sockDir = URL(fileURLWithPath: parent)
            .appendingPathComponent("clipulse-wrapped-tests-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: sockDir, withIntermediateDirectories: true)
    }
    override func tearDown() {
        server?.stop()
        manager?.shutdown()
        try? FileManager.default.removeItem(at: sockDir)
        super.tearDown()
    }

    private var tmuxBin: String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/tmux"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            ? "/opt/homebrew/bin/tmux" : nil
    }

    private func makeServer(enabled: Bool = true) throws -> LocalSessionServer {
        let mgr = ManagedSessionManager(transport: PtyTransport())
        manager = mgr
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        let enabledBox = AtomicBool(); enabledBox.set(enabled)
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sockPath),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { "T" },
                isLocalControlEnabled: { enabledBox.get() },
                setLocalControlEnabled: { enabledBox.set($0) },
                sessionManager: mgr
            )
        )
        try s.start()
        usleep(50_000)
        return s
    }

    private func clientCall(_ body: [String: Any]) throws -> [String: Any] {
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = (sockPath.path as NSString).fileSystemRepresentation
        withUnsafeMutableBytes(of: &addr.sun_path) { memcpy($0.baseAddress!, path, strlen(path)) }
        let rc = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 { throw NSError(domain: "connect", code: Int(errno)) }
        try Framing.writeFrame(to: fd, body: try JSONSerialization.data(withJSONObject: body))
        guard let reply = try Framing.readFrame(from: fd),
              let dict = try JSONSerialization.jsonObject(with: reply) as? [String: Any]
        else { throw NSError(domain: "reply", code: 0) }
        return dict
    }

    // MARK: - gating + advertise

    func testWrappedVerbsAdvertisedAndGated() throws {
        server = try makeServer(enabled: false)
        let hello = try clientCall(["id": "1", "method": "hello", "params": [:]])
        let supported = (hello["result"] as! [String: Any])["supported_methods"] as! [String]
        for m in ["list_wrapped_sessions", "attach_wrapped_session",
                  "shell_integration_status", "shell_integration_install", "shell_integration_uninstall"] {
            XCTAssertTrue(supported.contains(m), "hello must advertise \(m)")
        }
        // gate-off blocks the session-control verbs.
        let gated = try clientCall(["id": "2", "method": "list_wrapped_sessions", "auth_token": "T", "params": [:]])
        XCTAssertEqual((gated["error"] as? [String: Any])?["code"] as? String, "local_control_off")
        // unauth blocks.
        let noAuth = try clientCall(["id": "3", "method": "attach_wrapped_session", "params": [:]])
        XCTAssertEqual((noAuth["error"] as? [String: Any])?["code"] as? String, "unauthenticated")
    }

    func testCloudOptInVerbsAreAdvertisedAndGated() throws {
        // M4.4d. The gating is IMPLICIT — `bypassesAuth`/`bypassesGate` are
        // default-deny, so these verbs are protected by falling through to
        // `default`. That's load-bearing and invisible at the call site: pin it,
        // so a future `case` added to either switch can't silently expose the
        // consent surface.
        server = try makeServer(enabled: false)
        let hello = try clientCall(["id": "1", "method": "hello", "params": [:]])
        let supported = (hello["result"] as! [String: Any])["supported_methods"] as! [String]
        for m in ["set_wrapped_session_cloud_shared", "wrapped_session_cloud_state"] {
            XCTAssertTrue(supported.contains(m), "hello must advertise \(m)")
        }
        // local control off → refused even with a valid token.
        let gated = try clientCall(["id": "2", "method": "set_wrapped_session_cloud_shared",
                                    "auth_token": "T", "params": ["session_id": "s", "shared": true]])
        XCTAssertEqual((gated["error"] as? [String: Any])?["code"] as? String, "local_control_off")
        let gatedState = try clientCall(["id": "3", "method": "wrapped_session_cloud_state",
                                         "auth_token": "T", "params": [:]])
        XCTAssertEqual((gatedState["error"] as? [String: Any])?["code"] as? String, "local_control_off")
        // no token → refused.
        let noAuth = try clientCall(["id": "4", "method": "set_wrapped_session_cloud_shared",
                                     "params": ["session_id": "s", "shared": true]])
        XCTAssertEqual((noAuth["error"] as? [String: Any])?["code"] as? String, "unauthenticated")
    }

    func testSetCloudSharedVerbValidatesParams() throws {
        server = try makeServer()
        // No cloud arm wired (unpaired helper / this test) → not_implemented,
        // never a silent local flag flip that nothing would act on.
        let noArm = try clientCall(["id": "1", "method": "set_wrapped_session_cloud_shared",
                                    "auth_token": "T", "params": ["session_id": "s", "shared": true]])
        XCTAssertEqual((noArm["error"] as? [String: Any])?["code"] as? String, "not_implemented")
        // `shared` is a PRIVACY decision — a missing/non-boolean value must be
        // refused, never defaulted.
        let missingShared = try clientCall(["id": "2", "method": "set_wrapped_session_cloud_shared",
                                            "auth_token": "T", "params": ["session_id": "s"]])
        XCTAssertNotNil(missingShared["error"], "a missing `shared` must not be defaulted")
        // The state verb works without a cloud arm (it reads the manager).
        let state = try clientCall(["id": "3", "method": "wrapped_session_cloud_state",
                                    "auth_token": "T", "params": [:]])
        XCTAssertTrue(state["ok"] as? Bool ?? false, "\(state)")
        XCTAssertEqual(((state["result"] as? [String: Any])?["shared"] as? [String])?.count, 0)
    }

    func testListWrappedSessionsReturnsArray() throws {
        server = try makeServer()
        let reply = try clientCall(["id": "1", "method": "list_wrapped_sessions", "auth_token": "T", "params": [:]])
        XCTAssertTrue(reply["ok"] as? Bool ?? false, "\(reply)")
        XCTAssertNotNil((reply["result"] as? [String: Any])?["sessions"] as? [Any])
    }

    func testAttachWrappedSessionBadRequest() throws {
        server = try makeServer()
        let missing = try clientCall(["id": "1", "method": "attach_wrapped_session",
                                      "auth_token": "T", "params": ["tmux_session_name": "x"]])
        XCTAssertEqual((missing["error"] as? [String: Any])?["code"] as? String, "bad_request")
    }

    func testAttachWrappedSessionRejectsBadProviderAndLabel() throws {
        server = try makeServer()
        // Empty provider → bad_request (not silently coerced to "claude").
        let emptyProvider = try clientCall(["id": "1", "method": "attach_wrapped_session", "auth_token": "T",
            "params": ["session_id": "s", "tmux_session_name": "t", "provider": ""]])
        XCTAssertEqual((emptyProvider["error"] as? [String: Any])?["code"] as? String, "bad_request")
        // Non-string provider → bad_request.
        let numProvider = try clientCall(["id": "2", "method": "attach_wrapped_session", "auth_token": "T",
            "params": ["session_id": "s", "tmux_session_name": "t", "provider": 7]])
        XCTAssertEqual((numProvider["error"] as? [String: Any])?["code"] as? String, "bad_request")
        // Non-string, non-null client_label → bad_request (not silently dropped).
        let badLabel = try clientCall(["id": "3", "method": "attach_wrapped_session", "auth_token": "T",
            "params": ["session_id": "s", "tmux_session_name": "t", "client_label": 5]])
        XCTAssertEqual((badLabel["error"] as? [String: Any])?["code"] as? String, "bad_request")
    }

    // MARK: - attached sessions are LOCAL-ONLY (never cloud-uploaded)

    func testAttachedSessionIsSkippedByCloudObserver() throws {
        // The manager marks an attached session `isAttached==true`; the cloud
        // observer queries this to skip ALL cloud handling (review: codex — the
        // realtimePrivate=nil gate only mutes the PUBLIC sink, not cloud upload).
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("cloud.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-9", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }

        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-1", tmuxSessionName: "clipulse-claude-9",
                                               tmuxBin: bin, socketPath: sock))
        XCTAssertTrue(mgr.isAttached("att-1"), "an attached session must report isAttached")
        // A spawned/unknown session is NOT attached.
        XCTAssertFalse(mgr.isAttached("some-spawned-id"))
    }

    func testCloudObserverUploadsNothingForAttachedSession() async throws {
        // END-TO-END: feed the attached session's session_started + output_delta
        // frames through the cloud observer and assert ZERO cloud state + posts
        // (review: codex — attached sessions must never reach remote_helper_post_event).
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("cloudobs.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-codex-3", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-c", tmuxSessionName: "clipulse-codex-3",
                                               tmuxBin: bin, socketPath: sock))

        let rpc = CountingRPC()
        let cfg = HelperConfigStore.CloudConfig(
            deviceId: "11111111-2222-3333-4444-555555555555", helperSecret: "s",
            supabaseURL: "https://x.supabase.co", supabaseAnonKey: "anon")
        let uploader = EventUploader(helperConfig: { cfg }, rpcCaller: rpc)
        let cloud = RemoteAgentCloud(
            helperConfig: { cfg },
            rpcCaller: rpc, sessionManager: mgr, uploader: uploader, broker: nil)

        // Frames carry the LATCHED local_only flag (the manager stamps it on
        // every frame). The observer skips from the FRAME, not manager state.
        await cloud.handleBrokerEventForTesting([
            "event": "session_started", "session_id": "att-c", "provider": "codex",
            "attached": true, "local_only": true])
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-c", "payload": "secret wrapped output",
            "attached": true, "local_only": true])
        await cloud.handleBrokerEventForTesting([
            "event": "session_stopped", "session_id": "att-c", "exit_code": 0,
            "attached": true, "local_only": true])

        // The RACE codex flagged: a DEFERRED output_delta Task runs AFTER the
        // manager already removed the record (so a state query would say
        // "not attached"). The frame flag still latches it out. Simulate by
        // detaching first, then delivering a late frame.
        _ = mgr.stopSession("att-c")
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-c", "payload": "late secret",
            "attached": true, "local_only": true])
        _ = await uploader.pumpOnce()

        let cloudTracked = await cloud.trackedSessionCountForTesting
        XCTAssertEqual(cloudTracked, 0, "attached session must not create cloud state (even on a late frame)")
        XCTAssertEqual(rpc.postEventCount, 0,
                       "attached session output must never be uploaded to the cloud")
    }

    func testCloudCommandForAttachedSessionRejected() async throws {
        // Defense-in-depth: an inbound cloud command targeting an attached
        // (local-only) session must be rejected, never drive the real session.
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("cmd.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-5", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-cmd", tmuxSessionName: "clipulse-claude-5",
                                               tmuxBin: bin, socketPath: sock))
        let rpc = CountingRPC()
        let cfg = HelperConfigStore.CloudConfig(
            deviceId: "11111111-2222-3333-4444-555555555555", helperSecret: "s",
            supabaseURL: "https://x.supabase.co", supabaseAnonKey: "anon")
        let cloud = RemoteAgentCloud(
            helperConfig: { cfg }, rpcCaller: rpc, sessionManager: mgr,
            uploader: EventUploader(helperConfig: { cfg }, rpcCaller: rpc), broker: nil)

        await cloud.dispatchOneForTesting(["id": "c1", "kind": "stop", "session_id": "att-cmd"])
        // The real wrapped session must still be alive (the stop was rejected).
        XCTAssertTrue(mgr.isAttached("att-cmd"), "a cloud stop must NOT tear down a local-only attached session")
        XCTAssertTrue(owner.isAlive(oh))
    }

    // MARK: - M4.4d: explicit, per-session opt-in into the cloud plane

    func testShareMintsAPrivateRowAndUnshareRevokes() async throws {
        // The opt-in must (a) mint the cloud row the phone routes on, (b) mint it
        // PRIVATE — an external session must never be advertised on the public
        // `term:` topic, which bypasses RLS by design.
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("share.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-77", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-share", tmuxSessionName: "clipulse-claude-77",
                                               provider: "claude", tmuxBin: bin, socketPath: sock))

        let rpc = CountingRPC()
        let cloud = Self.makeCloud(rpc: rpc, mgr: mgr)

        XCTAssertFalse(mgr.isCloudShared("att-share"), "an attach must start LOCAL-ONLY")

        let shared = await cloud.shareAttachedSession(sessionId: "att-share")
        XCTAssertTrue(shared.ok, "share failed: \(shared.error)")
        XCTAssertTrue(mgr.isCloudShared("att-share"))
        XCTAssertEqual(mgr.cloudSharedSessionIds(), ["att-share"])

        XCTAssertEqual(rpc.registerParams.count, 1, "share must mint exactly one cloud row")
        let params = try XCTUnwrap(rpc.registerParams.first)
        XCTAssertEqual(params["p_session_id"] as? String, "att-share")
        XCTAssertEqual(params["p_provider"] as? String, "claude")
        XCTAssertEqual(params["p_realtime_private"] as? Bool, true,
                       "an external session must be minted PRIVATE — the public term: topic bypasses RLS")

        // Revoking is local-first: the flag drops even though the row lingers.
        let un = await cloud.unshareAttachedSession(sessionId: "att-share")
        XCTAssertTrue(un.ok, "unshare failed: \(un.error)")
        XCTAssertFalse(mgr.isCloudShared("att-share"))
        XCTAssertEqual(mgr.cloudSharedSessionIds(), [])
        // ...and the session itself is untouched: revoking sharing is not stopping.
        XCTAssertTrue(mgr.isAttached("att-share"))
        XCTAssertTrue(owner.isAlive(oh))
    }

    func testShareDoesNotOptInWhenTheRowCannotBeMinted() async throws {
        // If register fails, flipping the flag anyway would latch local_only:false
        // onto frames whose post_event then raises 'Session not found for device'
        // — which doesn't drop, it STALLS the uploader queue behind it.
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("sharefail.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-78", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-f", tmuxSessionName: "clipulse-claude-78",
                                               tmuxBin: bin, socketPath: sock))
        let rpc = CountingRPC()
        rpc.failRegister = true
        let cloud = Self.makeCloud(rpc: rpc, mgr: mgr)

        let r = await cloud.shareAttachedSession(sessionId: "att-f")
        XCTAssertFalse(r.ok, "share must fail when the row can't be minted")
        XCTAssertFalse(mgr.isCloudShared("att-f"), "the opt-in must NOT flip without a cloud row behind it")
    }

    func testSharedSessionUploadsOutputAndUnsharedStops() async throws {
        // The whole point of M4.4d: once opted in, the wrapped session's output
        // reaches the phone — and once revoked, it stops.
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("upl.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-79", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-u", tmuxSessionName: "clipulse-claude-79",
                                               tmuxBin: bin, socketPath: sock))
        let rpc = CountingRPC()
        let cfg = Self.testCfg
        let uploader = EventUploader(helperConfig: { cfg }, rpcCaller: rpc)
        let cloud = RemoteAgentCloud(helperConfig: { cfg }, rpcCaller: rpc,
                                     sessionManager: mgr, uploader: uploader, broker: nil)

        let sharedu = await cloud.shareAttachedSession(sessionId: "att-u")
        XCTAssertTrue(sharedu.ok, "share failed: \(sharedu.error)")
        // A frame emitted while shared carries local_only:false. Oversize on
        // purpose: EventBatcher only yields a chunk once it trips its 4096-char
        // cutoff, so a short payload would sit in the batcher and prove nothing.
        let bigPayload = String(repeating: "consented output ", count: 400)
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-u", "payload": bigPayload,
            "attached": true, "local_only": false])
        _ = await uploader.flush()
        XCTAssertGreaterThan(rpc.postEventCount, 0, "a SHARED wrapped session's output must reach the cloud")

        let before = rpc.postEventCount
        _ = await cloud.unshareAttachedSession(sessionId: "att-u")
        // After revocation the manager latches local_only:true again; such a
        // frame must upload nothing.
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-u", "payload": bigPayload,
            "attached": true, "local_only": true])
        _ = await uploader.flush()
        // unshare posts one status row ('stopped'); no STDOUT may follow it.
        XCTAssertLessThanOrEqual(rpc.postEventCount - before, 1,
                                 "no output may upload after the user revokes sharing")
    }

    func testCloudStopIsRefusedEvenForASharedSession() async throws {
        // A cloud stop on a non-owning attach can only lie: terminate() no-ops,
        // so we'd detach, report `stopped`, and leave the user's real claude
        // running unwatched behind a phone that shows it stopped. (This is NOT a
        // protection against the phone ending the session — sharing grants input,
        // and input includes C-c. See AttachedPolicy.refuseAttached.)
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("stopshared.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-80", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-s", tmuxSessionName: "clipulse-claude-80",
                                               tmuxBin: bin, socketPath: sock))
        let rpc = CountingRPC()
        let cloud = Self.makeCloud(rpc: rpc, mgr: mgr)
        let shareds = await cloud.shareAttachedSession(sessionId: "att-s")
        XCTAssertTrue(shareds.ok, "share failed: \(shareds.error)")

        await cloud.dispatchOneForTesting(["id": "c9", "kind": "stop", "session_id": "att-s"])
        XCTAssertTrue(mgr.isAttached("att-s"), "a cloud stop must never end a shared external session")
        XCTAssertTrue(owner.isAlive(oh), "the user's real session must survive a cloud stop")
    }

    func testAnUnshareDuringAnInFlightShareWins() async throws {
        // review: agy — `shareAttachedSession` awaits its register RPC, and the
        // actor is REENTRANT across that suspension. An unshare that lands in the
        // gap must win: otherwise the share resumes, stomps the user's LAST
        // explicit choice, and the session silently uploads while the toggle
        // reads off. Same hazard the CloudShareArm timeout path relies on.
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("race.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-81", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-r", tmuxSessionName: "clipulse-claude-81",
                                               tmuxBin: bin, socketPath: sock))

        // A register that parks until we let it through, so the unshare provably
        // runs INSIDE the share's suspension rather than by luck of timing.
        let gate = RegisterGate()
        let rpc = GatedRPC(gate: gate)
        let cfg = Self.testCfg
        let cloud = RemoteAgentCloud(
            helperConfig: { cfg }, rpcCaller: rpc, sessionManager: mgr,
            uploader: EventUploader(helperConfig: { cfg }, rpcCaller: rpc), broker: nil)

        async let shareResult = cloud.shareAttachedSession(sessionId: "att-r")
        await gate.waitUntilRegisterEntered()
        let un = await cloud.unshareAttachedSession(sessionId: "att-r")
        XCTAssertTrue(un.ok, "unshare failed: \(un.error)")
        await gate.release()
        let share = await shareResult

        XCTAssertFalse(share.ok, "a share superseded by an unshare must not report success")
        XCTAssertFalse(mgr.isCloudShared("att-r"),
                       "the user's LAST choice (unshare) must win over an in-flight share")
    }

    func testUnsharingASessionThatWasNeverSharedPostsNothing() async throws {
        // review: codex — a never-shared session has NO cloud row, so a `stopped`
        // status would raise 'Session not found for device'. A failed event does
        // not drop: it sits at the head of that session's uploader queue and
        // wedges everything behind it, including a later legitimate share. The
        // CloudShareArm timeout path calls unshare exactly this way, so this is
        // reachable, not theoretical.
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("nevershared.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-82", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-n", tmuxSessionName: "clipulse-claude-82",
                                               tmuxBin: bin, socketPath: sock))
        let rpc = CountingRPC()
        let cfg = Self.testCfg
        let uploader = EventUploader(helperConfig: { cfg }, rpcCaller: rpc)
        let cloud = RemoteAgentCloud(helperConfig: { cfg }, rpcCaller: rpc,
                                     sessionManager: mgr, uploader: uploader, broker: nil)

        let r = await cloud.unshareAttachedSession(sessionId: "att-n")
        XCTAssertTrue(r.ok, "unsharing an unshared session is a no-op, not an error: \(r.error)")
        let queued = await uploader.queuedCount(sessionId: "att-n")
        XCTAssertEqual(queued, 0, "nothing may be queued for a session that never had a cloud row")
        _ = await uploader.flush()
        XCTAssertEqual(rpc.postEventCount, 0, "no event may be posted for a session with no cloud row")
    }

    func testRevokingPurgesOutputStillQueuedForUpload() async throws {
        // review: codex — dropping the actor's batcher isn't enough: chunks
        // already handed to the EventUploader would keep draining after the user
        // revoked. "Stop sharing" must mean stop, not "stop once the backlog
        // drains".
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        let sock = sockDir.appendingPathComponent("purge.sock").path
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let oh = try owner.start(sessionId: "clipulse-claude-83", argv: ["cat"])
        defer { owner.close(oh); try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(mgr.attachWrappedSession(sessionId: "att-p", tmuxSessionName: "clipulse-claude-83",
                                               tmuxBin: bin, socketPath: sock))
        let rpc = CountingRPC()
        let cfg = Self.testCfg
        let uploader = EventUploader(helperConfig: { cfg }, rpcCaller: rpc)
        let cloud = RemoteAgentCloud(helperConfig: { cfg }, rpcCaller: rpc,
                                     sessionManager: mgr, uploader: uploader, broker: nil)
        let sh = await cloud.shareAttachedSession(sessionId: "att-p")
        XCTAssertTrue(sh.ok, "share failed: \(sh.error)")

        // Queue output but do NOT pump it, so it's still in flight at revoke.
        let big = String(repeating: "queued but unsent ", count: 400)
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-p", "payload": big,
            "attached": true, "local_only": false])
        let queuedBeforeRevoke = await uploader.queuedCount(sessionId: "att-p")
        XCTAssertGreaterThan(queuedBeforeRevoke, 0, "precondition: output is queued and unsent")

        _ = await cloud.unshareAttachedSession(sessionId: "att-p")
        // The 'stopped' status is legitimately queued by the revoke itself; the
        // OUTPUT must be gone.
        let postsBefore = rpc.postEventCount
        _ = await uploader.flush()
        XCTAssertLessThanOrEqual(rpc.postEventCount - postsBefore, 1,
                                 "revoked output must not upload — only the 'stopped' status may")
    }

    func testRevokeDuringAnInFlightPumpStopsTheUpload() async throws {
        // review: audit workflow — the finding agy and codex BOTH missed.
        // `pumpOnce` used to bind a value-type COPY of a session's queue and
        // hold it across `await postEvent` (an HTTPS RPC that releases the
        // actor), then write that copy back. So `uploader.removeSession` — the
        // whole mechanism of M4.4d's revoke — was invisible to a pump already in
        // flight: the pump resumed from its stale copy and posted every revoked
        // event anyway, then resurrected them by writing the copy back.
        //
        // With a ~1 s tick and ~200 ms RPCs on a chatty session, "a pump is in
        // flight" is the ORDINARY case, so the revoke fix was close to a no-op.
        //
        // This drives the interleave deterministically: the RPC parks on a gate,
        // the revoke runs inside that suspension, then the RPC is released.
        let gate = RegisterGate()
        let rpc = GatedPostRPC(gate: gate)
        let cfg = Self.testCfg
        let uploader = EventUploader(helperConfig: { cfg }, rpcCaller: rpc)

        // Queue several events, as a shared session's output would be.
        for i in 0..<5 {
            await uploader.ingest(sessionId: "sess-r", kind: .stdout, payload: "secret chunk \(i)")
        }
        let queuedBefore = await uploader.queuedCount(sessionId: "sess-r")
        XCTAssertEqual(queuedBefore, 5)

        async let pumped = uploader.pumpOnce()
        // Wait until the pump is genuinely suspended inside the first post.
        await gate.waitUntilRegisterEntered()
        // The user revokes while that post is in flight.
        await uploader.removeSession("sess-r")
        await gate.release()
        _ = await pumped

        let posts = rpc.postCount
        XCTAssertEqual(posts, 1,
                       "only the post already in flight may land — the other 4 were revoked")
        let queuedAfter = await uploader.queuedCount(sessionId: "sess-r")
        XCTAssertEqual(queuedAfter, 0,
                       "the purged queue must not be resurrected by the pump's stale copy")
    }

    func testIngestDuringAnInFlightPumpIsNotLost() async throws {
        // Same root cause, opposite direction: the stale copy written back at
        // the end of a pump DISCARDED anything ingested during it — silent
        // output loss on any session busy enough to produce output while an
        // upload was in flight.
        let gate = RegisterGate()
        let rpc = GatedPostRPC(gate: gate)
        let cfg = Self.testCfg
        let uploader = EventUploader(helperConfig: { cfg }, rpcCaller: rpc)

        await uploader.ingest(sessionId: "sess-i", kind: .stdout, payload: "first")
        async let pumped = uploader.pumpOnce()
        await gate.waitUntilRegisterEntered()
        // Output arrives while the first post is in flight.
        await uploader.ingest(sessionId: "sess-i", kind: .stdout, payload: "arrived mid-pump")
        await gate.release()
        _ = await pumped

        // "first" posted; "arrived mid-pump" must still be queued (or posted) —
        // never silently dropped.
        let remaining = await uploader.queuedCount(sessionId: "sess-i")
        XCTAssertEqual(remaining + rpc.postCount, 2,
                       "an event ingested during a pump must not be discarded")
    }

    func testSetCloudSharedRefusesANonAttachedSession() throws {
        // The flag governs attached sessions only. A spawned session is already
        // cloud-wired; letting this flip on one would imply an opt-in surface
        // that doesn't actually govern it.
        let mgr = ManagedSessionManager(transport: PtyTransport())
        defer { mgr.shutdown() }
        XCTAssertNil(mgr.setCloudShared("no-such-session", true))
        XCTAssertNil(mgr.attachedSessionInfo("no-such-session"))
        XCTAssertFalse(mgr.isCloudShared("no-such-session"))
    }

    private static var testCfg: HelperConfigStore.CloudConfig {
        HelperConfigStore.CloudConfig(
            deviceId: "11111111-2222-3333-4444-555555555555", helperSecret: "s",
            supabaseURL: "https://x.supabase.co", supabaseAnonKey: "anon")
    }

    private static func makeCloud(rpc: CountingRPC, mgr: ManagedSessionManager) -> RemoteAgentCloud {
        let cfg = testCfg
        return RemoteAgentCloud(
            helperConfig: { cfg }, rpcCaller: rpc, sessionManager: mgr,
            uploader: EventUploader(helperConfig: { cfg }, rpcCaller: rpc), broker: nil)
    }

    func testAttachWrappedSessionAttachFailedForMissingSession() throws {
        server = try makeServer()
        // No such tmux session on a fresh socket → attach_failed.
        let reply = try clientCall([
            "id": "1", "method": "attach_wrapped_session", "auth_token": "T",
            "params": ["session_id": "s1", "tmux_session_name": "clipulse-nope-1",
                       "socket_path": sockDir.appendingPathComponent("nope.sock").path],
        ])
        XCTAssertFalse(reply["ok"] as? Bool ?? true)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "attach_failed")
    }

    func testShellIntegrationStatusVerb() throws {
        server = try makeServer()
        let reply = try clientCall(["id": "1", "method": "shell_integration_status", "auth_token": "T", "params": [:]])
        XCTAssertTrue(reply["ok"] as? Bool ?? false, "\(reply)")
        let result = reply["result"] as! [String: Any]
        XCTAssertNotNil(result["installed"] as? Bool)
        XCTAssertNotNil(result["sock"] as? String)
    }

    // MARK: - real end-to-end: attach a wrapped tmux session + drive it via the app surface

    func testAttachWrappedSessionEndToEndDrivesTerminalSurface() throws {
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        server = try makeServer()
        let mgr = manager!
        let sock = sockDir.appendingPathComponent("wrap.sock").path
        // Simulate a shell-integration-wrapped session: a tmux session running
        // `cat`, on our socket, named with the clipulse- prefix.
        let owner = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let ownerHandle = try owner.start(sessionId: "clipulse-claude-42", argv: ["cat"])
        defer { owner.close(ownerHandle); try? FileManager.default.removeItem(atPath: sock) }

        // Attach through the MANAGER (as the UDS verb would), pointing at our sock.
        let ok = mgr.attachWrappedSession(
            sessionId: "wrapped-1", tmuxSessionName: "clipulse-claude-42",
            provider: "claude", tmuxBin: bin, socketPath: sock)
        XCTAssertTrue(ok, "attach should succeed for a live wrapped session")

        // It shows up in the app's listSessions (the existing surface).
        XCTAssertTrue(mgr.listSessions().contains { $0.sessionId == "wrapped-1" })

        // Drive it via send_input_raw (the app's terminal input path) → cat echoes
        // → get_tail_snapshot / drain shows it. Inject "hi\n".
        _ = try mgr.sendInputRaw(sessionId: "wrapped-1", bytes: Data("hi\n".utf8))
        // The drain loop feeds the tail buffer; poll the snapshot.
        var got = ""
        for _ in 0..<60 {
            if let snap = mgr.getTailSnapshot(sessionId: "wrapped-1", maxBytes: 65536),
               let s = String(data: snap, encoding: .utf8), s.contains("hi") { got = s; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(got.contains("hi"), "the app's terminal surface must stream the wrapped session's output")

        // Stopping the ATTACHED session must NOT kill the real tmux session
        // (non-owning) — the owner handle is still alive afterward.
        _ = mgr.stopSession("wrapped-1")
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(owner.isAlive(ownerHandle),
                      "detaching a wrapped session must leave the user's real session ALIVE")
    }
}

/// Counts remote_helper_post_event calls; returns benign empties for the rest.
/// Lets a test park inside `remote_helper_register_session` so a second actor
/// call provably runs during the share's suspension.
private actor RegisterGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func noteEntered() {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
    }
    func waitUntilRegisterEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
    func waitForRelease() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }
}

private final class GatedRPC: RPCCallable, @unchecked Sendable {
    private let gate: RegisterGate
    init(gate: RegisterGate) { self.gate = gate }
    func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
        if rpcName == "remote_helper_register_session" {
            await gate.noteEntered()
            await gate.waitForRelease()
        }
        return [String: Any]()
    }
}

/// Parks inside `remote_helper_post_event` so a test can drive the exact
/// interleave where the uploader is suspended mid-post.
private final class GatedPostRPC: RPCCallable, @unchecked Sendable {
    private let gate: RegisterGate
    private let lock = NSLock()
    private var _posts = 0
    var postCount: Int { lock.lock(); defer { lock.unlock() }; return _posts }
    init(gate: RegisterGate) { self.gate = gate }
    func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
        if rpcName == "remote_helper_post_event" {
            lock.lock(); _posts += 1; lock.unlock()
            // Only the FIRST post parks — later ones run free, so the test
            // observes whether any of them happen at all.
            if postCount == 1 {
                await gate.noteEntered()
                await gate.waitForRelease()
            }
        }
        return [String: Any]()
    }
}

private final class CountingRPC: RPCCallable, @unchecked Sendable {
    private let lock = NSLock()
    private var _postEvents = 0
    private var _registerParams: [[String: Any]] = []
    /// Set to make every `remote_helper_register_session` throw, so a test can
    /// prove the opt-in flag never flips without a cloud row behind it.
    var failRegister = false
    var postEventCount: Int { lock.lock(); defer { lock.unlock() }; return _postEvents }
    var registerParams: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _registerParams }
    func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
        if rpcName == "remote_helper_post_event" {
            lock.lock(); _postEvents += 1; lock.unlock()
        }
        if rpcName == "remote_helper_register_session" {
            lock.lock(); _registerParams.append(params); lock.unlock()
            if failRegister { throw SupabaseRPCError.transport("register boom") }
        }
        return [String: Any]()
    }
}
