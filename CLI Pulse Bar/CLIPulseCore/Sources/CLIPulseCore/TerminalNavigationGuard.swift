// TerminalNavigationGuard — shared, pure navigation policy for the in-app
// terminal WebViews (iOS RemoteTerminalView + macOS TerminalView).
//
// The terminal WebView only ever loads the vendored local xterm.js bundle via
// `loadFileURL(...)`. Nothing should ever navigate it anywhere else. Without a
// WKNavigationDelegate, a crafted escape sequence / link / injected script in
// the (still-public `term:`) stream could drive the WebView to an http(s)/data:
// URL — phishing, or exfiltrating local file contents reachable under the
// bundle's read-access scope. This guard refuses any navigation that doesn't
// stay inside the local bundle directory.
//
// Kept as a pure function (no WebKit import) so it is unit-testable without
// instantiating a WKWebView, which SIGABRTs in headless XCTest hosts.

import Foundation

public enum TerminalNavigationGuard {

    /// Whether a navigation to `url` is allowed for a terminal WebView whose
    /// bundle lives in `bundleDirectory`. Allowed iff `url` is a `file:` URL
    /// equal to or beneath `bundleDirectory` (after symlink/`..` normalization).
    /// Everything else — http(s), about:, data:, javascript:, blob:, a `file:`
    /// URL outside the bundle dir, or a nil/unknown URL — is denied.
    public static func allows(_ url: URL?, bundleDirectory: URL?) -> Bool {
        guard let url, let bundleDirectory, url.isFileURL else { return false }
        let target = url.standardizedFileURL.resolvingSymlinksInPath().path
        var base = bundleDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        if base.hasSuffix("/") { base.removeLast() }
        // Allow the directory itself and any path strictly beneath it. The
        // trailing-slash boundary stops a sibling like ".../Terminal-evil"
        // from matching ".../Terminal" via a bare prefix check.
        return target == base || target.hasPrefix(base + "/")
    }
}
