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

    private func makeServer(token: String = "T", enabled: Bool = true) throws -> LocalSessionServer {
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        let enabledBox = AtomicBool()
        enabledBox.set(enabled)
        let s = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sockPath),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { token },
                isLocalControlEnabled: { enabledBox.get() },
                setLocalControlEnabled: { enabledBox.set($0) }
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
}
