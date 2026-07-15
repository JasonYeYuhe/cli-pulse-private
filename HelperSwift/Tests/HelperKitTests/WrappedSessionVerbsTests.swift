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

        // Frames carry the LATCHED attached flag (the manager stamps it on every
        // frame). The observer skips from the FRAME, not manager state.
        await cloud.handleBrokerEventForTesting([
            "event": "session_started", "session_id": "att-c", "provider": "codex", "attached": true])
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-c", "payload": "secret wrapped output", "attached": true])
        await cloud.handleBrokerEventForTesting([
            "event": "session_stopped", "session_id": "att-c", "exit_code": 0, "attached": true])

        // The RACE codex flagged: a DEFERRED output_delta Task runs AFTER the
        // manager already removed the record (so a state query would say
        // "not attached"). The frame flag still latches it out. Simulate by
        // detaching first, then delivering a late frame.
        _ = mgr.stopSession("att-c")
        await cloud.handleBrokerEventForTesting([
            "event": "output_delta", "session_id": "att-c", "payload": "late secret", "attached": true])
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
private final class CountingRPC: RPCCallable, @unchecked Sendable {
    private let lock = NSLock()
    private var _postEvents = 0
    var postEventCount: Int { lock.lock(); defer { lock.unlock() }; return _postEvents }
    func call(_ rpcName: String, params: [String: Any]) async throws -> Any {
        if rpcName == "remote_helper_post_event" {
            lock.lock(); _postEvents += 1; lock.unlock()
        }
        return [String: Any]()
    }
}
