import Foundation
import CryptoKit

/// Local-control auth token — Swift port of `helper/local_auth_token.py`.
///
/// The macOS app and the helper communicate over a Unix domain socket
/// inside the app group container. Same-machine does NOT mean trusted:
/// any other process on the Mac can `connect(2)` to that socket. Every
/// UDS request (except `hello`) carries a 32-byte auth token that the
/// helper rotates on every startup and writes — mode 0600 — into the
/// app group container the macOS app reads via its sandbox
/// entitlement.
///
/// Threat model boundary: this is **local** authentication only. The
/// paired-device `helper_secret` (SHA-256 hex digest verified by
/// Supabase RPCs) handles the cross-device case. The two have
/// different rotation schedules + storage locations and are NOT
/// interchangeable.
public enum AuthToken {
    /// 32 bytes = 256 bits of entropy; well above any plausible
    /// online-guessing threat model. Encoded form is 44 chars of
    /// padded base64 (we keep the padding for round-trip
    /// convenience; matches the Python encoding decision).
    public static let tokenBytes = 32

    /// Group container path the macOS app's sandbox entitlement
    /// grants both the app and the helper read/write access to.
    /// Same identifier as the Python helper — required for
    /// drop-in compatibility.
    public static let appGroupID = "group.yyh.CLI-Pulse"
    public static let tokenFilename = "helper-auth-token"

    public static func containerPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(appGroupID, isDirectory: true)
    }

    public static func tokenPath() -> URL {
        return containerPath().appendingPathComponent(tokenFilename)
    }

    /// Generate a fresh token, write it (mode 0600) at `path`, and
    /// return the base64-encoded form so the caller can keep it
    /// in memory for `compare()`.
    ///
    /// Rotates unconditionally — every helper restart invalidates
    /// the previous token. The macOS app reads the file on each
    /// request, so the rotation is transparent to the user.
    /// Creates the parent directory if missing (helper may launch
    /// before the user opens the app).
    @discardableResult
    public static func rotateToken(at path: URL? = nil) throws -> String {
        let target = path ?? tokenPath()
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        var rawBytes = [UInt8](repeating: 0, count: tokenBytes)
        let result = SecRandomCopyBytes(kSecRandomDefault, tokenBytes, &rawBytes)
        guard result == errSecSuccess else {
            throw AuthTokenError.randomGenerationFailed(osStatus: result)
        }
        let raw = Data(rawBytes)
        let encoded = raw.base64EncodedString()
        let bytes = Array(encoded.utf8)

        // Atomic-replace pattern matches the Python implementation:
        // write tmp, fchmod, rename. POSIX rename is atomic so a
        // concurrent reader never sees a half-written token.
        let tmp = target.appendingPathExtension("tmp")
        // Clean up any leftover from a previous failed run.
        try? FileManager.default.removeItem(at: tmp)
        try Data(bytes).write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp.path
        )
        // `rename(2)` is atomic on POSIX. Foundation's
        // FileManager.replaceItem may use a non-atomic copy on
        // failure recovery so we use the lower-level API instead.
        let res = Darwin.rename(
            (tmp.path as NSString).fileSystemRepresentation,
            (target.path as NSString).fileSystemRepresentation
        )
        if res != 0 {
            throw AuthTokenError.writeFailed("rename: \(String(cString: strerror(errno)))")
        }
        // Defence in depth: re-chmod the destination — `rename`
        // preserves the destination's previous mode on some POSIX
        // implementations.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: target.path
        )
        return encoded
    }

    /// Read the token at `path` (or the default location) without
    /// any validation. Returns nil if the file is missing —
    /// caller decides whether that's fatal. IO errors fall back
    /// to nil with a logging hook the call site can plumb.
    public static func loadToken(at path: URL? = nil) -> String? {
        let target = path ?? tokenPath()
        guard let data = try? Data(contentsOf: target) else { return nil }
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Constant-time comparison of two base64-encoded tokens.
    /// Uses CryptoKit's `SymmetricKey` equality which short-
    /// circuits in constant time (defeats the timing oracle a
    /// naïve `==` would expose). Empty / mismatched-length
    /// inputs always return false — defenders in depth: a missing
    /// token must never authenticate.
    public static func compare(expected: String, supplied: String) -> Bool {
        guard !expected.isEmpty, !supplied.isEmpty else { return false }
        let expectedBytes = Array(expected.utf8)
        let suppliedBytes = Array(supplied.utf8)
        guard expectedBytes.count == suppliedBytes.count else { return false }
        // CryptoKit doesn't expose a generic constant-time bytes
        // compare; emulate via accumulated XOR which the optimiser
        // can't shortcut on data-dependent values.
        var diff: UInt8 = 0
        for i in 0..<expectedBytes.count {
            diff |= expectedBytes[i] ^ suppliedBytes[i]
        }
        return diff == 0
    }
}

public enum AuthTokenError: Error, Equatable {
    case randomGenerationFailed(osStatus: OSStatus)
    case writeFailed(String)
}
