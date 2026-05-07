import XCTest
@testable import HelperKit
import Foundation
import SQLite3
import CommonCrypto

/// Phase 4E Slice 2c.5 — tests for `ChromiumCookieDecrypter` (PBKDF2 +
/// AES-CBC + PKCS7) and `ChromiumCookieReader` (SQLite probe + Keychain
/// orchestration). Decrypter parity is pinned against Python-computed
/// reference values so a future tweak that drifts from
/// `helper/system_collector.py::_decrypt_chromium_cookie` fails here
/// rather than silently breaking the OAuth fallback for production
/// users.

final class ChromiumCookieDecrypterTests: XCTestCase {

    // MARK: - PBKDF2 key derivation

    func testKeyDerivationParityWithPython() throws {
        // Reference value computed via:
        //   PBKDF2HMAC(SHA1, length=16, salt=b"saltysalt",
        //              iterations=1003).derive(b"test-password")
        // Drift here breaks decryption for every user on the web-cookie
        // path → no Claude quota for OAuth-rate-limited users.
        let key = try ChromiumCookieDecrypter.deriveKey(password: "test-password")
        let hex = key.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "c0ffe4c25f07f62bfc6ab011d9efa54e",
                       "PBKDF2 drift from Python reference")
    }

    func testKeyDerivationDifferentPasswordsDifferentKeys() throws {
        let a = try ChromiumCookieDecrypter.deriveKey(password: "password-a")
        let b = try ChromiumCookieDecrypter.deriveKey(password: "password-b")
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.count, 16)
        XCTAssertEqual(b.count, 16)
    }

    // MARK: - PKCS7

    func testStripPKCS7_removesValidPadding() throws {
        // 5 bytes "hello" + 11 bytes 0x0b padding = 16 bytes.
        let padded = Data([0x68, 0x65, 0x6c, 0x6c, 0x6f] + [UInt8](repeating: 0x0b, count: 11))
        let unpadded = try ChromiumCookieDecrypter.stripPKCS7(padded)
        XCTAssertEqual(unpadded, Data("hello".utf8))
    }

    func testStripPKCS7_throwsOnInvalidByte() {
        let bad = Data([0x68, 0x65] + [0x20]) // last byte is 0x20 = 32 (invalid PKCS7).
        XCTAssertThrowsError(try ChromiumCookieDecrypter.stripPKCS7(bad)) { err in
            guard case ChromiumCookieDecrypter.DecryptError.paddingInvalid = err else {
                XCTFail("expected paddingInvalid; got \(err)")
                return
            }
        }
    }

    func testStripPKCS7_throwsOnEmpty() {
        XCTAssertThrowsError(try ChromiumCookieDecrypter.stripPKCS7(Data())) { err in
            guard case ChromiumCookieDecrypter.DecryptError.emptyCiphertext = err else {
                XCTFail("expected emptyCiphertext; got \(err)")
                return
            }
        }
    }

    // MARK: - End-to-end decrypt

    func testDecrypt_v10PrefixedCiphertextRoundTripsToKnownPlaintext() throws {
        // Reference encrypted blob built via Python:
        //   plain = b"sk-ant-sid01-test-session-key"
        //   PBKDF2(SHA1, salt="saltysalt", iter=1003, len=16) over
        //     password="test-password", IV=b" "*16
        //   pad PKCS7 to 16 bytes, AES-CBC encrypt, prefix `v10`.
        let hex = "763130c257c691bf8e1a242f238453dae900c90cc45251546ef852db5c08f11f4b074f"
        let encrypted = Data(hexString: hex)!
        let plaintext = try ChromiumCookieDecrypter.decrypt(
            encryptedValue: encrypted,
            password: "test-password"
        )
        XCTAssertEqual(plaintext, "sk-ant-sid01-test-session-key")
    }

    func testDecrypt_throwsForUnalignedCiphertext() {
        // 17 bytes (post-v10-strip) — not a multiple of 16.
        let blob = Data([0x76, 0x31, 0x30] + [UInt8](repeating: 0xff, count: 17))
        XCTAssertThrowsError(try ChromiumCookieDecrypter.decrypt(
            encryptedValue: blob, password: "x"
        )) { err in
            guard case ChromiumCookieDecrypter.DecryptError.ciphertextNotMultipleOf16 = err else {
                XCTFail("expected ciphertextNotMultipleOf16; got \(err)")
                return
            }
        }
    }

    func testDecrypt_wrongPasswordProducesGarbageOrPaddingError() {
        // Same ciphertext, wrong password — either decryption produces
        // an invalid PKCS7 byte (most likely), OR yields gibberish that
        // also fails the PKCS7 sanity check. Either way the function
        // must error rather than return random bytes.
        let hex = "763130c257c691bf8e1a242f238453dae900c90cc45251546ef852db5c08f11f4b074f"
        let encrypted = Data(hexString: hex)!
        XCTAssertThrowsError(try ChromiumCookieDecrypter.decrypt(
            encryptedValue: encrypted,
            password: "wrong-password"
        ))
    }

    // MARK: - Host-prefix stripping

    func testStripHostPrefix_removesNonPrintableLeading32() {
        // 32 bytes binary + "sk-ant-sid01-actual" (the ASCII payload)
        let binary = Data([UInt8](repeating: 0x01, count: 32))
        let payload = Data("sk-ant-sid01-actual".utf8)
        let result = ChromiumCookieDecrypter.stripChromiumHostPrefix(binary + payload)
        XCTAssertEqual(result, "sk-ant-sid01-actual")
    }

    func testStripHostPrefix_keepsPrefixIfPrintable() {
        // First 32 bytes are all ASCII (printable). Don't strip.
        let printable = Data("aaaabbbbccccddddeeeeffffgggghhhh".utf8)  // 32 chars
        let payload = Data("-rest".utf8)
        let result = ChromiumCookieDecrypter.stripChromiumHostPrefix(printable + payload)
        XCTAssertEqual(result, "aaaabbbbccccddddeeeeffffgggghhhh-rest")
    }
}

