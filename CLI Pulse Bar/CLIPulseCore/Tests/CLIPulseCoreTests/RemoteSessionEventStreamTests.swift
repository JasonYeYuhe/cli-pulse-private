import XCTest
@testable import CLIPulseCore

/// Pins the Phoenix vsn-2.0.0 wire shape `RemoteSessionEventStream`
/// produces and consumes. The live WebSocket path is integration-
/// tested manually against a real Supabase project — these tests
/// cover only the static parse/encode helpers so a refactor can't
/// silently break compatibility with the Realtime broker.
final class RemoteSessionEventStreamTests: XCTestCase {

    // MARK: - URL builder

    func test_makeWebSocketURL_swaps_https_to_wss() throws {
        let url = try RemoteSessionEventStream.makeWebSocketURL(
            config: .init(
                supabaseURL: "https://abc.supabase.co",
                supabaseAnonKey: "anon-key"
            )
        )
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "abc.supabase.co")
        XCTAssertEqual(url.path, "/realtime/v1/websocket")
        let q = url.query ?? ""
        XCTAssertTrue(q.contains("apikey=anon-key"), "missing apikey: \(q)")
        XCTAssertTrue(q.contains("vsn=2.0.0"), "missing vsn=2.0.0: \(q)")
    }

    func test_makeWebSocketURL_swaps_http_to_ws_for_local_dev() throws {
        let url = try RemoteSessionEventStream.makeWebSocketURL(
            config: .init(
                supabaseURL: "http://localhost:54321",
                supabaseAnonKey: "k"
            )
        )
        XCTAssertEqual(url.scheme, "ws")
        XCTAssertEqual(url.port, 54321)
    }

    func test_makeWebSocketURL_throws_notConfigured_on_empty() {
        XCTAssertThrowsError(try RemoteSessionEventStream.makeWebSocketURL(
            config: .init(supabaseURL: "", supabaseAnonKey: "k"))
        ) { err in
            XCTAssertEqual(err as? RemoteSessionEventStream.StreamError, .notConfigured)
        }
        XCTAssertThrowsError(try RemoteSessionEventStream.makeWebSocketURL(
            config: .init(supabaseURL: "https://x", supabaseAnonKey: ""))
        ) { err in
            XCTAssertEqual(err as? RemoteSessionEventStream.StreamError, .notConfigured)
        }
    }

    func test_makeWebSocketURL_throws_malformedURL_on_no_scheme() {
        XCTAssertThrowsError(try RemoteSessionEventStream.makeWebSocketURL(
            config: .init(supabaseURL: "abc.supabase.co", supabaseAnonKey: "k"))
        ) { err in
            XCTAssertEqual(err as? RemoteSessionEventStream.StreamError, .malformedURL)
        }
    }

    func test_makeWebSocketURL_handles_trailing_slash() throws {
        let url = try RemoteSessionEventStream.makeWebSocketURL(
            config: .init(supabaseURL: "https://abc.supabase.co/", supabaseAnonKey: "k")
        )
        XCTAssertEqual(url.path, "/realtime/v1/websocket",
                       "trailing slash on base must not produce //realtime/...")
    }

    // MARK: - phx_join encoder

    func test_encodePhxJoinFrame_array_shape_and_topic_prefix() throws {
        let data = try RemoteSessionEventStream.encodePhxJoinFrame(
            joinRef: "100",
            ref: "1",
            sessionId: "sid-42"
        )
        let arr = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [Any]
        )
        XCTAssertEqual(arr.count, 5, "vsn-2.0.0 frame is a 5-tuple")
        XCTAssertEqual(arr[0] as? String, "100", "joinRef")
        XCTAssertEqual(arr[1] as? String, "1", "ref")
        XCTAssertEqual(arr[2] as? String, "realtime:term:sid-42",
                       "topic must include realtime: prefix Phoenix routing expects")
        XCTAssertEqual(arr[3] as? String, "phx_join")
    }

    func test_encodePhxJoinFrame_config_disables_self_broadcast() throws {
        // We must NOT receive our own broadcasts back — only the
        // helper publishes; the iOS subscriber is read-only on
        // this channel. (Even if we did call broadcast(), the
        // helper-side sink uses HTTP not WS, so self-broadcast
        // wouldn't trigger anyway — but the config makes the
        // intent explicit and rules out a future regression.)
        let data = try RemoteSessionEventStream.encodePhxJoinFrame(
            joinRef: "j", ref: "r", sessionId: "x"
        )
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        let payload = try XCTUnwrap(arr[4] as? [String: Any])
        let cfg = try XCTUnwrap(payload["config"] as? [String: Any])
        let bcast = try XCTUnwrap(cfg["broadcast"] as? [String: Any])
        XCTAssertEqual(bcast["self"] as? Bool, false)
        XCTAssertEqual(bcast["ack"] as? Bool, false)
        // private:false matches the helper sink's payload.private:
        // false (or omitted — server defaults to false).
        XCTAssertEqual(cfg["private"] as? Bool, false)
    }

    // MARK: - R0 (B3) private join + token

    func test_topic_picks_pterm_for_private_and_term_for_public() {
        XCTAssertEqual(
            RemoteSessionEventStream.topic(for: "sid-1", isPrivate: true),
            "pterm:sid-1")
        XCTAssertEqual(
            RemoteSessionEventStream.topic(for: "sid-1", isPrivate: false),
            "term:sid-1")
    }

    func test_encodePhxJoinFrame_private_uses_pterm_and_attaches_token() throws {
        let data = try RemoteSessionEventStream.encodePhxJoinFrame(
            joinRef: "j", ref: "r", sessionId: "sid-9",
            isPrivate: true, accessToken: "user-jwt-abc"
        )
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        // Distinct PRIVATE prefix — the RLS-governed topic.
        XCTAssertEqual(arr[2] as? String, "realtime:pterm:sid-9")
        let payload = try XCTUnwrap(arr[4] as? [String: Any])
        let cfg = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(cfg["private"] as? Bool, true)
        // access_token sits at the payload top level (sibling of config) so
        // Realtime evaluates realtime.messages read-RLS as the owner.
        XCTAssertEqual(payload["access_token"] as? String, "user-jwt-abc")
    }

    func test_encodePhxJoinFrame_public_omits_token_even_when_passed() throws {
        // Zero-regression invariant: the PUBLIC frame must stay byte-identical
        // to pre-R0 — no access_token leaks onto the public `term:` channel
        // even if a token is supplied.
        let data = try RemoteSessionEventStream.encodePhxJoinFrame(
            joinRef: "j", ref: "r", sessionId: "sid-9",
            isPrivate: false, accessToken: "user-jwt-abc"
        )
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(arr[2] as? String, "realtime:term:sid-9")
        let payload = try XCTUnwrap(arr[4] as? [String: Any])
        XCTAssertNil(payload["access_token"], "public join must NOT carry a token")
        let cfg = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(cfg["private"] as? Bool, false)
    }

    func test_encodePhxJoinFrame_private_without_token_omits_key() throws {
        // A private join with no token yet (e.g. not signed in) must not emit
        // an empty/garbage access_token — better to fail closed at the server.
        let data = try RemoteSessionEventStream.encodePhxJoinFrame(
            joinRef: "j", ref: "r", sessionId: "s", isPrivate: true, accessToken: nil)
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        let payload = try XCTUnwrap(arr[4] as? [String: Any])
        XCTAssertNil(payload["access_token"])
        let cfg = try XCTUnwrap(payload["config"] as? [String: Any])
        XCTAssertEqual(cfg["private"] as? Bool, true)
    }

    func test_encodeAccessTokenFrame_shape() throws {
        let data = try RemoteSessionEventStream.encodeAccessTokenFrame(
            joinRef: "j", ref: "5", sessionId: "sid-9", accessToken: "fresh-jwt")
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(arr.count, 5)
        XCTAssertEqual(arr[0] as? String, "j")
        XCTAssertEqual(arr[1] as? String, "5")
        // Refresh always targets the PRIVATE topic (only private joins carry a token).
        XCTAssertEqual(arr[2] as? String, "realtime:pterm:sid-9")
        XCTAssertEqual(arr[3] as? String, "access_token")
        let payload = try XCTUnwrap(arr[4] as? [String: Any])
        XCTAssertEqual(payload["access_token"] as? String, "fresh-jwt")
    }

    // MARK: - heartbeat encoder

    func test_encodeHeartbeatFrame_shape() throws {
        let data = try RemoteSessionEventStream.encodeHeartbeatFrame(ref: "26")
        let arr = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(arr.count, 5)
        XCTAssertTrue(arr[0] is NSNull, "heartbeat joinRef must be null")
        XCTAssertEqual(arr[1] as? String, "26")
        XCTAssertEqual(arr[2] as? String, "phoenix",
                       "heartbeat targets the system 'phoenix' topic")
        XCTAssertEqual(arr[3] as? String, "heartbeat")
        let payload = try XCTUnwrap(arr[4] as? [String: Any])
        XCTAssertEqual(payload.count, 0, "heartbeat payload is empty")
    }

    // MARK: - broadcast decoder

    func test_decodeBroadcastChunk_extracts_event_and_bytes() throws {
        // Shape matches what slice-3 SupabaseRealtimeBroadcastSink
        // POSTs (inner event="stdout", payload={session_id, data_b64})
        // and what Supabase Realtime wraps before delivering.
        let raw = "hello world\n"
        let b64 = Data(raw.utf8).base64EncodedString()
        let envelope: [Any] = [
            NSNull(), NSNull(),
            "realtime:term:sid-42",
            "broadcast",
            [
                "event": "stdout",
                "type": "broadcast",
                "payload": [
                    "session_id": "sid-42",
                    "data_b64": b64,
                ],
            ],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)
        XCTAssertEqual(chunk?.event, "stdout")
        XCTAssertEqual(chunk?.data, Data(raw.utf8))
    }

    func test_decodeBroadcastChunk_preserves_binary_bytes() throws {
        // Terminal stdout chunks routinely include bytes that don't
        // round-trip through naive UTF-8 conversion (0xFF for ANSI
        // control sequences, partial multi-byte boundaries). Base64
        // is the wire shape because of these.
        let bytes = Data([0x68, 0x69, 0xFF, 0x1B, 0x5B, 0x32, 0x4A])
        let b64 = bytes.base64EncodedString()
        let envelope: [Any] = [
            NSNull(), NSNull(), "realtime:term:x", "broadcast",
            [
                "event": "stdout",
                "payload": ["data_b64": b64],
            ],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)
        XCTAssertEqual(chunk?.data, bytes)
    }

    func test_decodeBroadcastChunk_returns_nil_for_phx_reply() throws {
        // Replies to phx_join / heartbeat ack come through the same
        // socket; subscribeTerminal must ignore them silently. Real
        // shape from a vsn-2.0.0 ack:
        //   [join_ref, ref, topic, "phx_reply", {"response":{}, "status":"ok"}]
        let envelope: [Any] = [
            "100", "1", "realtime:term:x", "phx_reply",
            ["status": "ok", "response": [:] as [String: Any]],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)
        XCTAssertNil(chunk, "phx_reply must decode as nil (not surfaced to subscriber)")
    }

    func test_decodeBroadcastChunk_returns_nil_for_presence_diff() throws {
        // Same pattern for any other system event the subscriber
        // doesn't care about.
        let envelope: [Any] = [
            NSNull(), NSNull(), "realtime:term:x", "presence_diff",
            ["joins": [:] as [String: Any], "leaves": [:] as [String: Any]],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)
        XCTAssertNil(chunk)
    }

    func test_decodeBroadcastChunk_throws_unexpectedFrame_on_invalid_json() {
        let garbage = Data("this is not json".utf8)
        XCTAssertThrowsError(try RemoteSessionEventStream.decodeBroadcastChunk(from: garbage)) { err in
            switch err as? RemoteSessionEventStream.StreamError {
            case .unexpectedFrame: break
            default: XCTFail("expected unexpectedFrame, got \(err)")
            }
        }
    }

    func test_decodeBroadcastChunk_throws_on_short_array() throws {
        let envelope: [Any] = ["just", "two"]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)) { err in
            switch err as? RemoteSessionEventStream.StreamError {
            case .unexpectedFrame: break
            default: XCTFail("expected unexpectedFrame, got \(err)")
            }
        }
    }

    func test_decodeBroadcastChunk_throws_on_broadcast_missing_data_b64() throws {
        let envelope: [Any] = [
            NSNull(), NSNull(), "realtime:term:x", "broadcast",
            [
                "event": "stdout",
                "payload": ["session_id": "x"],  // no data_b64
            ],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        XCTAssertThrowsError(try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)) { err in
            switch err as? RemoteSessionEventStream.StreamError {
            case .unexpectedFrame: break
            default: XCTFail("expected unexpectedFrame, got \(err)")
            }
        }
    }

    func test_decodeBroadcastChunk_tolerates_flat_payload_shape() throws {
        // Defensive: some Phoenix versions deliver the user's event +
        // payload at the outer level rather than nested. Decoder
        // must accept both shapes so a Supabase upgrade can't
        // silently break the subscriber. Slice 3 today produces
        // nested; if Supabase ever flattens, we keep working.
        let b64 = Data("flat".utf8).base64EncodedString()
        let envelope: [Any] = [
            NSNull(), NSNull(), "realtime:term:x", "broadcast",
            [
                "event": "stderr",
                "data_b64": b64,
            ],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)
        XCTAssertEqual(chunk?.event, "stderr")
        XCTAssertEqual(chunk?.data, Data("flat".utf8))
    }

    // MARK: - end-to-end shape parity with slice-3 sink

    func test_decoder_accepts_what_slice3_sink_produces() throws {
        // Pins the contract: whatever the helper's broadcast sink
        // POSTs to /realtime/v1/api/broadcast, the iOS subscriber
        // decodes correctly after Supabase wraps it into a broadcast
        // envelope.
        let sessionId = "sid-end-to-end"
        let payloadBytes = Data("END_TO_END\n".utf8)

        // Simulate what slice-3 sink POSTs (inner body):
        let sinkInner: [String: Any] = [
            "session_id": sessionId,
            "data_b64": payloadBytes.base64EncodedString(),
        ]
        // Simulate what Supabase wraps before delivering over WS:
        let envelope: [Any] = [
            NSNull(), NSNull(),
            "realtime:term:\(sessionId)",
            "broadcast",
            [
                "event": "stdout",
                "type": "broadcast",
                "payload": sinkInner,
            ],
        ]
        let frame = try JSONSerialization.data(withJSONObject: envelope)
        let chunk = try RemoteSessionEventStream.decodeBroadcastChunk(from: frame)
        XCTAssertEqual(chunk?.event, "stdout")
        XCTAssertEqual(chunk?.data, payloadBytes)
    }
}
