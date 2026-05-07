import Foundation
import CommonCrypto

/// Port of `helper/system_collector.py::_decrypt_chromium_cookie`. The
/// algorithm is what every Chromium-fork uses to encrypt its Cookies
/// SQLite values on macOS:
///
///   1. Optional `v10` prefix (3 bytes) is stripped — Chromium added
///      it to mark cookies encrypted with the macOS Keychain-derived
///      key (vs the much weaker built-in salt scheme used on Linux
///      that we don't bother supporting).
///   2. PBKDF2-HMAC-SHA1 derives a 16-byte AES-128 key from the
///      browser's "Safe Storage" Keychain password using the
///      hard-coded salt `"saltysalt"` and 1003 iterations.
///   3. AES-128-CBC decrypts the ciphertext with the IV `0x20 * 16`
///      (sixteen ASCII spaces). Chromium uses a constant IV; the
///      cookie's secrecy comes from the per-user Keychain key, not
///      the IV.
///   4. PKCS7 padding is stripped; on long values, the first 32
///      bytes are also stripped if they're a non-printable host
///      prefix (a Chromium bookkeeping field).
///
/// Phase 4E Slice 2c.5 follow-up — Claude OAuth fallback path. Used
/// by `ClaudeWebSessionResolver` to recover a `sessionKey` cookie
/// from the user's browser when OAuth is rate-limited or unavailable.
public enum ChromiumCookieDecrypter {

    /// Constants — match Python `_decrypt_chromium_cookie` byte-for-byte.
    /// Drift here would silently break decryption for users on the
    /// web-cookie fallback path.
    public static let salt: Data = Data("saltysalt".utf8)
    public static let iterations: Int = 1003
    public static let keyLength: Int = 16
    public static let initializationVector: Data = Data(repeating: 0x20, count: 16)
    public static let v10Prefix: Data = Data("v10".utf8)

    public enum DecryptError: Error, Equatable {
        case pbkdf2Failed(status: Int32)
        case ciphertextNotMultipleOf16
        case aesDecryptFailed(status: Int32)
        case paddingInvalid(byte: UInt8)
        case emptyCiphertext
    }

    /// Derive the 16-byte AES key from a Keychain password. Pure
    /// function; PBKDF2 + SHA1 + the Chromium-specific salt/iteration
    /// constants. Stable output for the same password — pinned by
    /// `ChromiumCookieDecrypterTests.testKeyDerivationParityWithPython`.
    public static func deriveKey(password: String) throws -> Data {
        var derivedKey = Data(count: keyLength)
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt)
        let status = derivedKey.withUnsafeMutableBytes { keyPtr -> Int32 in
            return CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                passwordBytes, passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                UInt32(iterations),
                keyPtr.bindMemory(to: UInt8.self).baseAddress, keyLength
            )
        }
        guard status == kCCSuccess else {
            throw DecryptError.pbkdf2Failed(status: status)
        }
        return derivedKey
    }

    /// Decrypt a single cookie blob. Mirrors Python:
    ///   - strip `v10` prefix if present
    ///   - PBKDF2 derive 16-byte key from password
    ///   - AES-128-CBC decrypt with constant IV
    ///   - strip PKCS7 padding
    ///   - if plaintext is >32 bytes and the first 32 bytes are
    ///     non-printable, strip them (Chromium host-prefix metadata)
    public static func decrypt(
        encryptedValue: Data,
        password: String
    ) throws -> String {
        var blob = encryptedValue
        if blob.starts(with: v10Prefix) {
            blob = blob.subdata(in: v10Prefix.count..<blob.count)
        }
        guard !blob.isEmpty else {
            throw DecryptError.emptyCiphertext
        }
        guard blob.count.isMultiple(of: 16) else {
            throw DecryptError.ciphertextNotMultipleOf16
        }

        let key = try deriveKey(password: password)
        let plaintext = try aesCBCDecrypt(ciphertext: blob, key: key, iv: initializationVector)
        let unpadded = try stripPKCS7(plaintext)
        return Self.stripChromiumHostPrefix(unpadded)
    }

    /// AES-128-CBC decrypt via CommonCrypto. No padding is removed
    /// here — the caller does PKCS7 stripping after.
    static func aesCBCDecrypt(ciphertext: Data, key: Data, iv: Data) throws -> Data {
        // Allocate the output buffer exactly once. `output.count`
        // captured into a local variable below so we don't fight
        // Swift's exclusivity rules when reading `output.count`
        // while also taking a mutable reference to the same Data.
        let outputCapacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuf in
            ciphertext.withUnsafeBytes { cBuf in
                key.withUnsafeBytes { kBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES128),
                            0,                     // no padding option — we strip manually for parity
                            kBuf.baseAddress, key.count,
                            ivBuf.baseAddress,
                            cBuf.baseAddress, ciphertext.count,
                            outBuf.baseAddress, outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw DecryptError.aesDecryptFailed(status: status)
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    /// Strip PKCS7 padding. Mirrors Python `decrypted[:-decrypted[-1]]`
    /// — a single `decrypted[-1]` byte indicates the pad length, and
    /// we trim that many bytes from the end. Validates the byte is
    /// in the legal PKCS7 range (1...16); throws otherwise so a
    /// corrupt blob doesn't silently produce garbage.
    static func stripPKCS7(_ data: Data) throws -> Data {
        guard let last = data.last else {
            throw DecryptError.emptyCiphertext
        }
        guard last >= 1, last <= 16, last <= data.count else {
            throw DecryptError.paddingInvalid(byte: last)
        }
        return data.subdata(in: 0..<(data.count - Int(last)))
    }

    /// If `plaintext.count > 32` AND the first 32 bytes contain any
    /// non-printable byte, strip the leading 32. Chromium prefixes
    /// the cookie value with a SHA-256 of `host || cookie_name` for
    /// integrity binding; that prefix is binary and breaks UTF-8
    /// decoding if left in. Mirrors Python's check.
    static func stripChromiumHostPrefix(_ plaintext: Data) -> String {
        if plaintext.count > 32 {
            let prefix = plaintext.prefix(32)
            let allPrintable = prefix.allSatisfy { byte in
                byte >= 32 && byte <= 126
            }
            if !allPrintable {
                let trimmed = plaintext.subdata(in: 32..<plaintext.count)
                return String(data: trimmed, encoding: .utf8) ?? ""
            }
        }
        return String(data: plaintext, encoding: .utf8) ?? ""
    }
}