// MARK: - ChromiumCookieReader

final class ChromiumCookieReaderTests: XCTestCase {

    private var tmp: URL!
    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("CookieReader-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - readSessionKeyBlobs

    func testReadSessionKeyBlobs_fromTempCookiesDB() throws {
        let dbPath = tmp.appendingPathComponent("Cookies")
        try createTestCookiesDB(
            at: dbPath,
            rows: [
                ("claude.ai", "sessionKey", Data("encrypted-blob-1".utf8)),
                ("claude.ai", "other_cookie", Data("not-this".utf8)),
                ("example.com", "sessionKey", Data("not-claude".utf8)),
                (".claude.ai", "sessionKey", Data("encrypted-blob-2".utf8)),
            ]
        )

        let blobs = try ChromiumCookieReader.readSessionKeyBlobs(from: dbPath)
        // Expect 2 rows (claude.ai sessionKey + .claude.ai sessionKey),
        // sorted by host_key DESC ("claude.ai" > ".claude.ai" lexically).
        XCTAssertEqual(blobs.count, 2)
        XCTAssertEqual(blobs[0], Data("encrypted-blob-1".utf8))
        XCTAssertEqual(blobs[1], Data("encrypted-blob-2".utf8))
    }

    func testReadSessionKeyBlobs_returnsEmptyForMissingTable() throws {
        let dbPath = tmp.appendingPathComponent("EmptyCookies")
        // Create empty DB with no `cookies` table.
        var db: OpaquePointer?
        sqlite3_open_v2(dbPath.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        sqlite3_close(db)

        XCTAssertThrowsError(try ChromiumCookieReader.readSessionKeyBlobs(from: dbPath),
                             "missing `cookies` table should throw a sqlite3_prepare error")
    }

    // MARK: - tryReadSessionKey orchestration

    func testTryReadSessionKey_decryptsValidBlobWithKeychainPassword() async throws {
        // Build a DB with a valid v10-prefixed encrypted blob whose
        // password is known to the test-injected keychain.
        let dbPath = tmp.appendingPathComponent("Cookies")
        let hex = "763130c257c691bf8e1a242f238453dae900c90cc45251546ef852db5c08f11f4b074f"
        let blob = Data(hexString: hex)!
        try createTestCookiesDB(at: dbPath, rows: [
            ("claude.ai", "sessionKey", blob),
        ])

        let kr = KeychainReader(
            clock: { 0 },
            fetch: { service in
                if service == "Test Safe Storage" {
                    return .success(stdout: "test-password")
                }
                return .nonZeroExit(code: 44, stdout: "")
            }
        )
        let reader = ChromiumCookieReader(
            keychain: kr,
            fileExists: { _ in true }
        )
        let candidate = ChromiumCookieReader.CookieDBCandidate(
            label: "test:default",
            dbPath: dbPath,
            keychainServices: ["Test Safe Storage"]
        )
        let key = await reader.tryReadSessionKey(from: candidate)
        XCTAssertEqual(key, "sk-ant-sid01-test-session-key")
    }

    func testTryReadSessionKey_returnsNilWhenNoKeychainPasswordWorks() async throws {
        let dbPath = tmp.appendingPathComponent("Cookies")
        let hex = "763130c257c691bf8e1a242f238453dae900c90cc45251546ef852db5c08f11f4b074f"
        try createTestCookiesDB(at: dbPath, rows: [
            ("claude.ai", "sessionKey", Data(hexString: hex)!),
        ])

        let kr = KeychainReader(
            clock: { 0 },
            fetch: { service in
                .success(stdout: "wrong-password")
            }
        )
        let reader = ChromiumCookieReader(
            keychain: kr,
            fileExists: { _ in true }
        )
        let candidate = ChromiumCookieReader.CookieDBCandidate(
            label: "x",
            dbPath: dbPath,
            keychainServices: ["Whatever"]
        )
        let key = await reader.tryReadSessionKey(from: candidate)
        XCTAssertNil(key)
    }

    func testTryReadSessionKey_returnsNilWhenSessionKeyDoesntStartWithSkAntSid() async throws {
        // Decrypts cleanly but plaintext doesn't match Anthropic prefix.
        // (Shouldn't happen in practice; defensive guard.)
        let dbPath = tmp.appendingPathComponent("Cookies")
        // Encrypt "fake-cookie-value-not-claude" with our test password.
        let plain = Data("fake-cookie-value-not-claude".utf8)
        let padLen = 16 - (plain.count % 16)
        let padded = plain + Data([UInt8](repeating: UInt8(padLen), count: padLen))
        let key = try ChromiumCookieDecrypter.deriveKey(password: "test-password")
        let blob = try {
            // Manually CBC-encrypt to build the fixture.
            // Use the same IV as the decrypter.
            return Data("v10".utf8) + (try aesCBCEncrypt(
                plaintext: padded, key: key, iv: ChromiumCookieDecrypter.initializationVector
            ))
        }()
        try createTestCookiesDB(at: dbPath, rows: [
            ("claude.ai", "sessionKey", blob),
        ])
        let kr = KeychainReader(
            clock: { 0 },
            fetch: { _ in .success(stdout: "test-password") }
        )
        let reader = ChromiumCookieReader(
            keychain: kr,
            fileExists: { _ in true }
        )
        let candidate = ChromiumCookieReader.CookieDBCandidate(
            label: "x",
            dbPath: dbPath,
            keychainServices: ["Whatever"]
        )
        let result = await reader.tryReadSessionKey(from: candidate)
        XCTAssertNil(result, "non-Anthropic prefix must not be returned as a session key")
    }

    // MARK: - Helpers

    private func createTestCookiesDB(
        at path: URL,
        rows: [(host: String, name: String, encrypted: Data)]
    ) throws {
        var db: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            path.path, &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil
        )
        guard openStatus == SQLITE_OK else {
            throw NSError(domain: "test", code: Int(openStatus))
        }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE cookies (
            host_key TEXT NOT NULL,
            name TEXT NOT NULL,
            encrypted_value BLOB
        )
        """
        var err: UnsafeMutablePointer<CChar>?
        sqlite3_exec(db, createSQL, nil, nil, &err)

        for row in rows {
            var stmt: OpaquePointer?
            let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)
            sqlite3_prepare_v2(
                db,
                "INSERT INTO cookies (host_key, name, encrypted_value) VALUES (?, ?, ?)",
                -1, &stmt, nil
            )
            sqlite3_bind_text(stmt, 1, row.host, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, row.name, -1, SQLITE_TRANSIENT)
            row.encrypted.withUnsafeBytes { bytes in
                sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(row.encrypted.count), SQLITE_TRANSIENT)
            }
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    /// Test-only helper to encrypt a fixture so we can pin the
    /// "decrypts but wrong prefix" branch without hand-rolling
    /// hex constants.
    private func aesCBCEncrypt(plaintext: Data, key: Data, iv: Data) throws -> Data {
        // Mirrors the decrypter's CCCrypt call but with kCCEncrypt.
        // Pure local helper — not exposed in production code.
        let outputCapacity = plaintext.count + 16
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status: Int32 = output.withUnsafeMutableBytes { outBuf in
            plaintext.withUnsafeBytes { pBuf in
                key.withUnsafeBytes { kBuf in
                    iv.withUnsafeBytes { ivBuf in
                        return CCrypt_encrypt(
                            kBuf.baseAddress!, key.count,
                            ivBuf.baseAddress!,
                            pBuf.baseAddress!, plaintext.count,
                            outBuf.baseAddress!, outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == 0 else {
            throw NSError(domain: "encrypt-test", code: Int(status))
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }
}

// Tiny C-bridging wrapper for the test encrypter (CCCrypt in encrypt
// mode). Lives at file scope so the test target can reach it.
private func CCrypt_encrypt(
    _ key: UnsafeRawPointer, _ keyLen: Int,
    _ iv: UnsafeRawPointer,
    _ input: UnsafeRawPointer, _ inputLen: Int,
    _ output: UnsafeMutableRawPointer, _ outputCapacity: Int,
    _ outputLength: inout Int
) -> Int32 {
    return CCCrypt(
        CCOperation(kCCEncrypt),
        CCAlgorithm(kCCAlgorithmAES128),
        0,
        key, keyLen,
        iv,
        input, inputLen,
        output, outputCapacity,
        &outputLength
    )
}

// MARK: - Test helpers

private extension Data {
    init?(hexString: String) {
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2, limitedBy: hexString.endIndex) ?? hexString.endIndex
            guard next != index, let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
