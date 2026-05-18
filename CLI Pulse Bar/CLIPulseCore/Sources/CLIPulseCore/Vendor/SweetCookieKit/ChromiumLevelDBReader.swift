// Vendored from steipete/SweetCookieKit 0.4.1 (MIT, © Peter Steinberger)
// https://github.com/steipete/SweetCookieKit — see ./LICENSE for the
// full MIT notice. Source-vendored (not an SPM dependency) because
// SweetCookieKit's Package.swift requires swift-tools 6.2 while CI runs
// Swift 6.1; vendoring removes the manifest from the resolution graph.
// Whole file is `#if os(macOS)`-wrapped so it never compiles on
// iOS/watchOS (same isolation the `.when(platforms:[.macOS])` SPM
// condition provided); CLIPulseCore links sqlite3 on macOS for this.

#if os(macOS)

import Foundation

#if os(macOS)

/// Utilities for scanning Chromium LevelDB stores when you need raw text entries or token candidates.
public enum ChromiumLevelDBReader {
    /// Reads best-effort text entries from a Chromium LevelDB directory.
    ///
    /// - Parameters:
    ///   - levelDBURL: Directory containing `.log` and `.ldb` files.
    ///   - logger: Optional logger for diagnostics.
    /// - Returns: Decoded text entries.
    public static func readTextEntries(
        in levelDBURL: URL,
        logger: ((String) -> Void)? = nil) -> [ChromiumLevelDBTextEntry]
    {
        ChromiumLocalStorageReader.readTextEntries(in: levelDBURL, logger: logger)
    }

    /// Scans a Chromium LevelDB directory for token-shaped ASCII strings.
    ///
    /// - Parameters:
    ///   - levelDBURL: Directory containing `.log` and `.ldb` files.
    ///   - minimumLength: Minimum token length to return.
    ///   - logger: Optional logger for diagnostics.
    public static func readTokenCandidates(
        in levelDBURL: URL,
        minimumLength: Int = 60,
        logger: ((String) -> Void)? = nil) -> [String]
    {
        ChromiumLocalStorageReader.readTokenCandidates(
            in: levelDBURL,
            minimumLength: minimumLength,
            logger: logger)
    }
}

#endif

#endif
