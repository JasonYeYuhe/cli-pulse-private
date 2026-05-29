#if os(iOS) || os(visionOS)
import XCTest
@testable import CLIPulseCore

/// Static-surface tests for `RemoteTerminalView`. Instantiating the
/// UIView itself in an XCTest host SIGABRTs (no host UIScene; see
/// `feedback_filtered_swift_test_blind_spot`), so we test
/// `parseBridgeMessage` and the bundled-resource lookup directly —
/// same pattern the Mac `TerminalViewTests` already establishes.
final class RemoteTerminalViewTests: XCTestCase {

    // MARK: - parseBridgeMessage

    func test_parseBridgeMessage_ready() {
        let msg = RemoteTerminalView.parseBridgeMessage(["kind": "ready"])
        XCTAssertEqual(msg, .ready)
    }

    func test_parseBridgeMessage_stdin_string() {
        let msg = RemoteTerminalView.parseBridgeMessage([
            "kind": "stdin",
            "data": "hello\n",
        ])
        XCTAssertEqual(msg, .stdin("hello\n"))
    }

    func test_parseBridgeMessage_stdin_preserves_control_bytes() {
        // xterm.js sends Ctrl-C as the literal 0x03 character
        // (encoded as a UTF-8 string of length 1). The parser must
        // not touch the payload — slice 2's send_input_raw RPC
        // depends on the byte landing in the PTY unchanged.
        let ctrlC = String(UnicodeScalar(0x03)!)  // "\u{0003}"
        let msg = RemoteTerminalView.parseBridgeMessage([
            "kind": "stdin",
            "data": ctrlC,
        ])
        XCTAssertEqual(msg, .stdin(ctrlC))
    }

    func test_parseBridgeMessage_resize() {
        let msg = RemoteTerminalView.parseBridgeMessage([
            "kind": "resize",
            "cols": 80,
            "rows": 24,
        ])
        XCTAssertEqual(msg, .resize(cols: 80, rows: 24))
    }

