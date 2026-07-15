import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// End-to-end UDS server test — Swift port of the corresponding
/// section in `helper/test_local_session_server.py`. We bind a real
/// short-path socket under `/tmp` (macOS AF_UNIX limit ~104 chars)
/// and drive a real client connection over the wire.
final class LocalSessionServerTests: XCTestCase {

    private var sockDir: URL!
    private var server: LocalSessionServer?

    override func setUp() {
        super.setUp()
        let parent = FileManager.default.fileExists(atPath: "/tmp") ? "/tmp" : NSTemporaryDirectory()
        sockDir = URL(fileURLWithPath: parent)
            .appendingPathComponent("clipulse-helper-tests-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: sockDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        server?.stop()
        try? FileManager.default.removeItem(at: sockDir)
        super.tearDown()
    }

    private func makeServer(token: String = "T", enabled: Bool = true,
                            helperArgv0: String? = nil,
                            settingsPath: URL? = nil,
                            codexSettingsPath: URL? = nil) throws -> LocalSessionServer {
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        let enabledBox = AtomicBool()
        enabledBox.set(enabled)
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sockPath),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { token },
                isLocalControlEnabled: { enabledBox.get() },
                setLocalControlEnabled: { enabledBox.set($0) },
                getHelperArgv0: { helperArgv0 },
                claudeSettingsPathOverride: { settingsPath },
                codexSettingsPathOverride: { codexSettingsPath }
            )
        )
        try s.start()
        // Wait for the listener thread to bind. accept() on the
        // peer side blocks until connect() comes in, so a tiny
        // delay (<1 ms in practice) avoids a race where the
        // first test client connects before bind() resolves.
        usleep(50_000)
        return s
    }

    private func clientCall(_ body: [String: Any]) throws -> [String: Any] {
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = (sockPath.path as NSString).fileSystemRepresentation
        let len = strlen(path)
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            memcpy(rawPtr.baseAddress!, path, len)
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            throw NSError(domain: "test.connect", code: Int(errno))
        }
        let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])
        try Framing.writeFrame(to: fd, body: bodyData)
        guard let reply = try Framing.readFrame(from: fd) else {
            throw NSError(domain: "test.eof", code: 0)
        }
        guard let dict = try JSONSerialization.jsonObject(with: reply, options: []) as? [String: Any] else {
            throw NSError(domain: "test.parse", code: 0)
        }
        return dict
    }

    func testHelloReturnsCapsWithoutAuth() throws {
        server = try makeServer()
        let reply = try clientCall(["id": "1", "method": "hello", "params": [:]])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let result = reply["result"] as? [String: Any]
        XCTAssertEqual(result?["protocol_version"] as? Int, kProtocolVersion)
        // v1.34 R1d: hello must advertise helper_version so the app can gate
        // managed Claude sessions on the socket-owner being >= the OAuth floor.
        XCTAssertEqual(result?["helper_version"] as? String, kHelperVersion)
        let supported = (result?["supported_methods"] as? [String])?.sorted() ?? []
        // hello SHOULD be in the supported list; pick a few
        // representative methods to pin without requiring the
        // full set match (later iters add methods).
        XCTAssertTrue(supported.contains("hello"))
        XCTAssertTrue(supported.contains("ping"))
        XCTAssertTrue(supported.contains("install_claude_hook"))
        let caps = result?["capabilities"] as? [String: Any]
        XCTAssertEqual(caps?["send_input"] as? Bool, true)
        XCTAssertEqual(caps?["subscribe_events"] as? Bool, true)
        XCTAssertEqual(caps?["approvals"] as? Bool, true)
    }

    func testPingRequiresAuth() throws {
        server = try makeServer(token: "secret")
        // Without auth_token → unauthenticated
        let reply = try clientCall(["id": "1", "method": "ping", "params": [:]])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        let err = reply["error"] as? [String: Any]
        XCTAssertEqual(err?["code"] as? String, "unauthenticated")
    }

    func testPingSucceedsWithCorrectToken() throws {
        server = try makeServer(token: "secret")
        let reply = try clientCall([
            "id": "1", "method": "ping",
            "auth_token": "secret",
            "params": [:],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        let result = reply["result"] as? [String: Any]
        XCTAssertEqual(result?["pong"] as? Bool, true)
    }

    func testPingRejectsBadToken() throws {
        server = try makeServer(token: "secret")
        let reply = try clientCall([
            "id": "1", "method": "ping",
            "auth_token": "wrong",
            "params": [:],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "unauthenticated")
    }

    func testGetLocalControlStatusReportsState() throws {
        server = try makeServer(token: "T", enabled: false)
        let reply = try clientCall([
            "id": "1", "method": "get_local_control_status",
            "auth_token": "T",
            "params": [:],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual((reply["result"] as? [String: Any])?["local_control_enabled"] as? Bool, false)
    }

    func testSetLocalControlEnabledFlipsAndPersists() throws {
        server = try makeServer(token: "T", enabled: false)
        let reply = try clientCall([
            "id": "1", "method": "set_local_control_enabled",
            "auth_token": "T",
            "params": ["enabled": true],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual((reply["result"] as? [String: Any])?["local_control_enabled"] as? Bool, true)
        // Re-read confirms the flip persisted across calls.
        let probe = try clientCall([
            "id": "2", "method": "get_local_control_status",
            "auth_token": "T",
            "params": [:],
        ])
        XCTAssertEqual((probe["result"] as? [String: Any])?["local_control_enabled"] as? Bool, true)
    }

    func testUnknownMethodReturnsTypedError() throws {
        server = try makeServer()
        let reply = try clientCall([
            "id": "1", "method": "make_dinner",
            "auth_token": "T",
            "params": [:],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "unknown_method")
    }

    func testGateOffBlocksGatedMethods() throws {
        server = try makeServer(token: "T", enabled: false)
        // start_session is gated; even with auth_token it must
        // refuse when local_control_enabled is false.
        let reply = try clientCall([
            "id": "1", "method": "start_session",
            "auth_token": "T",
            "params": ["provider": "claude"],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "local_control_off")
    }

    /// hello bypasses the gate (used for capability negotiation
    /// before the user has even seen the toggle).
    func testHelloBypassesGate() throws {
        server = try makeServer(token: "T", enabled: false)
        let reply = try clientCall(["id": "1", "method": "hello", "params": [:]])
        XCTAssertEqual(reply["ok"] as? Bool, true)
    }

    /// Hook auth-table enforcement: app token rejected on
    /// hook_create_approval. Symmetric to the Python check.
    func testHookMethodRejectsAppToken() throws {
        server = try makeServer(token: "T")
        let reply = try clientCall([
            "id": "1", "method": "hook_create_approval",
            "auth_token": "T",     // app token, NOT session_token
            "params": [:],
        ])
        XCTAssertEqual(reply["ok"] as? Bool, false)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "bad_request")
    }

    /// P1#3 regression: a SECOND server on a live socket must REFUSE to bind
    /// (not unlink the live one). This is the "helper running in Activity
    /// Monitor but app reports not detected" race during an update/restart
    /// overlap — the old code unconditionally unlinked any existing socket.
    func testStartRefusesToUnlinkALiveSocket() throws {
        let s1 = try makeServer(token: "T")
        server = s1   // tearDown stops it
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")

        let s2 = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sockPath),
            hooks: LocalSessionServer.Hooks(getAuthToken: { "T" })
        )
        XCTAssertThrowsError(try s2.start()) { err in
            guard case LocalSessionServer.ServerError.alreadyRunning = err else {
                return XCTFail("expected .alreadyRunning, got \(err)")
            }
        }
        // The live server's socket must survive AND still answer.
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath.path))
        let reply = try clientCall(["id": "1", "method": "hello"])
        XCTAssertFalse(reply.isEmpty,
                       "live server should still answer after the 2nd start was refused")
    }

    /// A stale/dead socket FILE (no listener) must be cleaned + bound, NOT
    /// treated as a live server — else a leftover from a crash would
    /// permanently block startup.
    func testStartCleansStaleDeadSocketFile() throws {
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        XCTAssertTrue(FileManager.default.createFile(atPath: sockPath.path, contents: Data()))
        // start() must connect-probe (fails → stale), unlink, and bind cleanly.
        server = try makeServer(token: "T")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sockPath.path))
    }

    // MARK: - #18c: install / uninstall_claude_hook verbs (re-activated)

    private func tmpSettings() -> URL {
        sockDir.appendingPathComponent("claude-\(UUID().uuidString)").appendingPathComponent("settings.json")
    }

    func testInstallClaudeHookWritesBothEvents() throws {
        let settings = tmpSettings()
        server = try makeServer(token: "T", helperArgv0: "/h/cli_pulse_helper", settingsPath: settings)
        let reply = try clientCall(["id": "1", "method": "install_claude_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertTrue(reply["ok"] as? Bool ?? false, "\(reply)")
        let result = reply["result"] as! [String: Any]
        XCTAssertEqual(result["action"] as? String, "created")
        // both events written to the tmp settings file
        let data = try Data(contentsOf: settings)
        let hooks = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["hooks"] as! [String: Any]
        XCTAssertNotNil(hooks["PermissionRequest"])
        XCTAssertNotNil(hooks["PreToolUse"])
    }

    func testInstallClaudeHookNoArgv0ReturnsNotImplemented() throws {
        server = try makeServer(token: "T")  // no helperArgv0
        let reply = try clientCall(["id": "1", "method": "install_claude_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertFalse(reply["ok"] as? Bool ?? true)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "not_implemented")
    }

    func testUninstallClaudeHookRoundTrip() throws {
        let settings = tmpSettings()
        server = try makeServer(token: "T", helperArgv0: "/h/cli_pulse_helper", settingsPath: settings)
        _ = try clientCall(["id": "1", "method": "install_claude_hook", "auth_token": "T", "params": [:]])
        let reply = try clientCall(["id": "2", "method": "uninstall_claude_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertTrue(reply["ok"] as? Bool ?? false, "\(reply)")
        let result = reply["result"] as! [String: Any]
        XCTAssertEqual(result["action"] as? String, "removed")
        XCTAssertEqual(result["removed"] as? Int, 2)
    }

    func testUninstallClaudeHookRequiresAuth() throws {
        server = try makeServer(token: "T")
        let reply = try clientCall(["id": "1", "method": "uninstall_claude_hook", "params": [:]])
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "unauthenticated")
    }

    func testUninstallClaudeHookBlockedWhenGateOff() throws {
        server = try makeServer(token: "T", enabled: false)
        let reply = try clientCall(["id": "1", "method": "uninstall_claude_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "local_control_off")
    }

    func testHelloAdvertisesUninstallClaudeHook() throws {
        server = try makeServer()
        let reply = try clientCall(["id": "1", "method": "hello", "params": [:]])
        let supported = (reply["result"] as! [String: Any])["supported_methods"] as! [String]
        XCTAssertTrue(supported.contains("uninstall_claude_hook"))
    }

    // MARK: - M2p2: install / uninstall_codex_hook verbs

    private func tmpCodexSettings() -> URL {
        sockDir.appendingPathComponent("codex-\(UUID().uuidString)").appendingPathComponent("hooks.json")
    }

    func testInstallCodexHookWritesBothEventsAndTrustPayload() throws {
        let codexSettings = tmpCodexSettings()
        server = try makeServer(token: "T", helperArgv0: "/h/cli_pulse_helper",
                                codexSettingsPath: codexSettings)
        let reply = try clientCall(["id": "1", "method": "install_codex_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertTrue(reply["ok"] as? Bool ?? false, "\(reply)")
        let result = reply["result"] as! [String: Any]
        XCTAssertEqual(result["action"] as? String, "created")
        // The self-describing trust step (Python #357 payload parity): Codex
        // hash-pins + silently skips an untrusted command hook — the client
        // MUST render the one-time /hooks step.
        XCTAssertEqual(result["requires_manual_trust"] as? Bool, true)
        XCTAssertEqual(result["trust_command"] as? String, "/hooks")
        // Both events written with the CODEX marker.
        let data = try Data(contentsOf: codexSettings)
        let hooks = (try JSONSerialization.jsonObject(with: data) as! [String: Any])["hooks"] as! [String: Any]
        for event in ["PermissionRequest", "PreToolUse"] {
            let entries = hooks[event] as! [[String: Any]]
            XCTAssertEqual(entries.count, 1)
            let cmd = ((entries[0]["hooks"] as! [[String: Any]])[0]["command"] as! String)
            XCTAssertTrue(cmd.contains("remote-approval-hook --provider codex"), cmd)
        }
    }

    func testInstallCodexHookNoArgv0ReturnsNotImplemented() throws {
        server = try makeServer(token: "T")  // no helperArgv0
        let reply = try clientCall(["id": "1", "method": "install_codex_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertFalse(reply["ok"] as? Bool ?? true)
        XCTAssertEqual((reply["error"] as? [String: Any])?["code"] as? String, "not_implemented")
    }

    func testUninstallCodexHookRoundTrip() throws {
        let codexSettings = tmpCodexSettings()
        server = try makeServer(token: "T", helperArgv0: "/h/cli_pulse_helper",
                                codexSettingsPath: codexSettings)
        _ = try clientCall(["id": "1", "method": "install_codex_hook", "auth_token": "T", "params": [:]])
        let reply = try clientCall(["id": "2", "method": "uninstall_codex_hook",
                                    "auth_token": "T", "params": [:]])
        XCTAssertTrue(reply["ok"] as? Bool ?? false, "\(reply)")
        let result = reply["result"] as! [String: Any]
        XCTAssertEqual(result["action"] as? String, "removed")
        XCTAssertEqual(result["removed"] as? Int, 2)
    }

    func testCodexVerbsGatedLikeClaude() throws {
        // Same app-auth + local-control gating as the claude verbs.
        server = try makeServer(token: "T", enabled: false)
        let gateOff = try clientCall(["id": "1", "method": "install_codex_hook",
                                      "auth_token": "T", "params": [:]])
        XCTAssertEqual((gateOff["error"] as? [String: Any])?["code"] as? String, "local_control_off")
        server?.stop()
        server = try makeServer(token: "T")
        let noAuth = try clientCall(["id": "2", "method": "uninstall_codex_hook", "params": [:]])
        XCTAssertEqual((noAuth["error"] as? [String: Any])?["code"] as? String, "unauthenticated")
    }

    func testHelloAdvertisesCodexHookVerbs() throws {
        server = try makeServer()
        let reply = try clientCall(["id": "1", "method": "hello", "params": [:]])
        let supported = (reply["result"] as! [String: Any])["supported_methods"] as! [String]
        XCTAssertTrue(supported.contains("install_codex_hook"))
        XCTAssertTrue(supported.contains("uninstall_codex_hook"))
    }
}
