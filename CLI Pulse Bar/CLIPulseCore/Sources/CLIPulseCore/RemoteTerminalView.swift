// v1.25 Phase 4 slice 1 — RemoteTerminalView (iOS-side WKWebView host).
// Mirrors the Mac-side TerminalView but uses UIView; consumes
// `RemoteSessionEventStream.subscribeTerminal` to display stdout
// from a remote Mac helper's PTY in xterm.js.
//
// **Read-only in this slice.** onData (keystrokes) is parsed and
// forwarded to the delegate, but the iOS Sessions UI doesn't wire
// it to a remote send-input RPC yet — slice 2 lights that up.
//
// Shares the JS bundle (`Resources/Terminal/index.html` + xterm.js)
// with the Mac TerminalView. Producer-side bridge messages and the
// JS-side rAF batcher are identical; only the native UIView host
// differs between platforms.

#if os(iOS) || os(visionOS)
import UIKit
import WebKit
import Foundation

public protocol RemoteTerminalViewDelegate: AnyObject {
    /// Sent once the JS side has finished loading; consumer may
    /// safely call `pushStdout(_:)`. Called on the main queue.
    func remoteTerminalViewDidBecomeReady(_ view: RemoteTerminalView)
    /// User typed into the on-screen terminal. `data` is a raw
    /// UTF-8 string (per xterm.js's `onData` callback) — slice 2
    /// will convert this to `Data` and forward to `remoteSendInput`.
    func remoteTerminalView(_ view: RemoteTerminalView, didReceiveStdin data: String)
    /// Viewport size changed (e.g. rotation, soft-keyboard show).
    /// Slice 2 will forward to the helper via the `resize` RPC.
    func remoteTerminalView(_ view: RemoteTerminalView, didResizeTo cols: Int, rows: Int)
}

/// iOS / visionOS UIView host for the in-app terminal. Wraps a
/// WKWebView running the vendored xterm.js bundle and exposes a
/// thin Swift API for pushing output bytes / receiving input.
///
/// **Output path (helper → view):**
///   `pushStdout(Data)` → 16 ms `TerminalOutputCoalescer` → base64
///   → `evaluateJavaScript("window.pushChunk('<b64>')")` → JS-side
///   rAF batcher → `term.write()`. Combined bridge crossings cap at
///   ~60/sec (Codex H1).
///
/// **Input path (view → helper, slice 2):**
///   xterm.js `term.onData` → bridge → `terminalView(_:didReceiveStdin:)`
///   → consumer's `remoteSendInput(sessionId, bytes:)` RPC. Raw
///   bytes only (no CR-append), so 0x03 Ctrl-C reaches the PTY
///   intact.
public final class RemoteTerminalView: UIView {

    public weak var delegate: RemoteTerminalViewDelegate?

    /// Underlying WKWebView. Exposed for tests + diagnostics.
    /// Do NOT poke at its JS state directly — use `pushStdout(_:)`
    /// for output and the delegate for input.
    public let webView: WKWebView

    public private(set) var isReady: Bool = false

    private lazy var coalescer: TerminalOutputCoalescer = TerminalOutputCoalescer(
        windowSeconds: 0.016,
        flushQueue: .main,
        onFlush: { [weak self] payload in
            self?.emitFlush(payload)
        })
    private let messageHandler: RemoteTerminalBridgeHandler

    public override init(frame: CGRect) {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        let messageHandler = RemoteTerminalBridgeHandler()
        // v1.26 B1: iOS phones have a tight memory budget; 5000 lines
        // × ~80 cols × ~4 bytes ≈ 1.6 MB per session for the scrollback
        // alone. Inject `window.TERMINAL_CONFIG = {scrollback: 500}`
        // before the bundled JS reads it. Mac side never injects, so
        // it keeps the default 5000.
        let scrollbackScript = WKUserScript(
            source: Self.scrollbackConfigScript(scrollback: Self.iosScrollbackLines),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(scrollbackScript)
        config.userContentController.add(messageHandler, name: "terminal")

        self.webView = WKWebView(frame: .zero, configuration: config)
        self.messageHandler = messageHandler
        super.init(frame: frame)

        // Match the Mac side: terminal background is xterm.js's
        // default (black-on-paper). Make the WKWebView opaque so
        // the SwiftUI host can't bleed through during scroll.
        webView.isOpaque = true
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        // Disable WKWebView's native bounce — xterm.js handles its
        // own scrollback. Otherwise the WKWebView's rubber-band
        // fights the terminal's "follow tail" scroll behavior on
        // every burst of output.
        webView.scrollView.bounces = false
        // Default to keyboard-friendly viewport: don't auto-zoom
        // when the soft keyboard appears. Slice 3 will add a
        // helper bar above the keyboard for missing-key inputs.

        addSubview(webView)
        webView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        messageHandler.owner = self
        loadBundleIndex()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RemoteTerminalView does not support NSCoder")
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "terminal")
        coalescer.flushNow()
    }

    /// Push a chunk of raw stdout (or stderr) bytes into the
    /// terminal. Queues via the coalescer; the flush callback
    /// base64-encodes and calls `window.pushChunk(...)` on the
    /// main queue. Safe to call from any thread.
    public func pushStdout(_ chunk: Data) {
        if chunk.isEmpty { return }
        coalescer.append(chunk)
    }

