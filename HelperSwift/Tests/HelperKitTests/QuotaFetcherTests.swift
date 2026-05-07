import XCTest
@testable import HelperKit
import Foundation

/// Tests for `ClaudeQuotaFetcher` / `CodexQuotaFetcher` /
/// `GeminiQuotaFetcher` (Phase 4E Slice 2c). Pin parser invariants
/// + provenance discrimination + wire-shape Codable behaviour.

// MARK: - Shared helpers

private func makeISO(_ epoch: TimeInterval) -> String {
    let f = SessionDetector.makeISOFormatter()
    return f.string(from: Date(timeIntervalSince1970: epoch))
}

private func makeHTTPResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    return HTTPURLResponse(url: url, statusCode: status,
                           httpVersion: "HTTP/1.1", headerFields: nil)!
}

// MARK: - ClaudePlanInferrer

final class ClaudePlanInferrerTests: XCTestCase {
    func testMaxTiersDisambiguate() {
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "max_20x", subscriptionType: ""), "Max 20x")
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "max_5x", subscriptionType: ""), "Max 5x")
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "max", subscriptionType: ""), "Max 5x")
    }

    func testProAndUltraAndTeam() {
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "pro", subscriptionType: ""), "Pro")
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "", subscriptionType: "ultra"), "Ultra")
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "", subscriptionType: "team"), "Team")
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "", subscriptionType: "free"), "Free")
    }

    func testFallbackToCapitalizedSubscription() {
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "", subscriptionType: "custom"), "Custom")
        XCTAssertEqual(ClaudePlanInferrer.plan(rateLimitTier: "", subscriptionType: ""), "Unknown")
    }
}

// MARK: - QuotaProvenance Codable

final class QuotaProvenanceTests: XCTestCase {

    func testRoundTripSimpleVariant() throws {
        let original = QuotaProvenance.anthropicOAuth
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QuotaProvenance.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testRoundTripUnavailableWithReason() throws {
        let original = QuotaProvenance.unavailable(reason: "oauth_429_backoff")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(QuotaProvenance.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testWireShapeIncludesKindKey() throws {
        let p = QuotaProvenance.openAIWham
        let data = try JSONEncoder().encode(p)
        let json = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"kind\":\"openai_wham\""),
                      "expected `kind` discriminator; got \(json)")
    }
}

// MARK: - ClaudeQuotaFetcher

final class ClaudeQuotaFetcherTests: XCTestCase {

    private actor MockHTTP {
        var calls: [URLRequest] = []
        var canned: (Data, HTTPURLResponse)? = nil
        func record(_ r: URLRequest) { calls.append(r) }
        func setCanned(_ c: (Data, HTTPURLResponse)?) { canned = c }
    }

    private actor MockKeychainBackend {
        var stored: SubprocessRunner.RunResult = .nonZeroExit(code: 44, stdout: "")
        func set(_ r: SubprocessRunner.RunResult) { stored = r }
        func get() -> SubprocessRunner.RunResult { stored }
    }

    private func makeFetcher(
        keychainResult: SubprocessRunner.RunResult,
        httpCanned: (Data, HTTPURLResponse)?
    ) async -> (ClaudeQuotaFetcher, MockHTTP) {
        let mockHTTP = MockHTTP()
        await mockHTTP.setCanned(httpCanned)

        let kbBackend = MockKeychainBackend()
        await kbBackend.set(keychainResult)

        let kr = KeychainReader(
            clock: { 0 },
            fetch: { _ in await kbBackend.get() }
        )
        let backoff = OAuthBackoff(clock: { 0 })

        let fetcher = ClaudeQuotaFetcher(
            keychain: kr,
            backoff: backoff,
            http: { req in
                await mockHTTP.record(req)
                return await mockHTTP.canned
            },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        return (fetcher, mockHTTP)
    }

    func testFetch_returnsUnavailableWhenKeychainNotFound() async {
        let (fetcher, _) = await makeFetcher(
            keychainResult: .nonZeroExit(code: 44, stdout: ""),
            httpCanned: nil
        )
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertTrue(reason.contains("keychain"),
                          "expected keychain-related reason; got \(reason)")
        } else {
            XCTFail("expected unavailable; got \(snap.provenance)")
        }
    }

