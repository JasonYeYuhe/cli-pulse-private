import XCTest
@testable import HelperKit

/// v1.35 managed Codex + Gemini on-plan: GeminiSpawner→agy routing + CodexSpawner
/// plan-auth env patch (CODEX_HOME pin + gated OPENAI_API_KEY scrub).
final class ManagedProviderSpawnerTests: XCTestCase {

    // MARK: GeminiSpawner → agy

    func test_gemini_resolveAgyArgv0_honorsExplicitOverride() {
        let r = GeminiSpawner.resolveAgyArgv0(env: ["CLI_PULSE_GEMINI_ARGV0": "/custom/agy --foo"])
        XCTAssertEqual(r, ["/custom/agy", "--foo"])
    }

    func test_gemini_buildArgv_bareByDefault() {
        // Default managed launch is a bare interactive agy — NO seed in argv.
        XCTAssertEqual(
            GeminiSpawner.buildArgv(argv0: ["/opt/homebrew/bin/agy"], yoloRequested: false, helpText: nil),
            ["/opt/homebrew/bin/agy"])
    }

    func test_gemini_buildArgv_yoloAppendsSkipPermsWhenSupported() {
        let help = "Options:\n  --dangerously-skip-permissions  Auto-approve all tool permission requests\n"
        XCTAssertEqual(
            GeminiSpawner.buildArgv(argv0: ["agy"], yoloRequested: true, helpText: help),
            ["agy", "--dangerously-skip-permissions"])
    }

    func test_gemini_buildArgv_yoloFailsSafeWhenFlagAbsent() {
        // Flag drift: if this agy doesn't advertise the flag, degrade to interactive
        // approvals rather than spawn with an unknown flag.
        XCTAssertEqual(
            GeminiSpawner.buildArgv(argv0: ["agy"], yoloRequested: true, helpText: "usage: agy [no such flag]"),
            ["agy"])
        XCTAssertEqual(
            GeminiSpawner.buildArgv(argv0: ["agy"], yoloRequested: true, helpText: nil),
            ["agy"])
    }

    func test_gemini_envFlagEnabled() {
        for yes in ["1", "true", "TRUE", "yes", " Yes "] { XCTAssertTrue(GeminiSpawner.envFlagEnabled(yes)) }
        for no in [nil, "", "0", "false", "off"] { XCTAssertFalse(GeminiSpawner.envFlagEnabled(no)) }
    }

    // MARK: CodexSpawner plan-auth

    private func loader(_ json: String) -> ((URL) -> Data?) { { _ in Data(json.utf8) } }

    func test_codex_verified_chatgptWithAccessToken() {
        let j = #"{"auth_mode":"chatgpt","tokens":{"access_token":"abc"}}"#
        XCTAssertTrue(CodexSpawner.hasVerifiedChatGPTAuth(home: "/Users/x", fileLoader: loader(j)))
    }

    func test_codex_verified_chatgptWithRefreshOnly() {
        let j = #"{"auth_mode":"chatgpt","tokens":{"refresh_token":"r"}}"#
        XCTAssertTrue(CodexSpawner.hasVerifiedChatGPTAuth(home: "/Users/x", fileLoader: loader(j)))
    }

    func test_codex_notVerified_apikeyMode() {
        let j = #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x"}"#
        XCTAssertFalse(CodexSpawner.hasVerifiedChatGPTAuth(home: "/Users/x", fileLoader: loader(j)))
    }

    func test_codex_notVerified_missingMode() {
        let j = #"{"tokens":{"access_token":"abc"}}"#
        XCTAssertFalse(CodexSpawner.hasVerifiedChatGPTAuth(home: "/Users/x", fileLoader: loader(j)))
    }

    func test_codex_notVerified_chatgptButNoToken() {
        let j = #"{"auth_mode":"chatgpt","tokens":{}}"#
        XCTAssertFalse(CodexSpawner.hasVerifiedChatGPTAuth(home: "/Users/x", fileLoader: loader(j)))
    }

    func test_codex_notVerified_unreadable() {
        XCTAssertFalse(CodexSpawner.hasVerifiedChatGPTAuth(home: "/Users/x", fileLoader: { _ in nil }))
    }

    func test_codex_envPatch_pinsCodexHome() {
        // resolvedHome="/Users/x" → CODEX_HOME pinned; no real auth.json there so no scrub.
        let patch = CodexSpawner().envPatch(extraEnv: [:], resolvedHome: "/Users/x")
        XCTAssertEqual(patch.set["CODEX_HOME"], "/Users/x/.codex")
    }

    func test_codex_envPatch_nilHomeNoPin() {
        let patch = CodexSpawner().envPatch(extraEnv: [:], resolvedHome: nil)
        XCTAssertNil(patch.set["CODEX_HOME"])
    }
}
