import XCTest
@testable import CLIPulseCore

#if os(macOS)

final class LocalScannerTests: XCTestCase {

    private let scanner = LocalScanner.shared

    // MARK: - No match

    func testNoMatchReturnsNil() {
        XCTAssertNil(scanner.detectProvider("some random process --flag"))
    }

    func testEmptyCommandReturnsNil() {
        XCTAssertNil(scanner.detectProvider(""))
    }

    func testUnrelatedCommandReturnsNil() {
        XCTAssertNil(scanner.detectProvider("/usr/bin/python3 myscript.py"))
    }

    // MARK: - Codex

    func testCodexHighConfidence() {
        let result = scanner.detectProvider("/usr/local/bin/codex --project /Users/jason/app")
        XCTAssertEqual(result?.0, "Codex")
        XCTAssertEqual(result?.1, "high")
    }

    func testOpenAIMediumConfidence() {
        let result = scanner.detectProvider("/usr/local/bin/openai chat")
        XCTAssertEqual(result?.0, "Codex")
        XCTAssertEqual(result?.1, "medium")
    }

    // MARK: - Claude

    func testClaudeHighConfidence() {
        let result = scanner.detectProvider("/opt/claude/bin/claude --project myapp")
        XCTAssertEqual(result?.0, "Claude")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Gemini

    func testGeminiHighConfidence() {
        let result = scanner.detectProvider("gemini code --dir /Users/jason/code")
        XCTAssertEqual(result?.0, "Gemini")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Cursor

    func testCursorHighConfidence() {
        let result = scanner.detectProvider("/Applications/Cursor.app/Contents/MacOS/Cursor")
        XCTAssertEqual(result?.0, "Cursor")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Ollama

    func testOllamaHighConfidence() {
        let result = scanner.detectProvider("/usr/local/bin/ollama serve")
        XCTAssertEqual(result?.0, "Ollama")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Copilot

    func testCopilotHighConfidence() {
        let result = scanner.detectProvider("node /home/user/.vscode/extensions/github.copilot-chat/dist/extension.js")
        XCTAssertEqual(result?.0, "Copilot")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - OpenRouter

    func testOpenRouterHighConfidence() {
        let result = scanner.detectProvider("/usr/local/bin/openrouter --model gpt-4o")
        XCTAssertEqual(result?.0, "OpenRouter")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - JetBrains AI

    func testJetBrainsAIHighConfidence() {
        let result = scanner.detectProvider("/Applications/IntelliJ IDEA.app/jbai-assistant")
        XCTAssertEqual(result?.0, "JetBrains AI")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Kimi K2 vs Kimi priority

    func testKimiK2TakesPriorityOverKimi() {
        let result = scanner.detectProvider("/usr/local/bin/kimi-k2 serve")
        XCTAssertEqual(result?.0, "Kimi K2")
        XCTAssertEqual(result?.1, "high")
    }

    func testKimiMatchesWithoutK2() {
        let result = scanner.detectProvider("/usr/local/bin/kimi chat")
        XCTAssertEqual(result?.0, "Kimi")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Case insensitivity

    func testCaseInsensitiveMatch() {
        let result = scanner.detectProvider("CLAUDE --version")
        XCTAssertEqual(result?.0, "Claude")
    }

    func testMixedCaseGemini() {
        let result = scanner.detectProvider("Gemini-Pro-CLI start")
        XCTAssertEqual(result?.0, "Gemini")
    }

    // MARK: - Perplexity

    func testPerplexityHighConfidence() {
        let result = scanner.detectProvider("perplexity-cli --search")
        XCTAssertEqual(result?.0, "Perplexity")
        XCTAssertEqual(result?.1, "high")
    }

    func testPplxAbbreviationMatches() {
        let result = scanner.detectProvider("/usr/local/bin/pplx run")
        XCTAssertEqual(result?.0, "Perplexity")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Confidence ranking: high beats medium

    func testHighConfidenceBeatsMediumInSameCommand() {
        // "codex" (high) + "openai" (medium) — high should win
        let result = scanner.detectProvider("/usr/local/bin/codex openai-wrapper")
        XCTAssertEqual(result?.0, "Codex")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - Warp (medium)

    func testWarpMediumConfidence() {
        let result = scanner.detectProvider("/Applications/Warp.app/Contents/MacOS/Warp")
        XCTAssertEqual(result?.0, "Warp")
        XCTAssertEqual(result?.1, "medium")
    }

    // MARK: - Node-launched CLIs (regression for sessions data staleness)

    /// Claude Code / Codex CLI / Gemini CLI etc. often run as
    /// `/usr/local/bin/node /path/to/tool.js …`. Historical `proc_pidpath`
    /// returned only `/usr/local/bin/node`, which matched nothing and left
    /// `public.sessions` empty on Supabase. With the argv-concatenated
    /// command string, the `\bclaude\b` / `\bcodex\b` patterns inside the
    /// script path must now match.
    func testNodeLaunchedCodexMatches() {
        let cmd = "/usr/local/bin/node /Users/jason/.claude/plugins/cache/openai-codex/codex/1.0.1/scripts/app-server-broker.mjs serve"
        let result = scanner.detectProvider(cmd)
        XCTAssertEqual(result?.0, "Codex")
        XCTAssertEqual(result?.1, "high")
    }

    func testNodeLaunchedClaudeCodeMatches() {
        let cmd = "/opt/homebrew/bin/node /Users/jason/.claude/local/node_modules/@anthropic-ai/claude-code/cli.js --print"
        let result = scanner.detectProvider(cmd)
        XCTAssertEqual(result?.0, "Claude")
        XCTAssertEqual(result?.1, "high")
    }

    // MARK: - processArgs(pid:)

    /// Run against the test process itself — every process has argv, so
    /// argv[0] must be non-empty. Verifies the sysctl(KERN_PROCARGS2) walk
    /// produces something we can decode back into UTF-8.
    func testProcessArgsForSelf() {
        let args = LocalScanner.processArgs(pid: getpid())
        XCTAssertNotNil(args, "KERN_PROCARGS2 should succeed for own pid")
        XCTAssertFalse(args?.isEmpty ?? true, "self argv must contain at least argv[0]")
        XCTAssertFalse(args?.first?.isEmpty ?? true, "argv[0] must be non-empty")
    }

    // MARK: - LocalScanner rough-edges (2026-04-25 iter1)

    /// The Claude desktop app installs a Chrome native-messaging host bridge
    /// whose argv contains the literal string "Claude" plus the Chrome
    /// extension id. The provider regex `\bclaude\b` would otherwise create a
    /// zombie "Claude" session for the bridge — `shouldIgnore` must catch it.
    func testChromeNativeHostBridgeIgnored() {
        let nativeHostCommand =
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome Helper " +
            "--type=utility " +
            "/Applications/Claude.app/Contents/Resources/nativehost/chrome-native-host " +
            "fcoeoabgfenejglbffodgkkbkcdhcgfn"
        XCTAssertTrue(
            scanner.shouldIgnore(nativeHostCommand),
            "Claude Chrome native-host bridge must be ignored"
        )

        let bundleIdForm = "node /opt/homebrew/Cellar/com.anthropic.claude.nativehost/host.js"
        XCTAssertTrue(
            scanner.shouldIgnore(bundleIdForm),
            "com.anthropic.claude.nativehost bundle id must be ignored"
        )

        let appPathForm = "/Applications/Claude.app/Contents/Helpers/nativehost arg"
        XCTAssertTrue(
            scanner.shouldIgnore(appPathForm),
            "Claude.app/.../nativehost path form must be ignored"
        )
    }

    /// Real `claude` CLI invocations from inside `Claude.app/Contents/Resources`
    /// must NOT be swept up by the native-host ignore rules. We deliberately
    /// scoped the patterns to `nativehost` / extension id to avoid this.
    func testClaudeCLIInsideAppBundleStillCounted() {
        let cliCommand = "/Applications/Claude.app/Contents/Resources/cli/claude --project /Users/jason/work"
        XCTAssertFalse(
            scanner.shouldIgnore(cliCommand),
            "claude CLI bundled with the desktop app must NOT be ignored"
        )
    }

    /// Node-launched broker scripts often live in a version directory
    /// (e.g. `…/codex/1.0.1/scripts/app-server-broker.mjs`). The label must
    /// not be the version dir, the `scripts` dir, or the `.mjs` filename.
    func testGuessProjectRejectsVersionDirAndScriptLeaf() {
        let cmd = "node /Users/jason/.claude/plugins/cache/openai-codex/codex/1.0.1/scripts/app-server-broker.mjs --port 9000"
        let label = scanner.guessProject(cmd)
        XCTAssertNotEqual(label, "1.0.1")
        XCTAssertNotEqual(label, "scripts")
        XCTAssertNotEqual(label, "app-server-broker.mjs")
        // `codex` is the first acceptable basename when walking up past
        // version + reserved-name dirs. (`openai-codex` would also pass, but
        // the leaf-walk only goes two hops; this asserts what the algorithm
        // currently produces, not the only label that would be acceptable.)
        XCTAssertNotEqual(label, "unknown", "should find SOME human-friendly label, got 'unknown'")
    }

    /// `broker.pid` is a runtime sidecar — the project label must reject it
    /// outright via the suffix list (`.pid`).
    func testGuessProjectRejectsPidSidecar() {
        let cmd = "/usr/local/bin/codex /Users/jason/.codex/broker.pid"
        let label = scanner.guessProject(cmd)
        XCTAssertNotEqual(label, "broker.pid")
        XCTAssertNotEqual(label, ".codex", "hidden dotdir must not be the label either")
    }

    /// When `guessProjectRoot` finds a repo marker, the call site uses that
    /// directory's basename as the project label. This is a behavioural test
    /// using a tmp directory containing `.git`.
    func testRepoMarkerBasenameIsPreferred() throws {
        let tmpRoot = FileManager.default.temporaryDirectory.appendingPathComponent("clipulse-test-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpRoot) }

        let gitMarker = tmpRoot.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: gitMarker, withIntermediateDirectories: true)

        // Plant a node script under the tmp repo and verify guessProjectRoot
        // walks up to it.
        let scriptDir = tmpRoot.appendingPathComponent("packages/cli")
        try FileManager.default.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        let scriptPath = scriptDir.appendingPathComponent("entry.js").path

        let cmd = "node \(scriptPath)"
        let root = scanner.guessProjectRoot(cmd)
        XCTAssertEqual(root, tmpRoot.path, "guessProjectRoot must return the dir containing .git")
        XCTAssertEqual(
            (root.map { ($0 as NSString).lastPathComponent }) ?? "",
            tmpRoot.lastPathComponent,
            "basename of the repo root is the preferred project label"
        )
    }

    /// `/Applications/Claude.app/Contents/MacOS/Claude` is an app bundle
    /// dead-end — Claude/MacOS/Contents are reserved infra names and must
    /// not become the project label. Falls through to `unknown`.
    func testGuessProjectRejectsAppBundleLeaf() {
        let cmd = "/Applications/Claude.app/Contents/MacOS/Claude"
        let label = scanner.guessProject(cmd)
        XCTAssertNotEqual(label, "Claude")
        XCTAssertNotEqual(label, "MacOS")
        XCTAssertNotEqual(label, "Contents")
        XCTAssertEqual(label, "unknown", "Claude.app is a dead-end for project labelling")
    }
}

#endif
