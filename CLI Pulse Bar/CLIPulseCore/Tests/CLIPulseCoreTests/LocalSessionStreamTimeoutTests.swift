import XCTest
import Darwin
@testable import CLIPulseCore

#if os(macOS)

/// Phase 3 Iter 2B regression test for `LocalSessionControlClient.subscribeEvents`.
///
/// Codex review on PR #18 caught a frame-loss bug: the streaming
/// loop was using the same 5s `requestTimeout` watchdog as one-shot
/// RPCs. When the helper went idle longer than 5s (heartbeat is
/// 15s, so the gap is normal under realistic Claude usage), the
/// receive watchdog would fire, the loop would `continue`, and a
/// fresh `conn.receive(...)` would be scheduled on top of the still-
/// pending one. When the next frame eventually arrived the OLD
/// (already-resumed) callback consumed the bytes silently and the
/// new receive saw nothing.
///
/// This test exercises the contract end-to-end against a real
/// AF_UNIX socket so the no-timeout receive path is verified at the
/// wire level rather than only in mocked unit-tests.
final class LocalSessionStreamTimeoutTests: XCTestCase {

    /// Stream-receive must not drop a frame the helper sends after
    /// an idle period longer than `requestTimeout`. With
    /// `requestTimeout = 1s` and a 2s idle gap, the post-idle event
    /// frame must still be delivered to the consumer.
    func testEventArrivesAfterIdleLongerThanRequestTimeout() async throws {
        let env = try FakeUDSServer.startStreamScenario { send in
            // 1. Initial ack frame (synthesised snapshot reply).
            try send.ack(initial: ["managed_sessions": [], "pending_approvals": []])
            // 2. Idle longer than the client's per-call timeout.
            //    With the bug this is exactly the gap that loses
            //    the next frame. With the fix the receive call has
            //    no watchdog, so the bytes survive.
            Thread.sleep(forTimeInterval: 2.0)
            // 3. A real output_delta event after the gap.
            try send.event([
                "event": "output_delta",
                "session_id": "SID-A",
                "payload": "hello-after-idle",
                "ts": 1.0,
            ])
        }
        defer { env.shutdown() }

        let client = LocalSessionControlClient(
            socketPath: env.socketPath,
            tokenPath: env.tokenPath,
            connectTimeout: 2,
            requestTimeout: 1.0   // shorter than the idle gap above
        )
        let stream = client.subscribeEvents(sessionId: "SID-A")
        let collector = Task<[LocalSessionEvent], Error> {
            var collected: [LocalSessionEvent] = []
            for try await event in stream {
                collected.append(event)
                if collected.count >= 2 { break }   // ack + post-idle event
            }
            return collected
        }
        // Cap the test runtime — cancel the collector if the
        // stream hasn't produced both frames within a generous
        // window. With the fix the second frame should arrive
        // within ~2.1s of subscribe; we wait up to 5s.
        let timeout = Task<Void, Error> {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            collector.cancel()
        }
        defer { timeout.cancel() }

        let collected = try await collector.value
        XCTAssertGreaterThanOrEqual(collected.count, 2,
                                    "expected ack + post-idle event, got \(collected.count)")
        guard case .subscribed = collected[0] else {
            XCTFail("expected first event to be .subscribed ack; got \(collected[0])")
            return
        }
        guard case .outputDelta(let sid, let payload, _) = collected[1] else {
            XCTFail("expected .outputDelta after idle; got \(collected[1])")
            return
        }
        XCTAssertEqual(sid, "SID-A")
        XCTAssertEqual(payload, "hello-after-idle")
    }
}

// MARK: - Fake UDS server

/// Minimal AF_UNIX server used by this test. Speaks the helper's
/// wire format (4-byte big-endian length prefix + UTF-8 JSON body)
/// just enough to satisfy `subscribeEvents`. The scenario closure
/// runs on a background thread; it gets a `Sender` it uses to
/// write framed JSON onto the accepted client socket.
private struct FakeUDSServer {

    final class Environment {
        let socketPath: String
        let tokenPath: String
        private let serverFD: Int32
        private let holder: ScenarioHolder

        init(socketPath: String, tokenPath: String, serverFD: Int32, holder: ScenarioHolder) {
            self.socketPath = socketPath
            self.tokenPath = tokenPath
            self.serverFD = serverFD
            self.holder = holder
        }

        func shutdown() {
            Darwin.shutdown(serverFD, SHUT_RDWR)
            close(serverFD)
            holder.shutdownClient()
            try? FileManager.default.removeItem(atPath: socketPath)
            try? FileManager.default.removeItem(atPath: tokenPath)
        }
    }

