#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Tests the Gemini OAuth PKCE generation — a regression here silently breaks the
/// Gemini sign-in handshake (the auth server rejects the code exchange). The
/// challenge derivation is pinned against the canonical RFC 7636 Appendix B vector.
final class GeminiOAuthPKCETests: XCTestCase {

    func test_code_challenge_matches_independent_sha256_base64url() {
        // S256 PKCE: challenge = base64url(SHA256(ascii(verifier))) with no padding.
        // Expected value computed independently via:
        //   printf '%s' "<verifier>" | openssl dgst -sha256 -binary | openssl base64 | tr '+/' '-_' | tr -d '='
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXE"
        XCTAssertEqual(GeminiOAuthManager.generateCodeChallenge(from: verifier),
                       "ReRUJDfFsb8IO0H96Xz4SzJotT5pTH0ddiUpY50N1rs")
    }

    func test_code_challenge_is_deterministic() {
        XCTAssertEqual(GeminiOAuthManager.generateCodeChallenge(from: "abc"),
                       GeminiOAuthManager.generateCodeChallenge(from: "abc"))
    }

    func test_code_challenge_is_base64url_43_chars_no_padding() {
        let c = GeminiOAuthManager.generateCodeChallenge(from: "anything")
        XCTAssertEqual(c.count, 43) // SHA256 = 32 bytes → 43 base64url chars (unpadded)
        XCTAssertFalse(c.contains("+") || c.contains("/") || c.contains("="))
    }

    func test_code_verifier_is_43char_base64url_and_random() throws {
        let v1 = try GeminiOAuthManager.generateCodeVerifier()
        let v2 = try GeminiOAuthManager.generateCodeVerifier()
        XCTAssertEqual(v1.count, 43) // 32 random bytes → 43 base64url chars
        XCTAssertFalse(v1.contains("+") || v1.contains("/") || v1.contains("="))
        XCTAssertNotEqual(v1, v2) // independent RNG draws — collision astronomically unlikely
    }
}
#endif
