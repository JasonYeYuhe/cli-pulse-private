import XCTest
@testable import HelperKit

final class ClaudeOAuthInjectorTests: XCTestCase {

    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-oauth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeCreds(_ oauth: [String: Any], extraRoot: [String: Any] = [:]) throws -> URL {
        var root: [String: Any] = ["claudeAiOauth": oauth]
        for (k, v) in extraRoot { root[k] = v }
        let url = tmpDir.appendingPathComponent(".credentials.json")
        let data = try JSONSerialization.data(withJSONObject: root)
        try data.write(to: url)
        return url
    }

    private final class MockHTTP: TokenHTTPClient {
        var capturedURL: URL?
        var capturedBody: Data?
        var response: (status: Int, data: Data)?
        var callCount = 0
        func postJSON(url: URL, body: Data, timeout: TimeInterval) -> (status: Int, data: Data)? {
            callCount += 1
            capturedURL = url
            capturedBody = body
            return response
        }
    }

    private func ms(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    // MARK: - No-network: valid stored token used directly

    func test_validStoredToken_usedWithoutRefresh() throws {
        let url = try writeCreds([
            "accessToken": "valid-access",
            "refreshToken": "rt-1",
            "expiresAt": ms(Date().addingTimeInterval(3600)),
            "subscriptionType": "max",
        ])
        let http = MockHTTP()
        let token = ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: http)
        XCTAssertEqual(token, "valid-access")
        XCTAssertEqual(http.callCount, 0, "a still-valid token must not hit the network")
    }

    func test_missingFile_returnsNil() {
        let url = tmpDir.appendingPathComponent("does-not-exist.json")
        XCTAssertNil(ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: MockHTTP()))
    }

    // MARK: - Refresh when expired

    func test_expiredToken_refreshes_persistsRotatedRT_preservesFields() throws {
        let url = try writeCreds([
            "accessToken": "old-access",
            "refreshToken": "rt-old",
            "expiresAt": ms(Date().addingTimeInterval(-60)),   // expired
            "subscriptionType": "max",
            "scopes": ["user:inference", "user:profile"],
        ], extraRoot: ["someOtherTool": ["keep": true]])

        let http = MockHTTP()
        http.response = (200, try JSONSerialization.data(withJSONObject: [
            "access_token": "new-access",
            "refresh_token": "rt-rotated",
            "expires_in": 28800,
        ]))

        let token = ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: http)
        XCTAssertEqual(token, "new-access")
        XCTAssertEqual(http.callCount, 1)

        // Request shape: client_id REQUIRED + refresh_token + grant_type.
        let body = try XCTUnwrap(http.capturedBody)
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["grant_type"] as? String, "refresh_token")
        XCTAssertEqual(sent["refresh_token"] as? String, "rt-old")
        XCTAssertEqual(sent["client_id"] as? String, ClaudeOAuthInjector.clientID)
        XCTAssertEqual(http.capturedURL?.absoluteString, "https://console.anthropic.com/v1/oauth/token")

        // Persisted: rotated RT + new access + preserved unknown fields.
        let reread = try XCTUnwrap(ClaudeOAuthInjector.readCredentials(at: url))
        XCTAssertEqual(reread.accessToken, "new-access")
        XCTAssertEqual(reread.refreshToken, "rt-rotated")
        XCTAssertGreaterThan(reread.expiresAt.timeIntervalSinceNow, 28000)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertNotNil(root["someOtherTool"], "non-oauth root fields must survive the rewrite")
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["subscriptionType"] as? String, "max", "subscriptionType must survive")
        XCTAssertEqual((oauth["scopes"] as? [String])?.count, 2, "scopes must survive")
    }

    func test_refreshFailure_fallsBackToStoredToken() throws {
        let url = try writeCreds([
            "accessToken": "stale-access",
            "refreshToken": "rt-old",
            "expiresAt": ms(Date().addingTimeInterval(-60)),
        ])
        let http = MockHTTP()
        http.response = (401, Data("{}".utf8))  // refresh rejected
        // Two endpoints tried, both fail → fall back to the stored token.
        let token = ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: http)
        XCTAssertEqual(token, "stale-access")
        XCTAssertEqual(http.callCount, 2, "console then api fallback")
    }

    func test_noRefreshToken_andExpired_returnsNil() throws {
        let url = try writeCreds([
            "accessToken": "",
            "refreshToken": "",
            "expiresAt": ms(Date().addingTimeInterval(-60)),
        ])
        XCTAssertNil(ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: MockHTTP()))
    }

    func test_fdEnvVarName_isExact() {
        // The exact name matters — CLAUDE_CODE_OAUTH_TOKEN_FD does NOT work.
        XCTAssertEqual(ClaudeOAuthInjector.fdEnvVar, "CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR")
    }

    // MARK: - Codex review hardening (2026-06-29)

    func test_epochToDate_disambiguatesMsVsSeconds() {
        let now = Date()
        let ms = now.timeIntervalSince1970 * 1000.0
        let s = now.timeIntervalSince1970
        XCTAssertEqual(ClaudeOAuthInjector.epochToDate(ms).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(ClaudeOAuthInjector.epochToDate(s).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(ClaudeOAuthInjector.epochToDate(0).timeIntervalSince1970, 0)
    }

    func test_secondsEpoch_validToken_notMisreadAsExpired() throws {
        // A future expiry expressed in SECONDS must be treated as valid (not
        // 1970), so no needless refresh fires.
        let url = try writeCreds([
            "accessToken": "valid-seconds",
            "refreshToken": "rt",
            "expiresAt": Int(Date().addingTimeInterval(3600).timeIntervalSince1970), // seconds
        ])
        let http = MockHTTP()
        XCTAssertEqual(ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: http), "valid-seconds")
        XCTAssertEqual(http.callCount, 0)
    }

    func test_persist_conflictDetection_doesNotClobberConcurrentWinner() throws {
        // On-disk RT differs from what we refreshed-from → a concurrent claude
        // rotated it. persist must bail (return true) and leave the on-disk
        // (valid) credentials untouched, so we never invalidate the live login.
        let url = try writeCreds([
            "accessToken": "concurrent-access",
            "refreshToken": "rt-concurrent",
            "expiresAt": ms(Date().addingTimeInterval(3600)),
        ])
        let ok = ClaudeOAuthInjector.persist(
            accessToken: "ours-access", refreshToken: "rt-ours",
            expiresAt: Date().addingTimeInterval(28800), to: url,
            expectedPriorRefreshToken: "rt-original-stale")
        XCTAssertTrue(ok, "conflict is not an error — the winner already persisted")
        let reread = try XCTUnwrap(ClaudeOAuthInjector.readCredentials(at: url))
        XCTAssertEqual(reread.refreshToken, "rt-concurrent", "must keep the concurrent winner's RT")
        XCTAssertEqual(reread.accessToken, "concurrent-access", "must not clobber the winner's access token")
    }

    func test_persist_forces0600_evenIfOriginalWasLax() throws {
        let url = try writeCreds([
            "accessToken": "old",
            "refreshToken": "rt-old",
            "expiresAt": ms(Date().addingTimeInterval(-60)),
        ])
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        let http = MockHTTP()
        http.response = (200, try JSONSerialization.data(withJSONObject: [
            "access_token": "new", "refresh_token": "rt-new", "expires_in": 28800,
        ]))
        _ = ClaudeOAuthInjector.resolveAccessToken(fileURL: url, http: http)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "persisted credentials must be locked down to 0600")
    }
}
