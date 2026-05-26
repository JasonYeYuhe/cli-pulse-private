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
