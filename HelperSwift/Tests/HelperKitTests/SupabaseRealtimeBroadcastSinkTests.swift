import XCTest
@testable import HelperKit

/// Pins the HTTP wire shape of `SupabaseRealtimeBroadcastSink`
/// against the Supabase Realtime broadcast endpoint contract
/// (`<url>/realtime/v1/api/broadcast`). Uses the shared
/// `InterceptProtocol` from `SupabaseRPCCallerTests.swift` for
/// URLSession interception.
final class SupabaseRealtimeBroadcastSinkTests: XCTestCase {

    override func setUp() {
        super.setUp()
        InterceptProtocol.reset()
        URLProtocol.registerClass(InterceptProtocol.self)
    }

    override func tearDown() {
        URLProtocol.unregisterClass(InterceptProtocol.self)
        InterceptProtocol.reset()
        super.tearDown()
    }

    private func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [InterceptProtocol.self]
        cfg.timeoutIntervalForRequest = 2.5
        return URLSession(configuration: cfg)
    }

    private static let cloud = HelperConfigStore.CloudConfig(
        deviceId: "11111111-2222-3333-4444-555555555555",
        helperSecret: "stub-secret",
        supabaseURL: "https://example.supabase.co",
        supabaseAnonKey: "anon-key"
    )

    private static let unpaired = HelperConfigStore.CloudConfig(
        deviceId: "",
        helperSecret: "",
        supabaseURL: "",
        supabaseAnonKey: ""
    )

    // MARK: endpoint + headers

    func test_publish_posts_to_realtime_broadcast_endpoint() async throws {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 202,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data(#"{"message":"ok"}"#.utf8))
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        try await sink.publish(
            sessionId: "abc",
            channel: "term:abc",
            event: "stdout",
            redactedBytes: Data("hello".utf8)
        )
        let recorded = InterceptProtocol.lastRequest
        XCTAssertEqual(
            recorded?.url?.absoluteString,
            "https://example.supabase.co/realtime/v1/api/broadcast"
        )
        XCTAssertEqual(recorded?.httpMethod, "POST")
    }

    func test_publish_sets_apikey_and_bearer_headers() async throws {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 202,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data())
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        try await sink.publish(
            sessionId: "abc", channel: "term:abc",
            event: "stdout", redactedBytes: Data("h".utf8)
        )
        let recorded = InterceptProtocol.lastRequest
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(
            recorded?.value(forHTTPHeaderField: "Authorization"),
            "Bearer anon-key"
        )
        XCTAssertEqual(
            recorded?.value(forHTTPHeaderField: "Content-Type"),
            "application/json"
        )
    }

    // MARK: body shape (the wire contract iOS subscriber depends on)

    func test_publish_body_uses_messages_array_with_topic_event_payload() async throws {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 202,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data())
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        try await sink.publish(
            sessionId: "sid-42",
            channel: "term:sid-42",
            event: "stderr",
            redactedBytes: Data("ls -la\n".utf8)
        )
        let bodyData = InterceptProtocol.lastBodyData ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let messages = decoded?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        let first = messages?.first
        XCTAssertEqual(first?["topic"] as? String, "term:sid-42")
        XCTAssertEqual(first?["event"] as? String, "stderr")
        let payload = first?["payload"] as? [String: Any]
        XCTAssertEqual(payload?["session_id"] as? String, "sid-42")
    }

    func test_publish_payload_is_base64_of_redacted_bytes() async throws {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 202,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data())
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        // Include arbitrary byte that wouldn't survive a naïve
        // UTF-8 round-trip (0xFF) — base64 is the only safe wire
        // shape for terminal chunks that may include partial
        // multi-byte boundaries.
        let raw = Data([0x68, 0x69, 0xFF, 0x0A])
        try await sink.publish(
            sessionId: "x", channel: "term:x",
            event: "stdout", redactedBytes: raw
        )
        let bodyData = InterceptProtocol.lastBodyData ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        let payload = (decoded?["messages"] as? [[String: Any]])?
            .first?["payload"] as? [String: Any]
        let b64 = payload?["data_b64"] as? String ?? ""
        XCTAssertEqual(Data(base64Encoded: b64), raw)
    }

    // MARK: error mapping

    func test_publish_throws_notConfigured_when_unpaired() async {
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.unpaired },
            session: makeSession()
        )
        do {
            try await sink.publish(
                sessionId: "x", channel: "term:x",
                event: "stdout", redactedBytes: Data("h".utf8)
            )
            XCTFail("expected SinkError.notConfigured")
        } catch SupabaseRealtimeBroadcastSink.SinkError.notConfigured {
            // ok
        } catch {
            XCTFail("got \(error), expected notConfigured")
        }
    }

    func test_publish_throws_http_on_4xx() async {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data("unauthorized".utf8))
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        do {
            try await sink.publish(
                sessionId: "x", channel: "term:x",
                event: "stdout", redactedBytes: Data("h".utf8)
            )
            XCTFail("expected http error")
        } catch SupabaseRealtimeBroadcastSink.SinkError.http(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("unauthorized"))
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test_publish_throws_http_on_5xx() async {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data("upstream brake".utf8))
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        do {
            try await sink.publish(
                sessionId: "x", channel: "term:x",
                event: "stdout", redactedBytes: Data("h".utf8)
            )
            XCTFail("expected http error")
        } catch SupabaseRealtimeBroadcastSink.SinkError.http(let status, _) {
            XCTAssertEqual(status, 503)
        } catch {
            XCTFail("got \(error)")
        }
    }

    // MARK: integration with publisher (drop-oldest contract preserved)

    func test_sink_failure_increments_publisher_droppedSinceStart() async {
        // The publisher swallows sink throws and bumps
        // droppedSinceStart — this pins the contract between the
        // two so a future refactor doesn't reintroduce retry-on-error
        // (which would back-pressure the drain loop).
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data())
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s", chunk: Data("hi".utf8))
        await pub.awaitDrained()
        let dropped = await pub.droppedSinceStart
        let published = await pub.publishedSinceStart
        XCTAssertEqual(dropped, 1)
        XCTAssertEqual(published, 0)
    }

    func test_sink_success_increments_publisher_publishedSinceStart() async {
        InterceptProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 202,
                             httpVersion: "HTTP/1.1", headerFields: [:])!,
             Data())
        }
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        let pub = TerminalBroadcastPublisher(sink: sink)
        await pub.submit(sessionId: "s", chunk: Data("hi".utf8))
        await pub.awaitDrained()
        let dropped = await pub.droppedSinceStart
        let published = await pub.publishedSinceStart
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(published, 1)
    }
}
