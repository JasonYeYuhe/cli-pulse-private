// v1.21 D4: single CryptoKit-backed SHA-256 helper. Replaces three separate
// CommonCrypto implementations (AppUpdater, AlertGenerator, HelperInstaller)
// that each used `ptr.baseAddress!` force-unwrap inside withUnsafeBytes.
// CryptoKit's API takes Data directly, eliminating the force-unwrap.
//
// Per Gemini round 2 note: SHA256Digest is NOT Data. Hex conversion uses
// `digest.map { String(format: "%02x", $0) }.joined()` — every byte is
// formatted to its 2-char hex pair, then joined in one pass. Do NOT use
// per-byte string `+=` concatenation (O(n²) on long digests).

import Foundation
import CryptoKit

public enum CryptoHelpers {

    /// SHA-256 of arbitrary Data. Result is lowercase hex (64 chars).
    public static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a UTF-8 string. Empty/invalid strings return empty string
    /// (matches the legacy AlertGenerator.sha256Prefix behaviour).
    public static func sha256HexUtf8(_ s: String) -> String {
        guard let data = s.data(using: .utf8) else { return "" }
        return sha256Hex(data)
    }

    /// SHA-256 of a file's contents, returned as lowercase hex.
    ///
    /// Reads the entire file into memory via `Data(contentsOf:options:.mappedIfSafe)`.
    /// For DMG-sized files (50-150 MB) this is fast but can stall the caller's
    /// thread on slow disks. Callers on the main thread should wrap this in
    /// `await Task.detached { try CryptoHelpers.sha256Hex(of: url) }.value`.
    public static func sha256Hex(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return sha256Hex(data)
    }
}
