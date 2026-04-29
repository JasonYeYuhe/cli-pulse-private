import Foundation

/// Pure helpers for syncing iOS / macOS APNs device tokens to Supabase.
///
/// The actual UIKit / AppKit registration (`registerForRemoteNotifications()`)
/// lives in iOS-target-only code (`iOSAppDelegate.swift`) because UIKit is
/// not available in CLIPulseCore's multi-platform package. This file is the
/// platform-agnostic seam: anything that can be unit-tested without a real
/// APNs-enabled device runs here.
public enum PushTokenSync {

    /// Convert raw APNs `Data` token (from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`)
    /// into the lowercase-hex string that APNs HTTP/2 endpoints expect in
    /// the URL path. Public so iOS-target code can call it without leaking
    /// implementation details, and so unit tests can pin the encoding.
    public static func formatToken(_ data: Data) -> String {
        return data.map { String(format: "%02x", $0) }.joined()
    }

    /// Identify the platform string the server expects in
    /// `app_push_tokens.platform`. Defaults to "ios" because Phase 1
    /// scope is iOS-only; macOS follows in a subsequent migration.
    public static func platformIdentifier(forUIKit: Bool = true) -> String {
        return forUIKit ? "ios" : "macos"
    }

    /// Hard upper bound on token length we'll accept before sending to the
    /// server. APNs tokens are typically 64 hex chars (32 bytes); this
    /// matches the length CHECK on the server side (8…256). Defends against
    /// weird Apple changes in token shape mangling our server.
    public static func isValidTokenLength(_ hexToken: String) -> Bool {
        return hexToken.count >= 8 && hexToken.count <= 256
    }

    /// Sanity-check a bundle id before sending. Same length CHECK as the
    /// server. Bundle ids are short reverse-DNS strings; we don't enforce
    /// the dot-separated grammar here.
    public static func isValidBundleId(_ bundleId: String?) -> Bool {
        guard let id = bundleId, !id.isEmpty else { return false }
        return id.count <= 128
    }
}
