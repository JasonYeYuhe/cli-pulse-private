import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// NEW-H5: concurrent 401s must coalesce onto ONE token refresh so the
/// one-time-rotation Supabase refresh token is consumed exactly once. Without
/// single-flight, actor re-entrancy let each concurrent refresh use the same
/// captured token; the server rotated it on the first and rejected the rest,
/// which then wiped the freshly-rotated tokens → spurious forced logout.
final class APIClientRefreshSingleFlightTests: XCTestCase {

    func testConcurrentRefreshCoalescesToSingleNetworkCall() async throws {
        RefreshStubProtocol.reset()
        RefreshStubProtocol.responseDelay = 0.3 // ensure the 5 calls overlap

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshStubProtocol.self]
        let session = URLSession(configuration: config)

        let api = APIClient(
            token: "old-access",
            supabaseURL: "https://stub.cli-pulse.test",
            supabaseAnonKey: "anon",
            session: session
        )
        await api.updateRefreshToken("old-refresh")

        let results = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0..<5 {
                group.addTask { try await api.refreshAccessToken().accessToken }
            }
            var acc: [String] = []
            for try await r in group { acc.append(r) }
            return acc
        }

        XCTAssertEqual(results.count, 5)
        XCTAssertTrue(
            results.allSatisfy { $0 == RefreshStubProtocol.newAccessToken },
            "all concurrent callers must receive the single rotated access token"
        )
        XCTAssertEqual(
            RefreshStubProtocol.requestCount, 1,
            "5 concurrent refreshes must coalesce to ONE network refresh (single-flight)"
        )
        let stored = await api.getToken()
        XCTAssertEqual(stored, RefreshStubProtocol.newAccessToken)
    }

    /// Codex review of NEW-H5: a refresh that SUCCEEDS after a sign-out /
    /// account-switch landed (the stored refresh token changed mid-flight) must
    /// NOT resurrect the old session's tokens into actor state or Keychain.
    func testStaleSuccessfulRefreshDoesNotResurrectTokens() async throws {
        RefreshStubProtocol.reset()
        RefreshStubProtocol.responseDelay = 0.4

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshStubProtocol.self]
        let session = URLSession(configuration: config)

        let api = APIClient(
            token: "old-access",
            supabaseURL: "https://stub.cli-pulse.test",
            supabaseAnonKey: "anon",
            session: session
        )
        await api.updateRefreshToken("old-refresh")

        // Start a refresh that will await the 0.4s network.
        async let refreshResult: (accessToken: String, refreshToken: String) = api.refreshAccessToken()

        // While it's in flight, simulate a sign-out → new sign-in (token change).
        try await Task.sleep(nanoseconds: 120_000_000) // 0.12s, mid-flight
        await api.updateToken("new-session-access")
        await api.updateRefreshToken("new-session-refresh")

        _ = try? await refreshResult // let the stale refresh complete

        // The stale refresh must NOT have overwritten the new session's tokens.
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(access, "new-session-access", "stale refresh must not overwrite the new session access token")
        XCTAssertEqual(refresh, "new-session-refresh", "stale refresh must not overwrite the new session refresh token")
    }
}

/// URLProtocol stub: counts refresh requests and delays the response so
/// concurrent refreshes overlap, then returns a rotated token.
final class RefreshStubProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0
    nonisolated(unsafe) static var responseDelay: TimeInterval = 0.2
    static let lock = NSLock()
    static let newAccessToken = "new-access-rotated"
    static let newRefreshToken = "new-refresh-rotated"

    static func reset() {
        lock.lock(); requestCount = 0; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.requestCount += 1; Self.lock.unlock()
        let url = request.url ?? URL(string: "https://stub.cli-pulse.test")!
        let json = "{\"access_token\":\"\(Self.newAccessToken)\",\"refresh_token\":\"\(Self.newRefreshToken)\"}"
        let body = Data(json.utf8)
        let resp = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.responseDelay) { [weak self] in
            guard let self, let client = self.client else { return }
            client.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(self, didLoad: body)
            client.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

#endif
