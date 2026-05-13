import XCTest
@testable import HelperKit
import Foundation

/// Tests for `SupabaseConfigResolver`, the daemon-side reader of
/// Supabase URL + anonKey. Walks from the daemon's exe path up to
/// the sibling app's `Info.plist`, with env-var fallback.
final class SupabaseConfigResolverTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupabaseResolver-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tmp, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    // MARK: - Bundle layer

    func testResolve_walksFromHelperExePathToInfoPlist() throws {
        // Build a fake .app bundle structure:
        //   tmp/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper
        //   tmp/CLI Pulse Bar.app/Contents/Info.plist
        let appPath = tmp.appendingPathComponent("CLI Pulse Bar.app")
        let contentsPath = appPath.appendingPathComponent("Contents")
        let helpersPath = contentsPath.appendingPathComponent("Helpers")
        let infoPlistPath = contentsPath.appendingPathComponent("Info.plist")
        let exePath = helpersPath.appendingPathComponent("cli_pulse_helper")

        try FileManager.default.createDirectory(
            at: helpersPath, withIntermediateDirectories: true)
        try Data().write(to: exePath)

        let infoDict: [String: Any] = [
            "SUPABASE_URL": "https://prod.supabase.co",
            "SUPABASE_ANON_KEY": "eyJfake-jwt-token",
            "CFBundleIdentifier": "yyh.CLI-Pulse",
        ]
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: infoDict, format: .xml, options: 0)
        try plistData.write(to: infoPlistPath)

        let resolved = SupabaseConfigResolver.resolve(
            exePath: exePath.path,
            environment: [:]
        )
        XCTAssertEqual(resolved?.url, "https://prod.supabase.co")
        XCTAssertEqual(resolved?.anonKey, "eyJfake-jwt-token")
    }

    func testResolve_returnsNil_whenInfoPlistMissingKeys() throws {
        let appPath = tmp.appendingPathComponent("CLI Pulse Bar.app")
        let contentsPath = appPath.appendingPathComponent("Contents")
        let helpersPath = contentsPath.appendingPathComponent("Helpers")
        let infoPlistPath = contentsPath.appendingPathComponent("Info.plist")
        let exePath = helpersPath.appendingPathComponent("cli_pulse_helper")

        try FileManager.default.createDirectory(
            at: helpersPath, withIntermediateDirectories: true)
        try Data().write(to: exePath)

        // Info.plist present but missing the two Supabase keys
        let infoDict: [String: Any] = ["CFBundleIdentifier": "yyh.CLI-Pulse"]
        try PropertyListSerialization.data(
            fromPropertyList: infoDict, format: .xml, options: 0)
            .write(to: infoPlistPath)

        let resolved = SupabaseConfigResolver.resolve(
            exePath: exePath.path,
            environment: [:]
        )
        XCTAssertNil(resolved, "missing keys must NOT fall back to empty strings")
    }

    func testResolve_returnsNil_whenInfoPlistMissing() throws {
        // Helper exe exists but no Info.plist in the expected location
        let exePath = tmp.appendingPathComponent("loose_binary")
        try Data().write(to: exePath)

        let resolved = SupabaseConfigResolver.resolve(
            exePath: exePath.path,
            environment: [:]
        )
        XCTAssertNil(resolved)
    }

    // MARK: - Environment fallback

    func testResolve_fallsBackToEnv_whenBundleMissing() {
        // Daemon launched outside an .app bundle (swift run / tests)
        let resolved = SupabaseConfigResolver.resolve(
            exePath: "/usr/local/bin/cli_pulse_helper",
            environment: [
                "CLI_PULSE_SUPABASE_URL": "https://dev.supabase.co",
                "CLI_PULSE_SUPABASE_ANON_KEY": "dev-anon-key",
            ]
        )
        XCTAssertEqual(resolved?.url, "https://dev.supabase.co")
        XCTAssertEqual(resolved?.anonKey, "dev-anon-key")
    }

    func testResolve_bundlePrecedence_overEnv() throws {
        // Bundle WINS when both populated — env is for dev override
        // when bundle isn't available, not when both are present.
        let appPath = tmp.appendingPathComponent("CLI Pulse Bar.app")
        let contentsPath = appPath.appendingPathComponent("Contents")
        let helpersPath = contentsPath.appendingPathComponent("Helpers")
        let infoPlistPath = contentsPath.appendingPathComponent("Info.plist")
        let exePath = helpersPath.appendingPathComponent("cli_pulse_helper")
        try FileManager.default.createDirectory(
            at: helpersPath, withIntermediateDirectories: true)
        try Data().write(to: exePath)
        let infoDict: [String: Any] = [
            "SUPABASE_URL": "https://bundle.supabase.co",
            "SUPABASE_ANON_KEY": "bundle-anon-key",
        ]
        try PropertyListSerialization.data(
            fromPropertyList: infoDict, format: .xml, options: 0)
            .write(to: infoPlistPath)

        let resolved = SupabaseConfigResolver.resolve(
            exePath: exePath.path,
            environment: [
                "CLI_PULSE_SUPABASE_URL": "https://env.override.co",
                "CLI_PULSE_SUPABASE_ANON_KEY": "env-override-key",
            ]
        )
        XCTAssertEqual(resolved?.url, "https://bundle.supabase.co",
                       "bundle Info.plist must beat env override when both present")
    }

    func testResolve_returnsNil_whenBothSourcesEmpty() {
        let resolved = SupabaseConfigResolver.resolve(
            exePath: "/tmp/nonexistent",
            environment: [:]
        )
        XCTAssertNil(resolved)
    }

    func testResolve_returnsNil_whenEnvHasOnlyURL() {
        let resolved = SupabaseConfigResolver.resolve(
            exePath: "/tmp/nonexistent",
            environment: ["CLI_PULSE_SUPABASE_URL": "https://only-url.co"]
        )
        XCTAssertNil(resolved, "both keys must be populated for env fallback")
    }
}
