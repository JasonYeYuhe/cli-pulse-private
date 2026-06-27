#if os(macOS)
import XCTest
import CommonCrypto
@testable import CLIPulseCore

/// Golden tests for `ChromeCookieImporter.decryptChromiumValue` — the AES-128-CBC
/// decryptor for Chromium (Chrome/Edge/Brave/Arc) cookie values. It drives every
/// Chromium-based provider's cookie auth and had ZERO direct tests. We exercise it
/// by encrypting a known plaintext with the SAME scheme Chrome uses (fixed 16-space
/// IV, PKCS7 padding, `v10` prefix) and asserting the round-trip, plus the format
/// guards (wrong prefix / short input / wrong key / 32-byte domain-hash strip).
final class ChromeCookieDecryptTests: XCTestCase {

    private let key = Data(repeating: 0x42, count: kCCKeySizeAES128) // 16-byte AES-128 key

    /// Encrypt exactly as Chrome's `v10` scheme does (AES-128-CBC, IV = 16×0x20, PKCS7).
    private func encryptV10(_ plaintext: Data, key: Data) -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: plaintext.count + kCCBlockSizeAES128)
        var outLen = 0
        let cap = out.count
        let status = out.withUnsafeMutableBytes { o in
            plaintext.withUnsafeBytes { p in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { ivb in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, ivb.baseAddress,
                                p.baseAddress, plaintext.count,
                                o.baseAddress, cap, &outLen)
                    }
                }
            }
        }
        precondition(status == Int32(kCCSuccess), "test encrypt failed")
        out.count = outLen
        return Data("v10".utf8) + out
    }

    func test_roundtrip_short_value_no_hash_prefix() {
        // ≤32 bytes decrypted → returned as-is (no 32-byte strip).
        let value = "session-token-abc123"
        let enc = encryptV10(Data(value.utf8), key: key)
        XCTAssertEqual(ChromeCookieImporter.decryptChromiumValue(enc, key: key), value)
    }

    func test_roundtrip_strips_32_byte_domain_hash() {
        // Real Chrome v10 prepends a 32-byte SHA256(domain) before the value; the
        // decryptor drops the first 32 bytes when the plaintext is longer than 32.
        let value = "real-cookie-value-xyz"
        let plaintext = Data(repeating: 0x00, count: 32) + Data(value.utf8)
        let enc = encryptV10(plaintext, key: key)
        XCTAssertEqual(ChromeCookieImporter.decryptChromiumValue(enc, key: key), value)
    }

    func test_rejects_non_v10_prefix() {
        // Encrypt then swap the prefix to "v11" → must be rejected (nil).
        var enc = encryptV10(Data("x".utf8), key: key)
        enc.replaceSubrange(0..<3, with: Data("v11".utf8))
        XCTAssertNil(ChromeCookieImporter.decryptChromiumValue(enc, key: key))
    }

    func test_rejects_too_short_input() {
        XCTAssertNil(ChromeCookieImporter.decryptChromiumValue(Data("v10".utf8), key: key)) // 3 bytes
        XCTAssertNil(ChromeCookieImporter.decryptChromiumValue(Data([0x00]), key: key))
    }

    func test_wrong_key_does_not_recover_plaintext() {
        let value = "session-token-abc123"
        let enc = encryptV10(Data(value.utf8), key: key)
        let wrongKey = Data(repeating: 0x99, count: kCCKeySizeAES128)
        // A wrong key must fail PKCS7 unpad (nil) or at worst yield garbage — never the value.
        XCTAssertNotEqual(ChromeCookieImporter.decryptChromiumValue(enc, key: wrongKey), value)
    }
}
#endif
