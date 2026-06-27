import XCTest
@testable import CLIPulseCore

final class TerminalNavigationGuardTests: XCTestCase {

    private let bundleDir = URL(fileURLWithPath: "/tmp/clipulse-test/Terminal", isDirectory: true)

    func test_allows_index_within_bundle() {
        let url = bundleDir.appendingPathComponent("index.html")
        XCTAssertTrue(TerminalNavigationGuard.allows(url, bundleDirectory: bundleDir))
    }

    func test_allows_nested_asset_within_bundle() {
        let url = bundleDir.appendingPathComponent("assets/xterm.js")
        XCTAssertTrue(TerminalNavigationGuard.allows(url, bundleDirectory: bundleDir))
    }

    func test_allows_bundle_directory_itself() {
        XCTAssertTrue(TerminalNavigationGuard.allows(bundleDir, bundleDirectory: bundleDir))
    }

    func test_denies_https() {
        XCTAssertFalse(TerminalNavigationGuard.allows(URL(string: "https://evil.example.com/phish"), bundleDirectory: bundleDir))
    }

    func test_denies_http() {
        XCTAssertFalse(TerminalNavigationGuard.allows(URL(string: "http://10.0.0.1/"), bundleDirectory: bundleDir))
    }

    func test_denies_data_url() {
        XCTAssertFalse(TerminalNavigationGuard.allows(URL(string: "data:text/html,<script>alert(1)</script>"), bundleDirectory: bundleDir))
    }

    func test_denies_about_and_javascript() {
        XCTAssertFalse(TerminalNavigationGuard.allows(URL(string: "about:blank"), bundleDirectory: bundleDir))
        XCTAssertFalse(TerminalNavigationGuard.allows(URL(string: "javascript:alert(1)"), bundleDirectory: bundleDir))
    }

    func test_denies_file_outside_bundle() {
        let url = URL(fileURLWithPath: "/etc/passwd")
        XCTAssertFalse(TerminalNavigationGuard.allows(url, bundleDirectory: bundleDir))
    }

    func test_denies_parent_traversal_escape() {
        // file:///tmp/clipulse-test/Terminal/../secrets.txt → /tmp/clipulse-test/secrets.txt
        let url = bundleDir.appendingPathComponent("../secrets.txt")
        XCTAssertFalse(TerminalNavigationGuard.allows(url, bundleDirectory: bundleDir))
    }

    func test_denies_sibling_prefix_directory() {
        // A bare string-prefix check would wrongly allow ".../Terminal-evil/x".
        let url = URL(fileURLWithPath: "/tmp/clipulse-test/Terminal-evil/x.html")
        XCTAssertFalse(TerminalNavigationGuard.allows(url, bundleDirectory: bundleDir))
    }

    func test_denies_nil_url_or_nil_bundle() {
        XCTAssertFalse(TerminalNavigationGuard.allows(nil, bundleDirectory: bundleDir))
        XCTAssertFalse(TerminalNavigationGuard.allows(bundleDir.appendingPathComponent("index.html"), bundleDirectory: nil))
    }
}
