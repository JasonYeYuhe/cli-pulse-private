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
        // Keep the resource basename aligned with the final
        // LaunchAgent plist filename copied into
        // Contents/Library/LaunchAgents.
        XCTAssertEqual(
            HelperLifecycleManager.plistResourceName,
            "yyh.CLI-Pulse.helper",
            "LaunchAgent resource basename must match the bundled plist filename without .plist"
        )
    }

    // MARK: - Bundle layout helpers
    //
    // Phase 4D P1.4 dropped the runtime plist-substitution path
    // because writing into a signed app bundle invalidates the
    // signature. The plist is shipped in its final form. The
    // substitutePlistTemplate tests it backed have been removed
    // along with the function; what remains is verifying that the
    // bundle-layout helpers find the plist and binary at the
    // expected paths.

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