    final class ScenarioHolder {
        var clientFD: Int32 = -1
        let lock = NSLock()
        func shutdownClient() {
            lock.lock(); defer { lock.unlock() }
            if clientFD >= 0 {
                Darwin.shutdown(clientFD, SHUT_RDWR)
                close(clientFD)
                clientFD = -1
            }
        }
    }

    struct Sender {
        let fd: Int32

        func ack(initial: [String: Any]) throws {
            // Helper streaming ack envelope:
            // {"id":..., "ok":true, "result":{...snapshot...}}
            let envelope: [String: Any] = [
                "id": "ack",
                "ok": true,
                "result": initial,
            ]
            try writeFrame(JSONSerialization.data(withJSONObject: envelope))
        }

        func event(_ event: [String: Any]) throws {
            // Live frames are bare event dicts, NOT wrapped in
            // ok/result — matches the helper's `_stream_loop`.
            try writeFrame(JSONSerialization.data(withJSONObject: event))
        }

        private func writeFrame(_ body: Data) throws {
            var length = UInt32(body.count).bigEndian
            let header = Data(bytes: &length, count: 4)
            try sendAll(header)
            try sendAll(body)
        }

        private func sendAll(_ data: Data) throws {
            try data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var sent = 0
                while sent < data.count {
                    let n = Darwin.send(fd, base.advanced(by: sent), data.count - sent, 0)
                    if n <= 0 {
                        throw NSError(domain: "FakeUDSServer", code: 1, userInfo: nil)
                    }
                    sent += n
                }
            }
        }
    }

    static func startStreamScenario(scenario: @escaping (Sender) throws -> Void) throws -> Environment {
        let dir = NSTemporaryDirectory()
        let unique = UUID().uuidString.prefix(8)
        let socketPath = "\(dir)cps-stream-\(unique).sock"
        let tokenPath = "\(dir)cps-token-\(unique).txt"
        // Token contents don't matter — the fake server doesn't
        // validate auth, but the client refuses to send any
        // authenticated method without a non-empty token file.
        try "T".write(toFile: tokenPath, atomically: true, encoding: .utf8)

        let serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw NSError(domain: "FakeUDSServer", code: 2, userInfo: nil)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        precondition(pathBytes.count < 104, "socket path too long")
        withUnsafeMutablePointer(to: &addr.sun_path) { tuple in
            tuple.withMemoryRebound(to: CChar.self, capacity: 104) { cstr in
                for (i, byte) in pathBytes.enumerated() {
                    cstr[i] = CChar(bitPattern: byte)
                }
                cstr[pathBytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, len)
            }
        }
        guard bindResult == 0 else {
            close(serverFD)
            throw NSError(domain: "FakeUDSServer", code: 3, userInfo: [NSLocalizedDescriptionKey: "bind failed: \(errno)"])
        }
        guard listen(serverFD, 1) == 0 else {
            close(serverFD)
            throw NSError(domain: "FakeUDSServer", code: 4, userInfo: nil)
        }
        let holder = ScenarioHolder()
        let serverThread = Thread {
            let clientFD = accept(serverFD, nil, nil)
            holder.lock.lock()
            holder.clientFD = clientFD
            holder.lock.unlock()
            guard clientFD >= 0 else { return }
            // Drain the client's subscribe_events request frame so
            // the kernel doesn't stall the client's send. We don't
            // validate it.
            var header = [UInt8](repeating: 0, count: 4)
            _ = Darwin.recv(clientFD, &header, 4, MSG_WAITALL)
            let bodyLen = Int((UInt32(header[0]) << 24)
                              | (UInt32(header[1]) << 16)
                              | (UInt32(header[2]) << 8)
                              | UInt32(header[3]))
            if bodyLen > 0 && bodyLen < 1 << 20 {
                var bodyBuf = [UInt8](repeating: 0, count: bodyLen)
                _ = Darwin.recv(clientFD, &bodyBuf, bodyLen, MSG_WAITALL)
            }
            let sender = Sender(fd: clientFD)
            do {
                try scenario(sender)
            } catch {
                // Scenario error is non-fatal; shutdown closes the
                // socket so the client exits cleanly.
            }
        }
        serverThread.start()
        return Environment(
            socketPath: socketPath,
            tokenPath: tokenPath,
            serverFD: serverFD,
            holder: holder
        )
    }
}

#endif
