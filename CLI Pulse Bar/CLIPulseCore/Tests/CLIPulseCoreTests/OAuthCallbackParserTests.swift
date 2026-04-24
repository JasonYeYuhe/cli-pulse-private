import XCTest
@testable import CLIPulseCore

final class OAuthCallbackParserTests: XCTestCase {

    // Happy path: Supabase returns ?code=...&state=... on the query.
    func testSuccessQueryParams() {
        let url = URL(string: "clipulse://auth/callback?code=abc123&state=xyz789")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .success(code: "abc123", state: "xyz789")
        )
    }

    // Some Supabase flows put the response in the URL fragment instead of the query.
    func testSuccessFragmentParams() {
        let url = URL(string: "clipulse://auth/callback#code=abc123&state=xyz789")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .success(code: "abc123", state: "xyz789")
        )
    }

    // Google "cancel" / "deny" at the consent screen → Supabase forwards
    // error=access_denied. This used to fall into the generic "failed" branch
    // and surface OAuth jargon; we now surface a friendly "cancelled" state.
    func testCancelledAccessDeniedQuery() {
        let url = URL(string: "clipulse://auth/callback?error=access_denied&error_description=User%20denied")!
        XCTAssertEqual(OAuthCallbackParser.parse(url: url), .cancelled)
    }

    // Same, but in the fragment. Supabase mixes these depending on flow.
    func testCancelledAccessDeniedFragment() {
        let url = URL(string: "clipulse://auth/callback#error=access_denied&error_description=User%20denied")!
        XCTAssertEqual(OAuthCallbackParser.parse(url: url), .cancelled)
    }

    // Any other error_description passes through as a .failed detail.
    func testGenericFailure() {
        let url = URL(string: "clipulse://auth/callback?error=server_error&error_description=Boom")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "Boom")
        )
    }

    // No recognizable params → .failed with a generic hint (NOT the raw URL,
    // which could contain PII).
    func testUnknownResponseFallback() {
        let url = URL(string: "clipulse://auth/callback")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "no OAuth parameters in callback")
        )
    }

    // Regression: a callback with `code` but no `state` must NOT echo the
    // raw URL (and therefore the code) into a user-facing error. Codex
    // flagged this as a blocking issue in the review.
    func testCodeWithoutStateDoesNotLeakURL() {
        let url = URL(string: "clipulse://auth/callback?code=leaky-code")!
        let result = OAuthCallbackParser.parse(url: url)
        XCTAssertEqual(result, .failed(description: "state missing"))
        if case .failed(let description) = result {
            XCTAssertFalse(description.contains("leaky-code"))
            XCTAssertFalse(description.contains("clipulse://"))
        }
    }

    // Symmetric: state but no code is also a malformed callback.
    func testStateWithoutCodeFails() {
        let url = URL(string: "clipulse://auth/callback?state=abc")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "code missing")
        )
    }

    // Don't let a response carrying a code across query+fragment synthesize
    // "success" from half-mixed inputs. If the query has any OAuth param, we
    // read ONLY from the query; the fragment is ignored.
    func testDoesNotMixQueryAndFragment() {
        let url = URL(string: "clipulse://auth/callback?code=abc#state=xyz")!
        // query has `code` → query wins, fragment `state` ignored → no state
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "state missing")
        )
    }

    // Explicit non-cancel error should NOT be overridden by a `code` that
    // happens to also appear (defence in depth against malformed responses).
    func testErrorBeatsCode() {
        let url = URL(string: "clipulse://auth/callback?error=server_error&error_description=boom&code=ignored&state=s")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "boom")
        )
    }

    // Percent-encoded error_description for non-cancel paths.
    func testGenericFailurePercentDecoded() {
        let url = URL(string: "clipulse://auth/callback?error=server_error&error_description=Temporarily%20unavailable")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "Temporarily unavailable")
        )
    }
}
