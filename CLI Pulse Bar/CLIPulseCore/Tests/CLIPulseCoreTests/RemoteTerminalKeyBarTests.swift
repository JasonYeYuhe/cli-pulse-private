#if os(iOS) || os(visionOS)
import XCTest
@testable import CLIPulseCore

/// Pins the wire bytes the iOS soft-keyboard helper bar emits.
/// SwiftUI View itself can't be instantiated in XCTest (no UIScene
/// host); the bytes are the contract, so we test those.
final class RemoteTerminalKeyBarTests: XCTestCase {

    // MARK: - control bytes

    func test_esc_is_single_0x1B() {
        XCTAssertEqual(RemoteTerminalKeyBar.esc, Data([0x1B]))
    }

    func test_tab_is_single_0x09() {
        XCTAssertEqual(RemoteTerminalKeyBar.tab, Data([0x09]))
    }

    func test_ctrl_c_is_single_0x03() {
        // The #1 phone-terminal use case (Gemini MEDIUM): aborting
        // a hung process. Pin the byte so a refactor can't break it.
        XCTAssertEqual(RemoteTerminalKeyBar.ctrlC, Data([0x03]))
    }

    func test_ctrl_d_is_single_0x04() {
        XCTAssertEqual(RemoteTerminalKeyBar.ctrlD, Data([0x04]))
    }

    // MARK: - CSI escape sequences (arrows)

    func test_up_is_CSI_A() {
        XCTAssertEqual(RemoteTerminalKeyBar.up, Data([0x1B, 0x5B, 0x41]))
    }

    func test_down_is_CSI_B() {
        XCTAssertEqual(RemoteTerminalKeyBar.down, Data([0x1B, 0x5B, 0x42]))
    }

    func test_right_is_CSI_C() {
        // bash readline forward-char / vi `l`. xterm terminfo
        // entry `kcuf1` == ESC [ C.
        XCTAssertEqual(RemoteTerminalKeyBar.right, Data([0x1B, 0x5B, 0x43]))
    }

    func test_left_is_CSI_D() {
        XCTAssertEqual(RemoteTerminalKeyBar.left, Data([0x1B, 0x5B, 0x44]))
    }

    // MARK: - VT220 page-nav sequences

    func test_pgUp_is_CSI_5_tilde() {
        XCTAssertEqual(RemoteTerminalKeyBar.pgUp, Data([0x1B, 0x5B, 0x35, 0x7E]))
    }

    func test_pgDn_is_CSI_6_tilde() {
        XCTAssertEqual(RemoteTerminalKeyBar.pgDn, Data([0x1B, 0x5B, 0x36, 0x7E]))
    }

    func test_home_is_CSI_H() {
        XCTAssertEqual(RemoteTerminalKeyBar.home, Data([0x1B, 0x5B, 0x48]))
    }

    func test_end_is_CSI_F() {
        XCTAssertEqual(RemoteTerminalKeyBar.end, Data([0x1B, 0x5B, 0x46]))
    }

    // MARK: - shape invariants

    func test_all_arrows_start_with_CSI_prefix() {
        for arrow in [RemoteTerminalKeyBar.up, .down, .left, .right] {
            XCTAssertEqual(arrow.prefix(2), Data([0x1B, 0x5B]),
                           "arrow byte sequence must start with ESC [: \(arrow.map { $0 })")
        }
    }

    func test_no_byte_sequence_is_empty() {
        // A degenerate constant (`Data()`) would silently drop
        // taps. Defend at the type system: every public sequence
        // is non-empty.
        let all: [(String, Data)] = [
            ("esc", .esc), ("tab", .tab),
            ("ctrlC", .ctrlC), ("ctrlD", .ctrlD),
            ("up", .up), ("down", .down), ("left", .left), ("right", .right),
            ("pgUp", .pgUp), ("pgDn", .pgDn),
            ("home", .home), ("end", .end),
        ]
        for (name, bytes) in all {
            XCTAssertFalse(bytes.isEmpty, "\(name) must not be empty")
        }
    }

    // MARK: - accessibility name mapping

    func test_accessibilityName_translates_arrow_glyphs() {
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("↑"), "Up arrow")
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("↓"), "Down arrow")
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("←"), "Left arrow")
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("→"), "Right arrow")
    }

    func test_accessibilityName_passes_text_labels_through() {
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("Esc"), "Esc")
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("Ctrl-C"), "Ctrl-C")
        XCTAssertEqual(RemoteTerminalKeyBar.accessibilityName("PgUp"), "PgUp")
    }
}

extension Data {
    fileprivate static var esc: Data { RemoteTerminalKeyBar.esc }
    fileprivate static var tab: Data { RemoteTerminalKeyBar.tab }
    fileprivate static var ctrlC: Data { RemoteTerminalKeyBar.ctrlC }
    fileprivate static var ctrlD: Data { RemoteTerminalKeyBar.ctrlD }
    fileprivate static var up: Data { RemoteTerminalKeyBar.up }
    fileprivate static var down: Data { RemoteTerminalKeyBar.down }
    fileprivate static var left: Data { RemoteTerminalKeyBar.left }
    fileprivate static var right: Data { RemoteTerminalKeyBar.right }
    fileprivate static var pgUp: Data { RemoteTerminalKeyBar.pgUp }
    fileprivate static var pgDn: Data { RemoteTerminalKeyBar.pgDn }
    fileprivate static var home: Data { RemoteTerminalKeyBar.home }
    fileprivate static var end: Data { RemoteTerminalKeyBar.end }
}
#endif
