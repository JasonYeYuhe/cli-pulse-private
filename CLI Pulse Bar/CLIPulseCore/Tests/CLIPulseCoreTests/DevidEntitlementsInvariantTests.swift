#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// W1-A ship-config guard. Reads the entitlements SOURCE files from the repo
/// (resolved relative to this test file) and asserts the sandbox/app-group/
/// keychain matrix that `scripts/build_signed_app.sh` relies on. If anyone
/// accidentally re-adds the App Sandbox to the DEVID file (which would re-hide
/// the in-app terminal) or strips the app-group from a file (which would break
/// the helper UDS/keychain), this fails in `swift test` long before a build.
///
/// The build script's own Python verifier checks the SIGNED products on the
/// DEVID/Debug CI builds; this complements it by guarding the inputs in the
/// fast unit suite.
final class DevidEntitlementsInvariantTests: XCTestCase {

    private let sandboxKey = "com.apple.security.app-sandbox"
    private let appGroupsKey = "com.apple.security.application-groups"
    private let keychainKey = "keychain-access-groups"
    private let bookmarksKey = "com.apple.security.files.bookmarks.app-scope"
    private let groupSuffix = "group.yyh.CLI-Pulse"

    /// Repo root, walked up from this test file:
    /// <root>/CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/<this>.swift
    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CLIPulseCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // CLIPulseCore
            .deletingLastPathComponent()  // CLI Pulse Bar
            .deletingLastPathComponent()  // <root>
    }

    private func loadEntitlements(_ relativePath: String,
                                  file: StaticString = #filePath,
                                  line: UInt = #line) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("entitlements not found at \(url.path)", file: file, line: line)
            return [:]
        }
        guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            XCTFail("could not parse entitlements plist at \(url.path)", file: file, line: line)
            return [:]
        }
        return dict
    }

    private func hasGroup(_ dict: [String: Any], _ key: String, suffix: String) -> Bool {
        guard let arr = dict[key] as? [String] else { return false }
        return arr.contains { $0.hasSuffix(suffix) }
    }

    // MARK: - App entitlements

    func test_masAppEntitlements_areSandboxed_withGroups() throws {
        let mas = try loadEntitlements("CLI Pulse Bar/CLI Pulse Bar/CLI_Pulse_Bar.entitlements")
        XCTAssertEqual(mas[sandboxKey] as? Bool, true, "MAS app MUST keep the App Sandbox")
        XCTAssertTrue(hasGroup(mas, appGroupsKey, suffix: groupSuffix), "MAS app missing app-group")
        XCTAssertTrue(hasGroup(mas, keychainKey, suffix: groupSuffix), "MAS app missing keychain group")
    }

    func test_devidAppEntitlements_areUnsandboxed_butKeepGroups() throws {
        let devid = try loadEntitlements("CLI Pulse Bar/CLI Pulse Bar/CLI_Pulse_Bar_devid.entitlements")
        XCTAssertNil(devid[sandboxKey],
                     "DEVID app MUST NOT be sandboxed — that hides the in-app terminal")
        XCTAssertNil(devid[bookmarksKey],
                     "DEVID app should drop the sandbox-only app-scope bookmarks entitlement")
        XCTAssertTrue(hasGroup(devid, appGroupsKey, suffix: groupSuffix),
                      "DEVID app MUST keep the app-group (helper UDS/token)")
        XCTAssertTrue(hasGroup(devid, keychainKey, suffix: groupSuffix),
                      "DEVID app MUST keep the keychain group (prompt-free secrets)")
    }

    // MARK: - LoginItem entitlements

    func test_masLoginItem_isSandboxed() throws {
        let mas = try loadEntitlements("CLI Pulse Bar/CLIPulseHelper/CLIPulseHelper.entitlements")
        XCTAssertEqual(mas[sandboxKey] as? Bool, true,
                       "MAS LoginItem MUST be sandboxed (ITMS-90296)")
        XCTAssertTrue(hasGroup(mas, appGroupsKey, suffix: groupSuffix))
        XCTAssertTrue(hasGroup(mas, keychainKey, suffix: groupSuffix))
    }

    func test_devidLoginItem_isUnsandboxed_butKeepsGroups() throws {
        let devid = try loadEntitlements("CLI Pulse Bar/CLIPulseHelper/CLIPulseHelper_devid.entitlements")
        XCTAssertNil(devid[sandboxKey],
                     "DEVID LoginItem MUST be unsandboxed (no embedded profile to authorise restricted entitlements)")
        XCTAssertTrue(hasGroup(devid, appGroupsKey, suffix: groupSuffix))
        XCTAssertTrue(hasGroup(devid, keychainKey, suffix: groupSuffix))
    }

    // MARK: - LaunchAgent helper

    func test_launchAgentHelper_isUnsandboxed_withGroups() throws {
        let helper = try loadEntitlements("HelperSwift/cli_pulse_helper.entitlements")
        XCTAssertNil(helper[sandboxKey], "LaunchAgent helper MUST NOT be sandboxed")
        XCTAssertTrue(hasGroup(helper, appGroupsKey, suffix: groupSuffix))
        XCTAssertTrue(hasGroup(helper, keychainKey, suffix: groupSuffix))
    }
}
#endif
