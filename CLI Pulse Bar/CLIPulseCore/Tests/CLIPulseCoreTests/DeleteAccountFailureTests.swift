import XCTest
@testable import CLIPulseCore

/// Pin the contract for `DeleteAccountFailure.classify` — the decision
/// logic that drives whether `AppState.deleteAccount`'s catch arm signs
/// the user out (because their session is dead) or leaves them signed in
/// with a retryable error.
///
/// This is the iter11 hotfix's testable seam. The full delete-account
/// HTTP path can't be unit-tested without injecting a mock URLSession
/// into `APIClient` (the actor builds its session privately), so we
/// extract the failure-classification step into a pure helper and pin
/// THAT exhaustively. Manual real-device verification covers the
/// network round-trip side.
final class DeleteAccountFailureTests: XCTestCase {

    // MARK: - tokenExpired → sessionExpired

    /// The signal-firing case: `APIError.tokenExpired` thrown either by
    /// the eager `refreshAccessToken` call inside `APIClient.delete
    /// Account` or by any downstream authenticated path must classify as
    /// `.sessionExpired`. AppState routes that to `signOut()` so the UI
    /// state matches the API state (no tokens).
    func testAPIErrorTokenExpiredClassifiesAsSessionExpired() {
        let result = DeleteAccountFailure.classify(APIError.tokenExpired)
        XCTAssertEqual(result, .sessionExpired)
    }

    // MARK: - Other API errors → other(message:)

    /// HTTP errors from the RPC itself (e.g. server raised "Not authenticated"
    /// because `auth.uid()` returned NULL despite a token being sent —
    /// shouldn't happen post-iter10 eager refresh, but still possible if
    /// the refresh succeeded and then the RPC's own validation failed)
    /// must classify as `.other` so the session is preserved. The user
    /// can retry without re-authenticating.
    func testAPIErrorHTTP4xxClassifiesAsOther() {
        let body = #"{"message":"FK constraint"}"#
        let error = APIError.httpError(status: 400, body: body)
        let result = DeleteAccountFailure.classify(error)
        guard case .other(let message) = result else {
            return XCTFail("expected .other, got \(result)")
        }
        XCTAssertEqual(message, error.localizedDescription,
                       "should pass through APIError.localizedDescription unchanged")
        XCTAssertTrue(message.contains("400"), "message should mention HTTP status")
    }

    /// `APIError.invalidResponse` (URL construction failure, decoder
    /// failure, etc.) is also a `.other` — session is intact.
    func testAPIErrorInvalidResponseClassifiesAsOther() {
        let result = DeleteAccountFailure.classify(APIError.invalidResponse)
        guard case .other(let message) = result else {
            return XCTFail("expected .other, got \(result)")
        }
        XCTAssertEqual(message, APIError.invalidResponse.localizedDescription)
    }

    // MARK: - Non-API errors → other(message:)

    /// Network errors (NSURLError* / Foundation URLError) never carry
    /// `tokenExpired` semantics — they're transient and the user can
    /// retry. Must classify as `.other`.
    func testURLErrorClassifiesAsOther() {
        let urlError = URLError(.notConnectedToInternet)
        let result = DeleteAccountFailure.classify(urlError)
        guard case .other(let message) = result else {
            return XCTFail("expected .other, got \(result)")
        }
        XCTAssertEqual(message, urlError.localizedDescription)
    }

    /// Random unrecognised errors fall through to `.other` rather than
    /// being misclassified as session-expired. Defence-in-depth.
    struct CustomError: Error, LocalizedError {
        var errorDescription: String? { "custom failure" }
    }

    func testUnknownErrorTypeClassifiesAsOther() {
        let result = DeleteAccountFailure.classify(CustomError())
        guard case .other(let message) = result else {
            return XCTFail("expected .other, got \(result)")
        }
        XCTAssertEqual(message, "custom failure")
    }

    // MARK: - Equatable contract sanity

    /// Pin Equatable so callsites can compare `result == .sessionExpired`
    /// directly (used by AppState's switch). `.other` payload sensitivity
    /// covered alongside.
    func testEquatable() {
        XCTAssertEqual(DeleteAccountFailure.sessionExpired, .sessionExpired)
        XCTAssertEqual(DeleteAccountFailure.other(message: "x"),
                       .other(message: "x"))
        XCTAssertNotEqual(DeleteAccountFailure.sessionExpired,
                          .other(message: "x"))
        XCTAssertNotEqual(DeleteAccountFailure.other(message: "x"),
                          .other(message: "y"))
    }
}
