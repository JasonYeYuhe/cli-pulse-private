import XCTest
@testable import HelperKit

/// v1.35 managed-session spawn-env seam: HelperEnvironment (getpwuid HOME + augmented
/// PATH) + PtyTransport.buildChildEnv (parent ⊕ overlay ⊕ HOME/PATH ⊖ remove ⊕ defaults).
final class ManagedEnvSeamTests: XCTestCase {

    // MARK: HelperEnvironment

    func test_resolvedUserHome_isAbsoluteOnNonRoot() {
        // CI + dev run non-root, so the home must resolve to an absolute path.
        let home = HelperEnvironment.resolvedUserHome()
        XCTAssertNotNil(home)
        XCTAssertTrue(home?.hasPrefix("/") ?? false, "home must be absolute, got \(home ?? "nil")")
    }

    func test_augmentedPATH_appendsBinDirsAndInterpolatesHome() {
        let path = HelperEnvironment.augmentedPATH(base: "/usr/bin", home: "/Users/x")
        let dirs = path.split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains("/usr/bin"))
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
        XCTAssertTrue(dirs.contains("/usr/local/bin"))
        XCTAssertTrue(dirs.contains("/Users/x/.local/bin"))
        XCTAssertFalse(path.contains("$HOME"), "home must be interpolated, not a literal $HOME")
    }

    func test_augmentedPATH_dedupesAndHandlesNilBase() {
        // Already-present dir not duplicated.
        let path = HelperEnvironment.augmentedPATH(base: "/opt/homebrew/bin:/usr/bin", home: nil)
        XCTAssertEqual(path.components(separatedBy: ":").filter { $0 == "/opt/homebrew/bin" }.count, 1)
        // nil home → no .local/bin entry, but still adds the brew/local dirs.
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertFalse(path.contains(".local/bin"))
    }

    // MARK: buildChildEnv

    func test_buildChildEnv_overlayWinsOverParent() {
        let env = PtyTransport.buildChildEnv(
            parent: ["A": "1", "B": "9"], overlay: ["A": "2", "C": "3"],
            envRemove: [], cols: 80, rows: 24)
        XCTAssertEqual(env["A"], "2")   // overlay wins
        XCTAssertEqual(env["B"], "9")   // parent preserved
        XCTAssertEqual(env["C"], "3")   // overlay-only
    }

    func test_buildChildEnv_forcesResolvedHomeOverBogusParentHome() {
        // The launchd-/var/empty-HOME fix: a wrong parent HOME is replaced by the
        // getpwuid home when the caller didn't set one.
        let resolved = HelperEnvironment.resolvedUserHome()
        let env = PtyTransport.buildChildEnv(
            parent: ["HOME": "/var/empty"], overlay: [:],
            envRemove: [], cols: 80, rows: 24)
        XCTAssertEqual(env["HOME"], resolved)
        XCTAssertNotEqual(env["HOME"], "/var/empty")
    }

    func test_buildChildEnv_callerHomeWins() {
        let env = PtyTransport.buildChildEnv(
            parent: ["HOME": "/var/empty"], overlay: ["HOME": "/Users/caller"],
            envRemove: [], cols: 80, rows: 24)
        XCTAssertEqual(env["HOME"], "/Users/caller")
    }

    func test_buildChildEnv_augmentsPath() {
        let env = PtyTransport.buildChildEnv(
            parent: ["PATH": "/usr/bin"], overlay: [:],
            envRemove: [], cols: 80, rows: 24)
        let dirs = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        XCTAssertTrue(dirs.contains("/usr/bin"))
        XCTAssertTrue(dirs.contains("/opt/homebrew/bin"))
    }

    func test_buildChildEnv_removeDeletesInheritedKey() {
        // The core reason `remove` exists: scrub an inherited OPENAI_API_KEY.
        let env = PtyTransport.buildChildEnv(
            parent: ["OPENAI_API_KEY": "sk-leak", "KEEP": "1"], overlay: [:],
            envRemove: ["OPENAI_API_KEY"], cols: 80, rows: 24)
        XCTAssertNil(env["OPENAI_API_KEY"])
        XCTAssertEqual(env["KEEP"], "1")
    }

    func test_buildChildEnv_removeWinsOverOverlaySet() {
        let env = PtyTransport.buildChildEnv(
            parent: [:], overlay: ["X": "set-then-removed"],
            envRemove: ["X"], cols: 80, rows: 24)
        XCTAssertNil(env["X"])
    }

    func test_buildChildEnv_termAndSizeDefaults() {
        let env = PtyTransport.buildChildEnv(
            parent: [:], overlay: [:], envRemove: [], cols: 120, rows: 40)
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["COLUMNS"], "120")
        XCTAssertEqual(env["LINES"], "40")
    }

    func test_buildChildEnv_callerTermWins() {
        let env = PtyTransport.buildChildEnv(
            parent: [:], overlay: ["TERM": "dumb"], envRemove: [], cols: 80, rows: 24)
        XCTAssertEqual(env["TERM"], "dumb")
    }

    // MARK: ProviderEnvPatch + default

    func test_defaultEnvPatch_isEmpty() {
        let patch = ClaudeSpawner(buildInlineSettings: { _ in nil }).envPatch(extraEnv: [:], resolvedHome: "/Users/x")
        XCTAssertEqual(patch, .none)
    }
}
