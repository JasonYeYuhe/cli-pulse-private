import XCTest
@testable import CLIPulseCore

final class AuthNonceTests: XCTestCase {

    func testGeneratedNonceHasRequestedLength() throws {
        let nonce = try AuthNonce.random(length: 32)
        XCTAssertEqual(nonce.count, 32)

        let shorter = try AuthNonce.random(length: 8)
        XCTAssertEqual(shorter.count, 8)
    }

    func testGeneratedNonceUsesAllowedAlphabet() throws {
        let allowed = Set(AuthNonce.allowedCharset)
        let nonce = try AuthNonce.random(length: 64)
        for ch in nonce {
            XCTAssertTrue(allowed.contains(ch), "Unexpected character \(ch) in nonce")
        }
    }

    func testInvalidLengthThrows() {
        XCTAssertThrowsError(try AuthNonce.random(length: 0)) { error in
            XCTAssertEqual(error as? AuthNonceError, .invalidLength)
        }
        XCTAssertThrowsError(try AuthNonce.random(length: -3)) { error in
            XCTAssertEqual(error as? AuthNonceError, .invalidLength)
        }
    }

    func testRandomFailureSurfacesAsTypedError() {
        let failingGenerator: AuthNonce.RandomBytesGenerator = { _, _ in -67673 } // arbitrary non-success OSStatus
        XCTAssertThrowsError(try AuthNonce.random(length: 32, randomBytes: failingGenerator)) { error in
            XCTAssertEqual(error as? AuthNonceError, .randomFailed(-67673))
        }
    }

    func testInjectedGeneratorMapsBytesThroughAlphabet() throws {
        // Fill with 0s → every output character should be the first alphabet entry.
        let zeroGenerator: AuthNonce.RandomBytesGenerator = { count, buffer in
            for i in 0..<count { buffer[i] = 0 }
            return 0 // errSecSuccess
        }
        let nonce = try AuthNonce.random(length: 5, randomBytes: zeroGenerator)
        XCTAssertEqual(nonce, String(repeating: String(AuthNonce.allowedCharset[0]), count: 5))
    }
}
