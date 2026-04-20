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
}

#endif
