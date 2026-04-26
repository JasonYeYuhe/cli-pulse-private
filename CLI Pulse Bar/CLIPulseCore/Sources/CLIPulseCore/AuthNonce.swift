import Foundation
import Security

/// Failure modes for `AuthNonce.random(length:)`.
public enum AuthNonceError: Error, Equatable {
    /// Caller passed `length <= 0`.
    case invalidLength
    /// `SecRandomCopyBytes` (or an injected generator) returned a non-success status.
    case randomFailed(OSStatus)
}

/// Generates a cryptographically random nonce string for Sign in with Apple.
///
/// The previous app-side helpers crashed via `fatalError` when
/// `SecRandomCopyBytes` failed; this helper throws a typed, recoverable error
/// instead so the auth UI can surface a localized message and stay alive.
public enum AuthNonce {
    /// URL-safe character set used by Apple's reference Sign in with Apple sample.
    /// Kept identical to the previous in-app implementation for behavioral parity.
    static let allowedCharset: [Character] = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._"
    )

    /// Signature for an injectable random-byte generator. Takes the requested
    /// byte count and a buffer to fill, returning an `OSStatus`-shaped result
    /// (`errSecSuccess` on success). Tests can inject a failing implementation
    /// to exercise the error path without mocking the Security framework.
    public typealias RandomBytesGenerator = (Int, UnsafeMutablePointer<UInt8>) -> Int32

    /// Generate a random nonce of the requested length using the URL-safe alphabet.
    ///
    /// - Parameters:
    ///   - length: Number of characters in the nonce. Must be > 0.
    ///   - randomBytes: Source of random bytes. Defaults to `SecRandomCopyBytes`.
    /// - Throws: `AuthNonceError.invalidLength` for non-positive lengths,
    ///   `AuthNonceError.randomFailed` if the random source fails.
    public static func random(
        length: Int = 32,
        randomBytes: RandomBytesGenerator = AuthNonce.secRandomCopyBytes
    ) throws -> String {
        guard length > 0 else { throw AuthNonceError.invalidLength }
        var bytes = [UInt8](repeating: 0, count: length)
        let status: Int32 = bytes.withUnsafeMutableBufferPointer { buffer in
            // `baseAddress` is non-nil because `length > 0`.
            randomBytes(length, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AuthNonceError.randomFailed(status)
        }
        return String(bytes.map { allowedCharset[Int($0) % allowedCharset.count] })
    }

    /// Default generator backed by `SecRandomCopyBytes(kSecRandomDefault, ...)`.
    public static func secRandomCopyBytes(_ count: Int, _ buffer: UnsafeMutablePointer<UInt8>) -> Int32 {
        SecRandomCopyBytes(kSecRandomDefault, count, buffer)
    }
}
