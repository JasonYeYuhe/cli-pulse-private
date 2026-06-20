// v1.24 Phase 3 slice 2 — TerminalView WKWebView wrapper.
// Hosts the vendored xterm.js bundle inside an AppKit NSView so the
// Mac Bar app can drop a TerminalView into an NSWindow without
// owning any WebKit boilerplate itself.
//
// Producer-side coalescing: stdout bytes flow Swift→Web via
// `TerminalOutputCoalescer` (16 ms wall-clock window) → JS-side
// rAF batcher (`pushChunk`) → one `term.write()` per frame at
// worst. Together they cap bridge crossings at ~60/sec regardless
// of producer rate (Codex HIGH H1 from plan §3b).
//
// Bridge messages (see Resources/Terminal/index.html):
//   { kind: "ready" }              — DOM wired up, safe to pushChunk
//   { kind: "stdin", data: "…" }   — user keystrokes (raw UTF-8 string)
//   { kind: "resize", cols, rows } — viewport size after layout
//
// Consumer pattern: the host instantiates a TerminalView, sets
// `delegate` to receive stdin/resize callbacks, and pushes output
// chunks via `pushStdout(_:)`. The Mac Bar app's "New Terminal →
// Claude" menu item wires this into `ManagedSessionManager` in
// slice 3.

#if os(macOS)
import AppKit
import WebKit
import Foundation

public protocol TerminalViewDelegate: AnyObject {
    /// Sent once the JS side has finished loading and the consumer
    /// may begin calling `pushStdout(_:)`. Called on the main
    /// queue.
    func terminalViewDidBecomeReady(_ view: TerminalView)
    /// User typed into the terminal. `data` is a raw UTF-8 string —
    /// xterm.js sends a single keystroke per call, including
    /// control bytes encoded as their ASCII equivalents (e.g. 0x03
    /// for Ctrl-C, 0x04 for Ctrl-D, escape sequences for arrows).
    /// Consumers convert to `Data` and forward to the helper via
    /// `send_input_raw` so byte 0x03 is NOT mangled into 0x03 + \r.
    func terminalView(_ view: TerminalView, didReceiveStdin data: String)
    /// Viewport size changed (e.g. window resize). Consumers
    /// forward to the helper via `resize` so the child gets
    /// SIGWINCH.
    func terminalView(_ view: TerminalView, didResizeTo cols: Int, rows: Int)
}

public final class TerminalView: NSView {

    public weak var delegate: TerminalViewDelegate?

    /// Underlying WKWebView. Exposed for tests and the rare host
    /// that needs to attach an inspector. Do NOT poke at its
    /// JS state from outside — use `pushStdout(_:)` for output
    /// and the delegate for input.
    public let webView: WKWebView

    /// Producer-side coalescer. Built lazily on first push so the
    /// onFlush closure can capture `self` (Swift forbids capture
    /// pre-`super.init`, and we want the closure to dispatch to
    /// `emitFlush` on the real instance).
    private lazy var coalescer: TerminalOutputCoalescer = TerminalOutputCoalescer(
        windowSeconds: 0.016,
        flushQueue: .main,
        onFlush: { [weak self] payload in
            self?.emitFlush(payload)
        })
    private let messageHandler: BridgeHandler
    /// True after the JS side sent `{kind: "ready"}`. Output queued
    /// before this point still works (the JS-side rAF batcher
    /// holds chunks until `term.write` is safe), but the consumer
    /// usually wants to wait so the user doesn't see a half-loaded
    /// terminal.
    public private(set) var isReady: Bool = false

