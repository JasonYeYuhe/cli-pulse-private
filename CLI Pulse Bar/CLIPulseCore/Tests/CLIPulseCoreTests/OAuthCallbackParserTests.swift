import XCTest
@testable import CLIPulseCore

final class OAuthCallbackParserTests: XCTestCase {

    // Happy path: Supabase returns ?code=... on the query.
    // iter8 hotfix: state is now ignored (PKCE code_verifier handles CSRF).
    func testSuccessQueryParams() {
        let url = URL(string: "clipulse://auth/callback?code=abc123&state=xyz789")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .success(code: "abc123")
        )
    }

    // Some Supabase flows put the response in the URL fragment instead of the query.
    func testSuccessFragmentParams() {
        let url = URL(string: "clipulse://auth/callback#code=abc123&state=xyz789")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .success(code: "abc123")
        )
    }

    // iter8 hotfix: Supabase's PKCE flow no longer needs us to round-trip
    // `state`. A bare `?code=...` callback is now valid — the previous
    // "state missing" failure was rejecting genuine successes when Supabase
    // chose not to echo back our (now unused) state token.
    func testSuccessCodeOnlyNoState() {
        let url = URL(string: "clipulse://auth/callback?code=abc123")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .success(code: "abc123")
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

    // Regression: pin the exact wording the iter8 hotfix is fixing. When
    // Supabase emits `OAuth state parameter is invalid` we surface it
    // verbatim so support-side diagnosis is unambiguous.
    func testSurfacesSupabaseStateInvalidVerbatim() {
        let url = URL(string: "clipulse://auth/callback?error=invalid_request&error_description=OAuth%20state%20parameter%20is%20invalid")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "OAuth state parameter is invalid")
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

    // Defence-in-depth: a callback without a code must NOT echo the raw URL
    // (and therefore any leaky params) into a user-facing error.
    func testNoCodeDoesNotLeakURL() {
        let url = URL(string: "clipulse://auth/callback?state=abc")!
        let result = OAuthCallbackParser.parse(url: url)
        XCTAssertEqual(result, .failed(description: "no OAuth parameters in callback"))
        if case .failed(let description) = result {
            XCTAssertFalse(description.contains("clipulse://"))
            XCTAssertFalse(description.contains("abc"))
        }
    }

    // Don't let a code from the query and a state from the fragment ever
    // synthesize success across boundaries — even though state is ignored
    // for validation now, we still keep the source-of-truth invariant: if
    // the query has any OAuth param, we read ONLY from the query. (A
    // malicious shared link could otherwise smuggle a code in the query
    // alongside a stale fragment.)
    func testDoesNotMixQueryAndFragmentForCode() {
        // Query has `state` (recognized) but no code → fragment is ignored
        // even though it has a code. Result: failed (no code from the
        // chosen authoritative source).
        let url = URL(string: "clipulse://auth/callback?state=abc#code=fragmentCode")!
        XCTAssertEqual(
            OAuthCallbackParser.parse(url: url),
            .failed(description: "no OAuth parameters in callback")
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
