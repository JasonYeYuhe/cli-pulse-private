import XCTest
@testable import HelperKit

/// Swift parity for the Python helper's `test_provider_spawners.py`
/// suite. Pins the v1.15 multi-CLI registry so a refactor that
/// drops Codex/Gemini support has to update these tests
/// intentionally.
final class ProviderSpawnerRegistryTests: XCTestCase {
    // MARK: - registry shape

    func test_standard_registry_has_three_known_providers() {
        let registry = ProviderSpawnerRegistry.standard()
        XCTAssertEqual(
            Set(registry.allProviderNames()),
            ["claude", "codex", "gemini"]
        )
    }

    func test_spawner_for_returns_instance_for_known() {
        let registry = ProviderSpawnerRegistry.standard()
        XCTAssertTrue(registry.spawner(for: "claude") is ClaudeSpawner)
        XCTAssertTrue(registry.spawner(for: "codex") is CodexSpawner)
        XCTAssertTrue(registry.spawner(for: "gemini") is GeminiSpawner)
    }

    func test_spawner_for_returns_nil_for_unknown() {
        let registry = ProviderSpawnerRegistry.standard()
        XCTAssertNil(registry.spawner(for: "totally-not-a-cli"))
    }

    func test_spawner_for_is_case_insensitive_and_trimmed() {
        let registry = ProviderSpawnerRegistry.standard()
        XCTAssertNotNil(registry.spawner(for: "Claude"))
        XCTAssertNotNil(registry.spawner(for: "CODEX"))
        XCTAssertNotNil(registry.spawner(for: "  Gemini "))
    }

    // MARK: - argv resolution

    func test_codex_argv_default() {
        XCTAssertEqual(
            CodexSpawner().argv(extraEnv: [:], helperArgv0: nil),
            ["codex"]
        )
    }

    // v1.35: managed Gemini routes through the `agy` wrapper (runs on the user's plan),
    // not bare `gemini`/`--yolo`. argv() does machine-dependent filesystem resolution, so
    // the deterministic contract is tested via the pure helpers (also in
    // ManagedProviderSpawnerTests).

    func test_gemini_routesThroughAgy_viaExplicitOverride() {
        XCTAssertEqual(
            GeminiSpawner.resolveAgyArgv0(env: ["CLI_PULSE_GEMINI_ARGV0": "/opt/x/agy"]),
            ["/opt/x/agy"])
    }

    func test_gemini_default_isBareAgy_noYolo() {
        XCTAssertEqual(
            GeminiSpawner.buildArgv(argv0: ["agy"], yoloRequested: false, helpText: nil),
            ["agy"])
    }

    func test_gemini_yolo_remapsToSkipPermissions_whenSupported() {
        for value in ["1", "true", "yes", "TRUE", " yes "] {
            XCTAssertTrue(GeminiSpawner.envFlagEnabled(value), "value=\(value)")
        }
        XCTAssertEqual(
            GeminiSpawner.buildArgv(argv0: ["agy"], yoloRequested: true,
                                    helpText: "  --dangerously-skip-permissions  Auto-approve"),
            ["agy", "--dangerously-skip-permissions"])
    }

    func test_gemini_yolo_falsy_keeps_default() {
        for value in ["", "0", "false", "no"] {
            XCTAssertFalse(GeminiSpawner.envFlagEnabled(value), "value=\(value)")
        }
    }

    // MARK: - claude inline-settings injection

    func test_claude_argv_default_no_settings_when_no_argv0() {
        let spawner = ClaudeSpawner(buildInlineSettings: { _ in "{}" })
        XCTAssertEqual(
            spawner.argv(extraEnv: [:], helperArgv0: nil),
            ["claude"]
        )
    }

    func test_claude_argv_appends_settings_json_when_argv0_provided() {
        let spawner = ClaudeSpawner(buildInlineSettings: { path in
            "{\"hook_path\":\"\(path)\"}"
        })
        let argv = spawner.argv(
            extraEnv: [:],
            helperArgv0: "/path/to/cli_pulse_helper"
        )
        XCTAssertEqual(argv.count, 3)
        XCTAssertEqual(argv[0], "claude")
        XCTAssertEqual(argv[1], "--settings")
        XCTAssertTrue(argv[2].contains("/path/to/cli_pulse_helper"))
    }

    func test_claude_argv_no_settings_when_builder_returns_nil() {
        // Builder may return nil if JSON serialization fails; the
        // spawn must still go ahead without the hook (degraded mode
        // — terminal-style approval prompts).
        let spawner = ClaudeSpawner(buildInlineSettings: { _ in nil })
        XCTAssertEqual(
            spawner.argv(extraEnv: [:], helperArgv0: "/path"),
            ["claude"]
        )
    }

    // MARK: - approval surface contract

    func test_only_claude_supports_remote_approval() {
        // Pinned so a future refactor that wires Codex/Gemini hooks
        // has to update this contract intentionally. The iOS picker
        // uses this signal to surface a "this session can't be
        // remote-approved" hint.
        XCTAssertTrue(ClaudeSpawner().supportsRemoteApproval())
        XCTAssertFalse(CodexSpawner().supportsRemoteApproval())
        XCTAssertFalse(GeminiSpawner().supportsRemoteApproval())
    }

    // MARK: - availability snapshot

    func test_available_providers_subset_of_all() {
        // Even on a host with zero CLIs installed, this returns a
        // (possibly empty) list — never raises.
        let registry = ProviderSpawnerRegistry.standard()
        let all = Set(registry.allProviderNames())
        let available = Set(registry.availableProviderNames())
        XCTAssertTrue(available.isSubset(of: all))
    }

    // MARK: - env flag parser parity (Gemini)

    func test_gemini_env_flag_parser_truthy_table() {
        XCTAssertTrue(GeminiSpawner.envFlagEnabled("1"))
        XCTAssertTrue(GeminiSpawner.envFlagEnabled("true"))
        XCTAssertTrue(GeminiSpawner.envFlagEnabled("yes"))
        XCTAssertTrue(GeminiSpawner.envFlagEnabled(" YES "))
        XCTAssertFalse(GeminiSpawner.envFlagEnabled(nil))
        XCTAssertFalse(GeminiSpawner.envFlagEnabled(""))
        XCTAssertFalse(GeminiSpawner.envFlagEnabled("0"))
        XCTAssertFalse(GeminiSpawner.envFlagEnabled("false"))
    }
}
