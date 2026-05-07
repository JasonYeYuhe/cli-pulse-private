import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// End-to-end streaming test: spin up a real server with a real
/// broker, subscribe via UDS, publish from another thread, decode
/// frames on the client side. Pin the wire-shape invariants the
/// macOS app's `LocalSessionControlClient.subscribeEvents` decodes
/// against.
final class StreamingTests: XCTestCase {

    private var sockDir: URL!

    override func setUp() {
        super.setUp()
        let parent = FileManager.default.fileExists(atPath: "/tmp") ? "/tmp" : NSTemporaryDirectory()
        sockDir = URL(fileURLWithPath: parent)
            .appendingPathComponent("clipulse-stream-tests-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: sockDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sockDir)
        super.tearDown()
    }

    private func makeServer(broker: EventBroker, registry: ApprovalRegistry, manager: ManagedSessionManager? = nil)
        throws -> (LocalSessionServer, URL)
    {
        let sockPath = sockDir.appendingPathComponent("clipulse-helper.sock")
        let server = LocalSessionServer(
            config: LocalSessionServer.Configuration(socketPath: sockPath),
            hooks: LocalSessionServer.Hooks(
                getAuthToken: { "T" },
                isLocalControlEnabled: { true },
                setLocalControlEnabled: { _ in },
                sessionManager: manager,
                listDetectedSessions: { [] },
                approvalRegistry: registry,
                eventBroker: broker
            )
        )
        try server.start()
        usleep(50_000)
        return (server, sockPath)
    }

    private func clientConnect(_ sockPath: URL) -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = (sockPath.path as NSString).fileSystemRepresentation
        let len = strlen(path)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            memcpy(ptr.baseAddress!, path, len)
        }
        let r = withUnsafePointer(to: &addr) { ap -> Int32 in
            ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(r, 0)
        return fd
    }

    func testSubscribeReturnsAckWithSnapshotThenStreamsLiveEvents() throws {
        let broker = EventBroker()
        let registry = ApprovalRegistry()
        let (server, sockPath) = try makeServer(broker: broker, registry: registry)
        defer { server.stop() }

        let fd = clientConnect(sockPath)
        defer { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }

        // Send subscribe_events.
        let req: [String: Any] = [
            "id": "1",
            "method": "subscribe_events",
            "auth_token": "T",
            "params": [:],
        ]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        try Framing.writeFrame(to: fd, body: reqData)

        // Read the ack frame.
        guard let ack = try Framing.readFrame(from: fd) else {
            XCTFail("expected ack frame, got EOF"); return
        }
        let ackDict = try JSONSerialization.jsonObject(with: ack) as! [String: Any]
        XCTAssertEqual(ackDict["ok"] as? Bool, true)
        let result = ackDict["result"] as? [String: Any]
        XCTAssertEqual(result?["subscribed"] as? Bool, true)
        XCTAssertNotNil(result?["managed_sessions"])
        XCTAssertNotNil(result?["pending_approvals"])

        // Publish a couple events from the helper side.
        broker.publish([
            "event": "output_delta",
            "session_id": "S1",
            "payload": "hello",
            "ts": 1.0,
        ])
        broker.publishToAll([
            "event": "heartbeat",
            "ts": 2.0,
        ])

        // Read both frames; order is FIFO.
        guard let f1 = try Framing.readFrame(from: fd),
              let f2 = try Framing.readFrame(from: fd) else {
            XCTFail("expected 2 streamed events"); return
        }
        let e1 = try JSONSerialization.jsonObject(with: f1) as! [String: Any]
        let e2 = try JSONSerialization.jsonObject(with: f2) as! [String: Any]
        XCTAssertEqual(e1["event"] as? String, "output_delta")
        XCTAssertEqual(e1["session_id"] as? String, "S1")
        XCTAssertEqual(e2["event"] as? String, "heartbeat")
    }

    func testSubscribeRespectsSessionFilter() throws {
        let broker = EventBroker()
        let registry = ApprovalRegistry()
        let (server, sockPath) = try makeServer(broker: broker, registry: registry)
        defer { server.stop() }
        let fd = clientConnect(sockPath)
        defer { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        let req: [String: Any] = [
            "id": "1",
            "method": "subscribe_events",
            "auth_token": "T",
            "params": ["session_id": "WANTED"],
        ]
        try Framing.writeFrame(to: fd, body: try JSONSerialization.data(withJSONObject: req))
        _ = try Framing.readFrame(from: fd)   // ack

        // Publish to a different session — must NOT be delivered.
        broker.publish([
            "event": "output_delta",
            "session_id": "OTHER",
            "payload": "should not arrive",
            "ts": 1.0,
        ])
        // Then publish to the wanted session.
        broker.publish([
            "event": "output_delta",
            "session_id": "WANTED",
            "payload": "yes please",
            "ts": 2.0,
        ])

        // Read one frame; it should be the WANTED-session event,
        // NOT the OTHER one (filtering blocks it before it ever
        // hits the per-connection queue).
        let f = try Framing.readFrame(from: fd)
        XCTAssertNotNil(f)
        let e = try JSONSerialization.jsonObject(with: f!) as! [String: Any]
        XCTAssertEqual(e["session_id"] as? String, "WANTED")
        XCTAssertEqual(e["payload"] as? String, "yes please")
    }

    func testSubscribeRejectsMissingAuthToken() throws {
        let broker = EventBroker()
        let registry = ApprovalRegistry()
        let (server, sockPath) = try makeServer(broker: broker, registry: registry)
        defer { server.stop() }
        let fd = clientConnect(sockPath)
        defer { Darwin.shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        let req: [String: Any] = [
            "id": "1",
            "method": "subscribe_events",
            "params": [:],
        ]
        try Framing.writeFrame(to: fd, body: try JSONSerialization.data(withJSONObject: req))
        guard let ack = try Framing.readFrame(from: fd) else {
            XCTFail("expected error ack frame"); return
        }
        let dict = try JSONSerialization.jsonObject(with: ack) as! [String: Any]
        XCTAssertEqual(dict["ok"] as? Bool, false)
        XCTAssertEqual((dict["error"] as? [String: Any])?["code"] as? String, "unauthenticated")
    }
}