    /// Wipe the visible terminal buffer. Used by the iOS Sessions
    /// view when the user switches between sessions (avoid mixing
    /// session A's output into session B's view).
    public func clear() {
        coalescer.flushNow()
        webView.evaluateJavaScript("if (window.term) { window.term.reset(); }",
                                   completionHandler: nil)
    }

    // MARK: - private

    private func loadBundleIndex() {
        guard let url = Self.resourceURL else {
            assertionFailure("RemoteTerminalView: bundled index.html not found")
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    /// iOS scrollback line cap (v1.26 B1). 500 × 80 col × 4 B ≈
    /// 160 KB per session — enough for "what did this just print"
    /// recall, capped before WKWebView starts paging on multi-session
    /// hosts. Mac side gets the JS default (5000) because the popover
    /// has memory headroom and power-user scrollback is the value-add.
    public static let iosScrollbackLines = 500

    /// WKUserScript source that sets `window.TERMINAL_CONFIG` before
    /// `index.html` runs. Unit-testable without instantiating
    /// WKWebView (`feedback_filtered_swift_test_blind_spot`): tests
    /// pin the literal shape against the JS-side read.
    public static func scrollbackConfigScript(scrollback: Int) -> String {
        // Defensive clamp: never inject 0 / negative; JS-side already
        // ignores invalid values but spelling it out here makes the
        // injection contract obvious.
        let n = max(1, scrollback)
        return "window.TERMINAL_CONFIG = { scrollback: \(n) };"
    }

    /// URL of the bundled index.html, if present. Same lookup as
    /// the Mac side (shared bundle) so we never drift on which
    /// asset version each platform sees.
    public static var resourceURL: URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: RemoteTerminalBridgeHandler.self)
        #endif
        return bundle.url(forResource: "index", withExtension: "html", subdirectory: "Terminal")
            ?? bundle.url(forResource: "index", withExtension: "html")
    }

    /// Bridge message shape (parallel to Mac's TerminalView.BridgeMessage).
    public enum BridgeMessage: Equatable {
        case ready
        case stdin(String)
        case resize(cols: Int, rows: Int)
        /// v1.26.1 telemetry: the JS bundle caught an exception in a
        /// last-resort guard (e.g. `term.write` swallow) and is
        /// reporting it so the native side can surface to Sentry —
        /// otherwise the swallow is invisible (Gemini FYI). `context`
        /// identifies the guard site; `message` is the JS error
        /// string (scrubbed by SentryLogger before send).
        case jsError(context: String, message: String)
    }

    /// Pure parser for JS bridge message dictionaries. Returns nil
    /// for malformed inputs. Unit-testable without instantiating
    /// WKWebView (which SIGABRTs in XCTest hosts per
    /// `feedback_filtered_swift_test_blind_spot`).
    public static func parseBridgeMessage(_ body: Any) -> BridgeMessage? {
        guard let dict = body as? [String: Any],
              let kind = dict["kind"] as? String
        else { return nil }
        switch kind {
        case "ready":
            return .ready
        case "stdin":
            guard let data = dict["data"] as? String else { return nil }
            return .stdin(data)
        case "resize":
            guard let cols = dict["cols"] as? Int,
                  let rows = dict["rows"] as? Int,
                  cols > 0, rows > 0
            else { return nil }
            return .resize(cols: cols, rows: rows)
        case "jserror":
            guard let context = dict["context"] as? String,
                  let message = dict["message"] as? String,
                  !context.isEmpty
            else { return nil }
            return .jsError(context: context, message: message)
        default:
            return nil
        }
    }

    func handleBridgeMessage(_ body: Any) {
        guard let msg = Self.parseBridgeMessage(body) else { return }
        switch msg {
        case .ready:
            isReady = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.remoteTerminalViewDidBecomeReady(self)
            }
        case .stdin(let data):
            delegate?.remoteTerminalView(self, didReceiveStdin: data)
        case .resize(let cols, let rows):
            delegate?.remoteTerminalView(self, didResizeTo: cols, rows: rows)
        case .jsError(let context, let message):
            // v1.26.1 telemetry: surface the swallowed JS guard to
            // Sentry. The JS side rate-limits to one report per
            // terminal load (see index.html `jsErrorReported`), so
            // this can't spam event quota. SentryLogger scrubs the
            // message before send.
            SentryLogger.captureWarning(
                message,
                category: "remote-terminal.\(context)")
        }
    }

    fileprivate func emitFlush(_ payload: Data) {
        let b64 = payload.base64EncodedString()
        let js = "window.pushChunk('\(b64)')"
        webView.evaluateJavaScript(js, completionHandler: nil)
    }
}

/// Inner class so `WKScriptMessageHandler` conformance doesn't
/// leak into the public surface.
final class RemoteTerminalBridgeHandler: NSObject, WKScriptMessageHandler {
    weak var owner: RemoteTerminalView?
    func userContentController(_ ucc: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        owner?.handleBridgeMessage(message.body)
    }
}

#endif
