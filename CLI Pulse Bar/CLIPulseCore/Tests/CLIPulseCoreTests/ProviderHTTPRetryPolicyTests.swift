// Pure-policy tests for v1.24 Phase 1 Item #6 — ProviderHTTPRetryPolicy.
// Verifies upstream CodexBar 94f831a2 semantics: which status codes and
// URLErrors qualify for retry, idempotent-method gating, Retry-After
// header honoring, exponential-backoff cap.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class ProviderHTTPRetryPolicyTests: XCTestCase {
    private let getRequest: URLRequest = {
        var r = URLRequest(url: URL(string: "https://example.test/x")!)
        r.httpMethod = "GET"
        return r
    }()

    private let postRequest: URLRequest = {
        var r = URLRequest(url: URL(string: "https://example.test/x")!)
        r.httpMethod = "POST"
        return r
    }()

    // MARK: - shouldRetry(statusCode:)

    func test_shouldRetry_statusCode_retryable_GET_underLimit() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        for code in [408, 429, 500, 502, 503, 504] {
            XCTAssertTrue(
                policy.shouldRetry(request: getRequest, attempt: 0, statusCode: code),
                "expected retry for \(code)")
        }
    }

    func test_shouldRetry_statusCode_nonRetryable_returnsFalse() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        for code in [200, 201, 301, 400, 401, 403, 404, 422] {
            XCTAssertFalse(
                policy.shouldRetry(request: getRequest, attempt: 0, statusCode: code),
                "did not expect retry for \(code)")
        }
    }

    func test_shouldRetry_statusCode_POST_neverRetries_evenOnRetryableStatus() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        XCTAssertFalse(policy.shouldRetry(request: postRequest, attempt: 0, statusCode: 503))
    }

    func test_shouldRetry_statusCode_attemptAtMaxRetries_returnsFalse() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent  // maxRetries = 1
        XCTAssertTrue(policy.shouldRetry(request: getRequest, attempt: 0, statusCode: 503))
        XCTAssertFalse(policy.shouldRetry(request: getRequest, attempt: 1, statusCode: 503))
        XCTAssertFalse(policy.shouldRetry(request: getRequest, attempt: 2, statusCode: 503))
    }

    // MARK: - shouldRetry(error:)

    func test_shouldRetry_URLError_retryable() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        for code in [URLError.timedOut, .networkConnectionLost, .cannotConnectToHost,
                     .cannotFindHost, .dnsLookupFailed] {
            XCTAssertTrue(
                policy.shouldRetry(request: getRequest, attempt: 0, error: URLError(code)),
                "expected retry for URLError \(code)")
        }
    }

    func test_shouldRetry_URLError_nonRetryable_returnsFalse() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        for code in [URLError.userCancelledAuthentication, .badURL, .unsupportedURL] {
            XCTAssertFalse(
                policy.shouldRetry(request: getRequest, attempt: 0, error: URLError(code)),
                "did not expect retry for URLError \(code)")
        }
    }

    func test_shouldRetry_nonURLError_returnsFalse() {
        struct OtherError: Error {}
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        XCTAssertFalse(policy.shouldRetry(request: getRequest, attempt: 0, error: OtherError()))
    }

    // MARK: - delaySeconds

    func test_delaySeconds_honors_RetryAfter_header() {
        let policy = ProviderHTTPRetryPolicy(maxRetries: 3)
        let response = HTTPURLResponse(
            url: getRequest.url!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "5"])!
        XCTAssertEqual(policy.delaySeconds(attempt: 0, response: response), 5)
    }

    func test_delaySeconds_RetryAfter_cappedAtMaxDelay() {
        let policy = ProviderHTTPRetryPolicy(maxRetries: 3, maxDelaySeconds: 10)
        let response = HTTPURLResponse(
            url: getRequest.url!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "60"])!
        XCTAssertEqual(policy.delaySeconds(attempt: 0, response: response), 10)
    }

    func test_delaySeconds_exponentialBackoff_cappedAtMax() {
        let policy = ProviderHTTPRetryPolicy(maxRetries: 5, baseDelaySeconds: 1, maxDelaySeconds: 10)
        // attempt 0 → 1 * 2^0 = 1
        XCTAssertEqual(policy.delaySeconds(attempt: 0, response: nil), 1)
        // attempt 1 → 1 * 2^1 = 2
        XCTAssertEqual(policy.delaySeconds(attempt: 1, response: nil), 2)
        // attempt 2 → 1 * 2^2 = 4
        XCTAssertEqual(policy.delaySeconds(attempt: 2, response: nil), 4)
        // attempt 3 → 1 * 2^3 = 8
        XCTAssertEqual(policy.delaySeconds(attempt: 3, response: nil), 8)
        // attempt 4 → 1 * 2^4 = 16, capped to 10
        XCTAssertEqual(policy.delaySeconds(attempt: 4, response: nil), 10)
    }

    func test_delaySeconds_baseDelayZero_returnsZero() {
        let policy = ProviderHTTPRetryPolicy(
            maxRetries: 2,
            baseDelaySeconds: 0,
            maxDelaySeconds: 10)
        XCTAssertEqual(policy.delaySeconds(attempt: 0, response: nil), 0)
        XCTAssertEqual(policy.delaySeconds(attempt: 3, response: nil), 0)
    }

    // MARK: - Presets

    func test_disabled_neverRetries() {
        let policy = ProviderHTTPRetryPolicy.disabled
        XCTAssertEqual(policy.maxRetries, 0)
        XCTAssertFalse(policy.shouldRetry(request: getRequest, attempt: 0, statusCode: 503))
        XCTAssertFalse(policy.shouldRetry(request: getRequest, attempt: 0, error: URLError(.timedOut)))
    }

    func test_transientIdempotent_retriesOnce() {
        let policy = ProviderHTTPRetryPolicy.transientIdempotent
        XCTAssertEqual(policy.maxRetries, 1)
        XCTAssertTrue(policy.shouldRetry(request: getRequest, attempt: 0, statusCode: 503))
        XCTAssertFalse(policy.shouldRetry(request: getRequest, attempt: 1, statusCode: 503))
    }

    // MARK: - Init clamps

    func test_init_clamps_negativeMaxRetries_toZero() {
        let policy = ProviderHTTPRetryPolicy(maxRetries: -5)
        XCTAssertEqual(policy.maxRetries, 0)
    }

    func test_init_clamps_negativeDelays_toZero() {
        let policy = ProviderHTTPRetryPolicy(
            maxRetries: 1,
            baseDelaySeconds: -2,
            maxDelaySeconds: -3)
        XCTAssertEqual(policy.baseDelaySeconds, 0)
        XCTAssertEqual(policy.maxDelaySeconds, 0)
    }
}
#endif