    /// Designated initializer. The web view loads `index.html` from
    /// the CLIPulseCore module's resource bundle synchronously;
    /// `isReady` flips to true after the JS-side handshake fires
    /// the `ready` message.
    public override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        // Allow the WKWebView to talk to xterm's clipboard helpers
        // for copy/paste — defaults to false on macOS WebKit.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Pre-populate the content controller so the `terminal`
        // message handler exists before the page loads. WKWebView
        // installs handlers AFTER navigation otherwise and the
        // `ready` post would fire into the void.
        let messageHandler = BridgeHandler()
        config.userContentController.add(messageHandler, name: "terminal")

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.messageHandler = messageHandler
        super.init(frame: frame)

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        // Wire the bridge back-pointer so JS→native messages route
        // to this instance. The coalescer's flush sink captures
        // self via the lazy var above, so no extra wiring needed.
        messageHandler.owner = self
        loadBundleIndex()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TerminalView does not support NSCoder")
    }

    deinit {
        // Tear down the message handler so WKWebView doesn't
        // retain a dangling reference after dealloc.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        // Deliberately do NOT flush here: emitting a final batch into a
        // deallocating WKWebView via evaluateJavaScript has no value and is the
        // only `evaluateJavaScript` path that could run off-main in a narrow
        // dealloc-timing window (deep review). The coalescer's pending bytes are
        // freed with `self`; its onFlush captures `[weak self]`, so any already-
        // scheduled flush no-ops once we're gone.
    }

    /// Push a chunk of raw stdout to the terminal. Bytes are
    /// queued in the producer-side coalescer; the flush callback
    /// base64-encodes and calls `window.pushChunk(...)` in the JS
    /// side. Safe to call from any thread.
    public func pushStdout(_ chunk: Data) {
        if chunk.isEmpty { return }
        coalescer.append(chunk)
        // Kick off a delayed evaluator on the main queue. The
        // coalescer schedules its own flush; on flush we drain.
        // We don't drain here because the coalescer's onFlush
        // closure handles the bridge call.
    }

    // MARK: - private

    private func loadBundleIndex() {
        guard let url = Self.resourceURL else {
            assertionFailure("TerminalView: bundled index.html not found")
            return
        }
        // baseURL must point at the parent directory so xterm.js,
        // xterm.css, addon-fit.js, addon-web-links.js resolve.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// URL of the bundled index.html, if present. Public so tests
    /// can sanity-check the bundle without instantiating WKWebView
    /// (which is heavier and headless-unfriendly).
    public static var resourceURL: URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: BridgeHandler.self)
        #endif
        return bundle.url(forResource: "index", withExtension: "html", subdirectory: "Terminal")
            ?? bundle.url(forResource: "index", withExtension: "html")
    }

    /// Decoded JS→native bridge message. Exposed (along with the
    /// static `parseBridgeMessage`) so tests can verify parsing
    /// without instantiating a WKWebView.
    public enum BridgeMessage: Equatable {
        case ready
        case stdin(String)
        case resize(cols: Int, rows: Int)
    }

    /// Pure parser for the JS bridge message dictionaries. Returns
    /// `nil` for malformed inputs (missing/wrong-type fields), which
    /// the runtime path silently drops. Unit-testable; the
    /// instance-side `handleBridgeMessage` is a thin router on top.
    public static func parseBridgeMessage(_ body: Any) -> BridgeMessage? {
        guard let dict = body as? [String: Any], let kind = dict["kind"] as? String else { return nil }
        switch kind {
        case "ready":
            return .ready
        case "stdin":
            guard let data = dict["data"] as? String else { return nil }
            return .stdin(data)
        case "resize":
            guard let cols = dict["cols"] as? Int, let rows = dict["rows"] as? Int,
                  cols > 0, rows > 0 else { return nil }
            return .resize(cols: cols, rows: rows)
        default:
            return nil
        }
    }

    /// Internal: invoked by `BridgeHandler` on every JS→native
    /// message. Routes parsed messages to the delegate.
    func handleBridgeMessage(_ body: Any) {
        guard let msg = Self.parseBridgeMessage(body) else { return }
        switch msg {
        case .ready:
            isReady = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.terminalViewDidBecomeReady(self)
            }
        case .stdin(let data):
            delegate?.terminalView(self, didReceiveStdin: data)
        case .resize(let cols, let rows):
            delegate?.terminalView(self, didResizeTo: cols, rows: rows)
        }
    }

    /// Internal: flush callback the coalescer fires. Renders the
    /// batched bytes via `evaluateJavaScript("window.pushChunk(...)")`
    /// on the main queue.
    fileprivate func emitFlush(_ payload: Data) {
        let b64 = payload.base64EncodedString()
        // Single-quoted JS string is safe because base64 never
        // contains quotes / backslashes.
        let js = "window.pushChunk('\(b64)')"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// Inner class so WKScriptMessageHandler conformance doesn't leak
/// into the public surface. Owner is a weak ref so dealloc is
/// clean.
final class BridgeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: TerminalView?
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleBridgeMessage(message.body)
    }
}

#endif
