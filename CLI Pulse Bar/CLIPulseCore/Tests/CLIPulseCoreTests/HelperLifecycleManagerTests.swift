import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Tests for `HelperLifecycleManager`, the Phase 4 helper-bundling
/// surface that registers the embedded `cli_pulse_helper` LaunchAgent
/// via `SMAppService.agent(plistName:)`.
///
/// We do NOT spin up SMAppService against launchd here (that's an
/// integration concern that needs a real signed app bundle). These
/// tests cover:
///
///   * Agent label / plist filename pinning — the LaunchAgent plist
///     filename and `Label` field MUST match for SMAppService to
///     resolve them. A typo in either drift breaks registration.
///   * Pure plist-template substitution — placeholder syntax + every
///     of the four expected tokens get replaced verbatim.
///   * Bundle-layout helpers return the right paths under a fake
///     bundle structure (helps catch refactor breakage).
final class HelperLifecycleManagerTests: XCTestCase {

    // MARK: - Naming contract

    func testAgentLabelMatchesPlistFilename() {
        // SMAppService.agent(plistName:) resolves the on-disk plist
        // by name. The plist's <Label> field MUST equal the filename
        // minus `.plist`. Any drift between the two strings breaks
        // registration silently (launchd accepts the plist but the
        // app's `service.status` check refers to a different label
        // and reports "not registered").
        XCTAssertEqual(
            HelperLifecycleManager.agentPlistName,
            "\(HelperLifecycleManager.agentLabel).plist",
            "agent plist filename and Label MUST stay in sync; SMAppService pairs them by exact match"
        )
    }

    func testAgentPlistResourceNameIsBaseFileName() {
        // Bundle.main.url(forResource:withExtension:) takes the
        // basename without `.plist`. Pin so a future refactor that
        // changes the bundled file's name updates both halves.
        XCTAssertEqual(
            HelperLifecycleManager.plistResourceName,
            "HelperAgent",
            "template plist resource name must match the actual file in CLI Pulse Bar/Resources/"
        )
    }

    // MARK: - Plist template substitution

    func testSubstitutePlistTemplate_replacesAllFourPlaceholders() {
        let template = """
        <plist>
          <dict>
            <key>ProgramArguments</key>
            <array>
              <string>__CLI_PULSE_HELPER_BIN__</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
              <key>CLI_PULSE_SUPABASE_URL</key>
              <string>__CLI_PULSE_SUPABASE_URL__</string>
              <key>CLI_PULSE_SUPABASE_ANON_KEY</key>
              <string>__CLI_PULSE_SUPABASE_ANON_KEY__</string>
            </dict>
            <key>StandardErrorPath</key>
            <string>__HOME__/Library/Logs/cli-pulse-helper.log</string>
          </dict>
        </plist>
        """

        let result = HelperLifecycleManager.substitutePlistTemplate(
            template,
            helperBinaryPath: "/Applications/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper",
            supabaseURL: "https://gkjwsxotmwrgqsvfijzs.supabase.co",
            supabaseAnonKey: "FAKE_ANON_KEY_FOR_TEST",
            homePath: "/Users/testuser"
        )

        XCTAssertTrue(result.contains("/Applications/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper"))
        XCTAssertTrue(result.contains("https://gkjwsxotmwrgqsvfijzs.supabase.co"))
        XCTAssertTrue(result.contains("FAKE_ANON_KEY_FOR_TEST"))
        XCTAssertTrue(result.contains("/Users/testuser/Library/Logs/cli-pulse-helper.log"))
        // None of the placeholder tokens may survive the rewrite —
        // a leftover `__CLI_PULSE_…__` substring would land in the
        // installed plist and launchd would happily try to exec a
        // path called literally `__CLI_PULSE_HELPER_BIN__`.
        XCTAssertFalse(result.contains("__CLI_PULSE_HELPER_BIN__"))
        XCTAssertFalse(result.contains("__CLI_PULSE_SUPABASE_URL__"))
        XCTAssertFalse(result.contains("__CLI_PULSE_SUPABASE_ANON_KEY__"))
        XCTAssertFalse(result.contains("__HOME__"))
    }

    func testSubstitutePlistTemplate_handlesPathsWithSpaces() {
        // CLI Pulse Bar.app contains a space; helper binary path
        // includes the bundle name verbatim. Make sure the
        // substitution doesn't mangle paths the way shell-quote
        // bugs did in iter5 — string-replace is purely literal.
        let template = "<string>__CLI_PULSE_HELPER_BIN__</string>"
        let path = "/Applications/CLI Pulse Bar.app/Contents/Helpers/cli_pulse_helper"
        let result = HelperLifecycleManager.substitutePlistTemplate(
            template,
            helperBinaryPath: path,
            supabaseURL: "",
            supabaseAnonKey: "",
            homePath: "/h"
        )
        XCTAssertEqual(result, "<string>\(path)</string>")
    }

    func testSubstitutePlistTemplate_emptyAnonKeySurvives() {
        // Pre-pair builds (no Info.plist SUPABASE_ANON_KEY) end up
        // here with an empty string. The substitution should still
        // produce a syntactically valid plist; launchd won't reject
        // an empty-value EnvironmentVariables string.
        let template = """
        <key>CLI_PULSE_SUPABASE_ANON_KEY</key><string>__CLI_PULSE_SUPABASE_ANON_KEY__</string>
        """
        let result = HelperLifecycleManager.substitutePlistTemplate(
            template,
            helperBinaryPath: "/p",
            supabaseURL: "",
            supabaseAnonKey: "",
            homePath: "/h"
        )
        XCTAssertEqual(
            result,
            "<key>CLI_PULSE_SUPABASE_ANON_KEY</key><string></string>"
        )
    }

    // MARK: - Bundle layout helpers

    func testLocateBundledHelperBinary_returnsNilForTestBundle() {
        // The XCTest runner bundle has no Contents/Helpers/
        // cli_pulse_helper. Pin that the lookup returns nil rather
        // than misresolving to some other path the test runner has
        // executable bits on. Production builds populate that path
        // via the Phase 4 Run Script + Copy Files build phases.
        XCTAssertNil(
            HelperLifecycleManager.locateBundledHelperBinary(),
            "test bundle should not have an embedded helper; if this fails, the test runner's bundle layout changed"
        )
    }

    func testAgentPlistPath_returnsNilForXCTestRuntime() {
        // The xctest runner is not a .app bundle; `Bundle.main.
        // bundleURL` lands on the test bundle / xctest CLI which
        // has no `.app` extension. Pin that the lookup returns
        // nil rather than producing a nonsense path under
        // `/Applications/Xcode.app/Contents/Developer/usr/...`
        // (the pre-fix behaviour walked up from executableURL and
        // resolved a useless URL there). Production .app bundles
        // hit a different code path which is integration-tested
        // against a signed build.
        XCTAssertNil(
            HelperLifecycleManager.agentPlistPath(),
            "non-.app bundle should return nil; if this fails, the test runtime is now somehow inside a real .app and the bundle-detection heuristic needs updating"
        )
    }
}

#endif