    func test_parseBridgeMessage_resize_rejects_zero() {
        // 0×0 winsize is invalid (ratatui hard-newlines after each
        // CJK glyph per feedback_pty_winsize_gotcha); the helper
        // would reject the resize anyway. Reject at the parse
        // boundary so the bridge doesn't even fire.
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "resize",
            "cols": 0,
            "rows": 24,
        ]))
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "resize",
            "cols": 80,
            "rows": 0,
        ]))
    }

    func test_parseBridgeMessage_rejects_unknown_kind() {
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "selection",  // some future xterm.js callback
            "data": "...",
        ]))
    }

    func test_parseBridgeMessage_rejects_missing_kind() {
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "data": "hi",
        ]))
    }

    func test_parseBridgeMessage_rejects_wrong_type_for_kind() {
        // Defensive: a future JS-side bug shouldn't crash the
        // native path. Numbers / arrays / nil are all rejected.
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": 42,
        ]))
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage("just a string"))
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage(NSNull()))
    }

    func test_parseBridgeMessage_stdin_rejects_missing_data() {
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "stdin",
            // no "data"
        ]))
    }

    func test_parseBridgeMessage_resize_rejects_non_int_dims() {
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "resize",
            "cols": "80",
            "rows": 24,
        ]))
    }

    // MARK: - v1.26 B1: scrollback cap injection

    func test_iosScrollbackLines_isPhoneSafeDefault() {
        // Phones are tight on RAM; 500 lines × 80 col × 4 B ≈ 160 KB
        // per session. Don't bump without measuring multi-session
        // WKWebView pressure.
        XCTAssertEqual(RemoteTerminalView.iosScrollbackLines, 500)
    }

    func test_scrollbackConfigScript_setsTerminalConfigGlobal() {
        let js = RemoteTerminalView.scrollbackConfigScript(scrollback: 500)
        // Must set the same global the bundled index.html reads.
        XCTAssertTrue(js.contains("window.TERMINAL_CONFIG"))
        XCTAssertTrue(js.contains("scrollback"))
        XCTAssertTrue(js.contains("500"))
    }

    func test_scrollbackConfigScript_clampsNonPositiveToOne() {
        // JS-side already ignores invalid values, but spell out the
        // injection contract — never emit 0 / negative, which xterm.js
        // documents as "disable scrollback entirely" and would clear
        // the buffer on every resize.
        XCTAssertTrue(RemoteTerminalView.scrollbackConfigScript(scrollback: 0).contains(": 1 "))
        XCTAssertTrue(RemoteTerminalView.scrollbackConfigScript(scrollback: -10).contains(": 1 "))
    }

    /// The bundled index.html must read `window.TERMINAL_CONFIG.scrollback`
    /// (the contract `scrollbackConfigScript` writes to). This pins the
    /// JS-side shape so a refactor of the HTML can't silently break the
    /// iOS cap. Mac side gets the default (5000) because it never
    /// injects a `TERMINAL_CONFIG`.
    func test_bundledIndexHTML_readsTerminalConfigScrollback() throws {
        let url = try XCTUnwrap(RemoteTerminalView.resourceURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("window.TERMINAL_CONFIG"),
                      "index.html must consume window.TERMINAL_CONFIG.scrollback")
        XCTAssertTrue(html.contains("config.scrollback"),
                      "index.html must read .scrollback off the config")
        // Default-fallback path stays at 5000 (Mac, no injection).
        XCTAssertTrue(html.contains("5000"),
                      "index.html must keep 5000 as the fallback default")
    }

    // MARK: - v1.26 B3: JS bridge crash defense

    /// `decodeB64` is the rAF batcher's first action on every native
    /// pushChunk call. A misconfigured proxy or rogue DevTools script
    /// could send malformed base64; `atob` would throw
    /// `InvalidCharacterError` and surface a noisy bridge error.
    /// Pin the try/catch so a refactor can't silently regress it.
    func test_bundledIndexHTML_defendsAgainstMalformedBase64() throws {
        let url = try XCTUnwrap(RemoteTerminalView.resourceURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        // The try/catch must wrap atob; verify both pieces are there
        // and that the catch returns null (so pushChunk can short-circuit).
        XCTAssertTrue(html.contains("try {"),
                      "decodeB64 must wrap atob in try")
        XCTAssertTrue(html.contains("atob(b64)"),
                      "decodeB64 must still call atob — defense is wrapping, not replacing")
        XCTAssertTrue(html.contains("return null;"),
                      "decodeB64 catch must return null sentinel for pushChunk to drop")
    }

    /// `term.write` should never throw on well-formed Uint8Array, but
    /// a future xterm.js upgrade or a corrupt write should not strand
    /// `pendingChunks` at length > 0 forever — the rAF callback drains
    /// the buffer in every frame, and a swallow-and-continue keeps
    /// the pump from wedging on one bad chunk.
    func test_bundledIndexHTML_termWriteIsExceptionSafe() throws {
        let url = try XCTUnwrap(RemoteTerminalView.resourceURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("term.write(merged[i])"),
                      "rAF loop must call term.write per merged chunk")
        // The swallow comment is the discoverable marker for the
        // try/catch around term.write.
        XCTAssertTrue(html.contains("swallow"),
                      "rAF loop's term.write must be wrapped in try/catch")
    }

    // MARK: - v1.26.1 telemetry: jsError bridge message

    func test_parseBridgeMessage_jsError() {
        let msg = RemoteTerminalView.parseBridgeMessage([
            "kind": "jserror",
            "context": "term_write",
            "message": "TypeError: cannot read x",
        ])
        XCTAssertEqual(msg, .jsError(context: "term_write", message: "TypeError: cannot read x"))
    }

    func test_parseBridgeMessage_jsError_rejects_missing_fields() {
        // No context → reject (we key the Sentry category on it).
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "jserror",
            "message": "boom",
        ]))
        // No message → reject.
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "jserror",
            "context": "term_write",
        ]))
        // Empty context → reject (would produce a useless category).
        XCTAssertNil(RemoteTerminalView.parseBridgeMessage([
            "kind": "jserror",
            "context": "",
            "message": "boom",
        ]))
    }

    /// The bundled index.html must report the swallowed term.write
    /// throw to native (rate-limited once per load) so the guard
    /// isn't invisible in the field.
    func test_bundledIndexHTML_reportsTermWriteSwallowToNative() throws {
        let url = try XCTUnwrap(RemoteTerminalView.resourceURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(html.contains("reportJsError"),
                      "index.html must define a reportJsError bridge hop")
        XCTAssertTrue(html.contains("jsErrorReported"),
                      "reportJsError must be rate-limited once per load")
        XCTAssertTrue(html.contains("'jserror'") || html.contains("\"jserror\""),
                      "reportJsError must post a 'jserror' bridge kind")
        XCTAssertTrue(html.contains("reportJsError('term_write'"),
                      "term.write catch must call reportJsError('term_write', e)")
    }

    // MARK: - resourceURL

    func test_resourceURL_finds_bundled_index_html() {
        let url = RemoteTerminalView.resourceURL
        XCTAssertNotNil(url, "vendored xterm.js index.html must ship in CLIPulseCore.Resources/Terminal/")
        if let url {
            XCTAssertTrue(url.lastPathComponent == "index.html")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "resource URL points at non-existent file: \(url.path)")
        }
    }
}
#endif
