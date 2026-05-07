import XCTest
@testable import HelperKit

/// Wire-shape pinning for `SupabaseRPCCaller`. Uses URLProtocol to
/// intercept all `URLSession` traffic so no real network calls happen.
final class SupabaseRPCCallerTests: XCTestCase {

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

    func test_call_posts_to_correct_rpc_endpoint_with_headers() async throws {
        InterceptProtocol.responder = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!,
                Data("{}".utf8)
            )
        }
        let caller = SupabaseRPCCaller(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        _ = try await caller.call(
            "remote_helper_pull_commands",
            params: ["p_max": 10]
        )
        let recorded = InterceptProtocol.lastRequest
        XCTAssertNotNil(recorded)
        let url = recorded?.url?.absoluteString ?? ""
        XCTAssertEqual(url, "https://example.supabase.co/rest/v1/rpc/remote_helper_pull_commands")
        XCTAssertEqual(recorded?.httpMethod, "POST")
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "apikey"), "anon-key")
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "Authorization"), "Bearer anon-key")
        XCTAssertEqual(recorded?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func test_call_throws_notConfigured_when_helper_unpaired() async throws {
        let caller = SupabaseRPCCaller(
            configProvider: {
                HelperConfigStore.CloudConfig(deviceId: "", helperSecret: "", supabaseURL: "", supabaseAnonKey: "")
            },
            session: makeSession()
        )
        do {
            _ = try await caller.call("anything", params: [:])
            XCTFail("expected SupabaseRPCError.notConfigured")
        } catch SupabaseRPCError.notConfigured {
            // ok
        } catch {
            XCTFail("got \(error), expected notConfigured")
        }
    }

    func test_call_throws_http_on_4xx() async throws {
        InterceptProtocol.responder = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!,
                Data("Device not found or unauthorized".utf8)
            )
        }
        let caller = SupabaseRPCCaller(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        do {
            _ = try await caller.call("remote_helper_pull_commands", params: [:])
            XCTFail("expected http error")
        } catch SupabaseRPCError.http(let status, let body) {
            XCTAssertEqual(status, 401)
            XCTAssertTrue(body.contains("not found"))
        } catch {
            XCTFail("got \(error)")
        }
    }

    func test_call_decodes_array_body_for_pull_commands() async throws {
        InterceptProtocol.responder = { request in
            let body = #"[{"id":"abc","kind":"start","session_id":"sid"}]"#
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!,
                Data(body.utf8)
            )
        }
        let caller = SupabaseRPCCaller(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        let result = try await caller.call("remote_helper_pull_commands", params: [:])
        let arr = result as? [Any]
        XCTAssertEqual(arr?.count, 1)
        let first = arr?.first as? [String: Any]
        XCTAssertEqual(first?["id"] as? String, "abc")
    }

    func test_call_decodes_empty_body_as_NSNull() async throws {
        InterceptProtocol.responder = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!,
                Data()
            )
        }
        let caller = SupabaseRPCCaller(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        let result = try await caller.call("remote_helper_complete_command", params: [:])
        XCTAssertTrue(result is NSNull)
    }

    func test_request_body_is_json_encoded_params() async throws {
        InterceptProtocol.responder = { request in
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!,
                Data("{}".utf8)
            )
        }
        let caller = SupabaseRPCCaller(
            configProvider: { Self.cloud },
            session: makeSession()
        )
        let params: [String: Any] = [
            "p_device_id": "dev",
            "p_helper_secret": "sec",
            "p_max": 5,
        ]
        _ = try await caller.call("remote_helper_pull_commands", params: params)
        let bodyData = InterceptProtocol.lastBodyData ?? Data()
        let decoded = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
        XCTAssertEqual(decoded?["p_device_id"] as? String, "dev")
        XCTAssertEqual(decoded?["p_helper_secret"] as? String, "sec")
        XCTAssertEqual(decoded?["p_max"] as? Int, 5)
    }
}

/// URLProtocol that intercepts all requests routed through a session
/// configured with `protocolClasses = [InterceptProtocol.self]` and
/// hands them to `responder` for synthetic responses.
final class InterceptProtocol: URLProtocol {

    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBodyData: Data?

    static func reset() {
        responder = nil
        lastRequest = nil
        lastBodyData = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        Self.lastRequest = request
        // URLProtocol receives the body via `httpBodyStream` (unless
        // it was set as a one-shot Data via httpBody). URLSession
        // wraps httpBody into a stream by the time we see it.
        if let body = request.httpBody {
            Self.lastBodyData = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            let bufSize = 8192
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let n = stream.read(buffer, maxLength: bufSize)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            Self.lastBodyData = collected
        }
        guard let responder = Self.responder else {
            client?.urlProtocol(
                self,
                didFailWithError: NSError(domain: "InterceptProtocol", code: -1, userInfo: nil)
            )
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
