import Foundation

// CodexBar-parity Phase A / G1 — browser-cookie auto-import seam.
//
// This file is intentionally platform-agnostic (NO `#if os`): the protocol
// and the `NullCookieImporter` compile on macOS, iOS and watchOS. The real,
// SweetCookieKit-backed implementation lives in `BrowserCookieAutoImporter`
// behind `#if os(macOS) && canImport(SweetCookieKit)`. On iOS/watchOS the
// resolver uses `NullCookieImporter`, so cookie-based providers transparently
// fall back to the existing manual-paste path with zero behaviour change.

/// Attempts to read a browser session cookie and return it as an HTTP
/// `Cookie:` header value. Implementations MUST never throw — any failure
/// (no browser, Full Disk Access denied, Keychain denied, parse error) is
/// absorbed and surfaced as `nil` so the caller can fall back to manual.
public protocol CookieImporting: Sendable {
    func importCookieHeader(
        domains: [String],
        knownSessionCookieNames: Set<String>,
        logger: (@Sendable (String) -> Void)?
    ) async -> String?
}

/// No-op importer used on iOS/watchOS and in unit tests. Always returns nil,
/// which makes `CookieResolver` fall through to the manual/env path.
public struct NullCookieImporter: CookieImporting, Sendable {
    public init() {}

    public func importCookieHeader(
        domains: [String],
        knownSessionCookieNames: Set<String>,
        logger: (@Sendable (String) -> Void)?
    ) async -> String? {
        nil
    }
}
