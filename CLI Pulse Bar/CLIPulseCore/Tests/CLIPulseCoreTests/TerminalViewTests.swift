#if os(macOS)
import XCTest
@testable import CLIPulseCore
import Foundation

/// Phase 3 slice 2 — pure-Swift tests for TerminalView's bridge
/// message parser and the vendored xterm.js bundle layout. Skips
/// the WKWebView instance path so tests stay fast and headless.
final class TerminalViewTests: XCTestCase {

    // MARK: - parseBridgeMessage (pure, no WKWebView)

    func test_parseReady() {
        let body: [String: Any] = ["kind": "ready"]
        XCTAssertEqual(TerminalView.parseBridgeMessage(body), .ready)
    }

    func test_parseStdinWithData() {
        let body: [String: Any] = ["kind": "stdin", "data": "ls\r"]
        XCTAssertEqual(TerminalView.parseBridgeMessage(body), .stdin("ls\r"))
    }

    func test_parseStdinControlByteString_passesThrough() {
        // xterm.js sends Ctrl-C as a single-character string "\u{0003}".
        let body: [String: Any] = ["kind": "stdin", "data": "\u{0003}"]
        XCTAssertEqual(TerminalView.parseBridgeMessage(body), .stdin("\u{0003}"))
    }

    func test_parseStdinMissingData_returnsNil() {
        let body: [String: Any] = ["kind": "stdin"]
        XCTAssertNil(TerminalView.parseBridgeMessage(body))
    }

    func test_parseStdinNonStringData_returnsNil() {
        let body: [String: Any] = ["kind": "stdin", "data": 42]
        XCTAssertNil(TerminalView.parseBridgeMessage(body))
    }

    func test_parseResize() {
        let body: [String: Any] = ["kind": "resize", "cols": 132, "rows": 50]
        XCTAssertEqual(TerminalView.parseBridgeMessage(body), .resize(cols: 132, rows: 50))
    }

    func test_parseResizeMissingCols_returnsNil() {
        let body: [String: Any] = ["kind": "resize", "rows": 50]
        XCTAssertNil(TerminalView.parseBridgeMessage(body))
    }

    func test_parseResizeZeroOrNegative_returnsNil() {
        // FitAddon can briefly report 0×0 during DOM measure — the
        // parser drops these so they don't propagate to the helper's
        // resize RPC (which the LocalSessionServer would 400 on).
        XCTAssertNil(TerminalView.parseBridgeMessage(
            ["kind": "resize", "cols": 0, "rows": 24]))
        XCTAssertNil(TerminalView.parseBridgeMessage(
            ["kind": "resize", "cols": 80, "rows": 0]))
        XCTAssertNil(TerminalView.parseBridgeMessage(
            ["kind": "resize", "cols": -5, "rows": 24]))
    }

    func test_parseTitle() {
        let body: [String: Any] = ["kind": "title", "title": "claude · ~/proj"]
        XCTAssertEqual(TerminalView.parseBridgeMessage(body), .title("claude · ~/proj"))
    }

    func test_parseTitleMissing_isEmptyString() {
        // OSC title-cleared (`ESC ]0;BEL`) arrives with no/empty title; the
        // adapter treats empty as "cleared" → falls back to the default window
        // title. Parser yields an empty-string title rather than nil.
        XCTAssertEqual(TerminalView.parseBridgeMessage(["kind": "title"]), .title(""))
    }

    func test_parseUnknownKind_returnsNil() {
        let body: [String: Any] = ["kind": "wat", "data": "x"]
        XCTAssertNil(TerminalView.parseBridgeMessage(body))
    }

    func test_parseMissingKind_returnsNil() {
        let body: [String: Any] = ["data": "x"]
        XCTAssertNil(TerminalView.parseBridgeMessage(body))
    }

    func test_parseNonDictBody_returnsNil() {
        XCTAssertNil(TerminalView.parseBridgeMessage("just a string"))
        XCTAssertNil(TerminalView.parseBridgeMessage(42))
        XCTAssertNil(TerminalView.parseBridgeMessage(NSNull()))
    }

    // MARK: - bundle resources

    func test_resourceURL_locatesIndexHtml() {
        let url = TerminalView.resourceURL
        XCTAssertNotNil(url, "expected bundled index.html to be reachable")
        guard let url else { return }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.lastPathComponent, "index.html")
    }

    func test_bundleContainsXtermAssets() {
        guard let indexURL = TerminalView.resourceURL else {
            XCTFail("index.html missing")
            return
        }
        let dir = indexURL.deletingLastPathComponent()
        // SPM `.process("Resources")` flattens the Terminal/ subdir
        // into the bundle root — so the four sibling assets live
        // next to index.html. Verify all are reachable.
        for name in ["xterm.js", "xterm.css", "addon-fit.js", "addon-web-links.js"] {
            let url = dir.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "missing vendored asset: \(name)")
        }
    }

    func test_indexHtmlReferencesBridgeMessageHandler() throws {
        guard let url = TerminalView.resourceURL else {
            XCTFail("index.html missing"); return
        }
        let html = try String(contentsOf: url, encoding: .utf8)
        // Sanity check the message-handler name matches what the
        // native side installs. If someone renames "terminal" on
        // either side without grep, this test fires.
        XCTAssertTrue(html.contains("webkit.messageHandlers.terminal"),
                      "index.html must post to `terminal` message handler")
        XCTAssertTrue(html.contains("window.pushChunk"),
                      "index.html must expose pushChunk for native→JS path")
        XCTAssertTrue(html.contains("requestAnimationFrame"),
                      "index.html must rAF-batch incoming chunks (Codex H1)")
    }
}
#endif