    func testFetch_returnsUnavailableWhenTokenWrongShape() async {
        let blob = #"{"claudeAiOauth": {"accessToken": "not-sk-ant-oat-prefix"}}"#
        let (fetcher, _) = await makeFetcher(
            keychainResult: .success(stdout: blob),
            httpCanned: nil
        )
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "oauth_token_missing")
        } else {
            XCTFail("expected unavailable; got \(snap.provenance)")
        }
    }

    func testFetch_returnsUnavailableWhenExpired() async {
        // expiresAt is in the past relative to fixed-now (1.7e9).
        let blob = #"""
        {"claudeAiOauth": {
          "accessToken": "sk-ant-oat01-foo",
          "expiresAt": 1500000000
        }}
        """#
        let (fetcher, _) = await makeFetcher(
            keychainResult: .success(stdout: blob),
            httpCanned: nil
        )
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "oauth_expired")
        } else {
            XCTFail("expected oauth_expired; got \(snap.provenance)")
        }
    }

    func testFetch_register429AndReturnsBackoff() async {
        let blob = #"""
        {"claudeAiOauth": {
          "accessToken": "sk-ant-oat01-foo",
          "expiresAt": 9999999999
        }}
        """#
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let response = makeHTTPResponse(url, status: 429)
        let (fetcher, _) = await makeFetcher(
            keychainResult: .success(stdout: blob),
            httpCanned: (Data(), response)
        )
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "oauth_429")
        } else {
            XCTFail("expected oauth_429; got \(snap.provenance)")
        }
    }

    func testFetch_unauthorizedOnHTTP401() async {
        let blob = #"""
        {"claudeAiOauth": {
          "accessToken": "sk-ant-oat01-foo",
          "expiresAt": 9999999999
        }}
        """#
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let (fetcher, _) = await makeFetcher(
            keychainResult: .success(stdout: blob),
            httpCanned: (Data(), makeHTTPResponse(url, status: 401))
        )
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "oauth_unauthorized")
        } else {
            XCTFail("expected oauth_unauthorized; got \(snap.provenance)")
        }
    }

    func testFetch_parsesSuccessfulOAuthResponse() async {
        let blob = #"""
        {"claudeAiOauth": {
          "accessToken": "sk-ant-oat01-foo",
          "rateLimitTier": "pro",
          "subscriptionType": "pro",
          "expiresAt": 9999999999
        }}
        """#
        let respBody = #"""
        {
          "five_hour": {"used_percentage": 30, "resets_at_iso": "2026-05-07T05:00:00Z"},
          "weekly_all": {"used_percentage": 50, "resets_at_iso": "2026-05-13T00:00:00Z"},
          "weekly_opus": {"used_percentage": 10, "resets_at_iso": "2026-05-13T00:00:00Z"}
        }
        """#
        let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let (fetcher, _) = await makeFetcher(
            keychainResult: .success(stdout: blob),
            httpCanned: (respBody.data(using: .utf8)!, makeHTTPResponse(url, status: 200))
        )
        let snap = await fetcher.fetch()
        XCTAssertEqual(snap.provenance, .anthropicOAuth)
        XCTAssertEqual(snap.planType, "Pro")
        XCTAssertEqual(snap.tiers.count, 3)
        XCTAssertEqual(snap.tiers[0].name, "5h Window")
        XCTAssertEqual(snap.tiers[0].remaining, 70)
        XCTAssertEqual(snap.tiers[1].remaining, 50)
        XCTAssertEqual(snap.tiers[2].remaining, 90)
    }

    // MARK: - normalizedExpiry

    func testNormalizedExpiry_handlesSecondsAndMs() {
        let epochSeconds: [String: Any] = ["expiresAt": 1_700_000_000]
        let epochMs: [String: Any] = ["expiresAt": 1_700_000_000_000]
        XCTAssertEqual(ClaudeQuotaFetcher.normalizedExpiry(from: epochSeconds), 1_700_000_000)
        XCTAssertEqual(ClaudeQuotaFetcher.normalizedExpiry(from: epochMs), 1_700_000_000)
    }

    func testNormalizedExpiry_returnsNilForMissingOrZero() {
        XCTAssertNil(ClaudeQuotaFetcher.normalizedExpiry(from: [:]))
        XCTAssertNil(ClaudeQuotaFetcher.normalizedExpiry(from: ["expiresAt": 0]))
    }

    // MARK: - parseAPIResponse direct

    func testParseAPIResponse_returnsParseErrorOnInvalidJSON() {
        let snap = ClaudeQuotaFetcher.parseAPIResponse(
            Data("not-json".utf8),
            planType: "Pro",
            fetchedAt: makeISO(0)
        )
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "parse_error")
        } else {
            XCTFail("expected parse_error")
        }
    }
}

// MARK: - CodexQuotaFetcher

final class CodexQuotaFetcherTests: XCTestCase {

    private actor MockHTTP {
        var canned: (Data, HTTPURLResponse)? = nil
        func setCanned(_ c: (Data, HTTPURLResponse)?) { canned = c }
    }

    private actor MockFile {
        var data: Data? = nil
        func set(_ d: Data?) { data = d }
        func get() -> Data? { data }
    }

    private func makeFetcher(
        authJSON: Data?,
        httpCanned: (Data, HTTPURLResponse)?
    ) async -> CodexQuotaFetcher {
        let mockHTTP = MockHTTP()
        await mockHTTP.setCanned(httpCanned)

        let mockFile = MockFile()
        await mockFile.set(authJSON)

        return CodexQuotaFetcher(
            authFilePath: URL(fileURLWithPath: "/dev/null"),
            http: { _ in await mockHTTP.canned },
            fileLoader: { _ in await mockFile.get() },
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    func testFetch_authFileMissing() async {
        let fetcher = await makeFetcher(authJSON: nil, httpCanned: nil)
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "auth_file_missing")
        } else {
            XCTFail("expected auth_file_missing")
        }
    }

    func testExtractAccessToken_flatShape() {
        let outer: [String: Any] = ["tokens": ["access_token": "flat-tok"]]
        XCTAssertEqual(CodexQuotaFetcher.extractAccessToken(from: outer), "flat-tok")
    }

    func testExtractAccessToken_nestedShape() {
        let outer: [String: Any] = [
            "tokens": ["someKey": ["access_token": "nested-tok"]]
        ]
        XCTAssertEqual(CodexQuotaFetcher.extractAccessToken(from: outer), "nested-tok")
    }

    func testExtractAccessToken_returnsNilWhenAbsent() {
        XCTAssertNil(CodexQuotaFetcher.extractAccessToken(from: ["tokens": ["wrong_key": "x"]]))
        XCTAssertNil(CodexQuotaFetcher.extractAccessToken(from: ["tokens": [:]]))
        XCTAssertNil(CodexQuotaFetcher.extractAccessToken(from: [:]))
    }

    func testFetch_emptyToken() async {
        let auth = #"{"tokens": {"access_token": ""}}"#
        let fetcher = await makeFetcher(authJSON: auth.data(using: .utf8), httpCanned: nil)
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "auth_token_missing")
        }
    }

    func testParseUsageResponse_planAndTwoTiers() {
        let body = #"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 25, "reset_at": 1700004800},
            "secondary_window": {"used_percent": 60, "reset_at": 1700604800}
          }
        }
        """#
        let snap = CodexQuotaFetcher.parseUsageResponse(
            body.data(using: .utf8)!, fetchedAt: makeISO(0)
        )
        XCTAssertEqual(snap.provenance, .openAIWham)
        XCTAssertEqual(snap.planType, "Plus")
        XCTAssertEqual(snap.tiers.count, 2)
        XCTAssertEqual(snap.tiers[0].name, "Session")
        XCTAssertEqual(snap.tiers[0].remaining, 75)
        XCTAssertEqual(snap.tiers[1].remaining, 40)
    }

    func testFetch_http500ReturnsUnavailable() async {
        let auth = #"{"tokens": {"access_token": "good-tok"}}"#
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
        let fetcher = await makeFetcher(
            authJSON: auth.data(using: .utf8),
            httpCanned: (Data(), makeHTTPResponse(url, status: 500))
        )
        let snap = await fetcher.fetch()
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "http_500")
        }
    }
}

