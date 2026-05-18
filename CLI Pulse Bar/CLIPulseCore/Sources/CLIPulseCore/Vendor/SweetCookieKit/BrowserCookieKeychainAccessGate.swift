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
/// Opt-in switch for disabling Keychain access in host apps.
public enum BrowserCookieKeychainAccessGate {
    public nonisolated(unsafe) static var isDisabled: Bool = false
}
#endif

#endif