// MARK: - GeminiQuotaFetcher

final class GeminiQuotaFetcherTests: XCTestCase {

    func testReadTokenIfFresh_returnsTokenWhenNoExpiry() {
        let json = #"{"access_token": "good-tok"}"#
        let token = GeminiQuotaFetcher.readTokenIfFresh(
            json.data(using: .utf8)!,
            now: Date()
        )
        XCTAssertEqual(token, "good-tok")
    }

    func testReadTokenIfFresh_returnsTokenWhenNotExpired() {
        let json = #"{"access_token": "good-tok", "expiry_date": 9999999999000}"#
        let token = GeminiQuotaFetcher.readTokenIfFresh(
            json.data(using: .utf8)!,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(token, "good-tok")
    }

    func testReadTokenIfFresh_returnsNilWhenExpired() {
        let json = #"{"access_token": "stale-tok", "expiry_date": 1_500_000_000_000}"#
        let token = GeminiQuotaFetcher.readTokenIfFresh(
            json.data(using: .utf8)!,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertNil(token)
    }

    func testReadTokenIfFresh_handlesEpochSeconds() {
        // expiry_date as seconds (not ms).
        let json = #"{"access_token": "tok", "expiry_date": 9999999999}"#
        let token = GeminiQuotaFetcher.readTokenIfFresh(
            json.data(using: .utf8)!,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(token, "tok")
    }

    func testReadTokenIfFresh_emptyAccessTokenIsNil() {
        let json = #"{"access_token": ""}"#
        let token = GeminiQuotaFetcher.readTokenIfFresh(
            json.data(using: .utf8)!,
            now: Date()
        )
        XCTAssertNil(token)
    }

    func testParseQuotaResponse_dailyLimit() {
        let json = #"""
        {
          "dailyLimit": 100,
          "dailyUsed": 30,
          "nextResetTimestamp": 1700004800000
        }
        """#
        let snap = GeminiQuotaFetcher.parseQuotaResponse(
            json.data(using: .utf8)!,
            fetchedAt: makeISO(0)
        )
        XCTAssertEqual(snap.provenance, .googleCloudCode)
        XCTAssertEqual(snap.tiers.count, 1)
        XCTAssertEqual(snap.tiers[0].remaining, 70)
    }

    func testParseQuotaResponse_missingFieldsReturnsUnavailable() {
        let snap = GeminiQuotaFetcher.parseQuotaResponse(
            "{}".data(using: .utf8)!,
            fetchedAt: makeISO(0)
        )
        if case .unavailable(let reason) = snap.provenance {
            XCTAssertEqual(reason, "parse_no_quota_fields")
        }
    }
}
