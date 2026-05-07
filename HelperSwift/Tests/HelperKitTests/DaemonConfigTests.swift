import XCTest
@testable import HelperKit

/// Phase 4E Slice 4 — pin the argv parsing for `cli_pulse_helper
/// daemon`. The daemon body itself is procedural launchd / GCD
/// wiring; isolating the parser gives us a unit-test seam.
final class DaemonConfigTests: XCTestCase {

    func test_default_when_argv_empty() {
        let cfg = DaemonConfig.parse([])
        XCTAssertEqual(cfg.legacyPython, false)
        XCTAssertEqual(cfg.intervalSeconds, 120)
        XCTAssertEqual(cfg.cloudTickSeconds, 1.0)
        XCTAssertEqual(cfg.cloudPullMax, 10)
    }

    func test_parses_legacy_python_flag() {
        let cfg = DaemonConfig.parse(["--legacy-python"])
        XCTAssertTrue(cfg.legacyPython)
    }

    func test_parses_interval_flag() {
        let cfg = DaemonConfig.parse(["--interval", "300"])
        XCTAssertEqual(cfg.intervalSeconds, 300)
    }

    func test_parses_cloud_tick_seconds() {
        let cfg = DaemonConfig.parse(["--cloud-tick-seconds", "0.5"])
        XCTAssertEqual(cfg.cloudTickSeconds, 0.5)
    }

    func test_parses_cloud_pull_max() {
        let cfg = DaemonConfig.parse(["--cloud-pull-max", "25"])
        XCTAssertEqual(cfg.cloudPullMax, 25)
    }

    func test_combines_all_flags() {
        let cfg = DaemonConfig.parse([
            "--interval", "180",
            "--cloud-tick-seconds", "2.5",
            "--cloud-pull-max", "50",
            "--legacy-python",
        ])
        XCTAssertEqual(cfg.intervalSeconds, 180)
        XCTAssertEqual(cfg.cloudTickSeconds, 2.5)
        XCTAssertEqual(cfg.cloudPullMax, 50)
        XCTAssertTrue(cfg.legacyPython)
    }

    func test_floors_below_minimum_values() {
        // intervalSeconds floor 60s, cloudTickSeconds 0.1s,
        // cloudPullMax 1 — all enforced in the initialiser.
        let cfg = DaemonConfig.parse([
            "--interval", "10",
            "--cloud-tick-seconds", "0.0",
            "--cloud-pull-max", "0",
        ])
        XCTAssertEqual(cfg.intervalSeconds, 60)
        XCTAssertEqual(cfg.cloudTickSeconds, 0.1)
        XCTAssertEqual(cfg.cloudPullMax, 1)
    }

    func test_ignores_unknown_flags_for_forward_compat() {
        // Future flag additions in newer plists must not crash an
        // older binary that's currently running. Unknown flags are
        // skipped; defaults stay intact.
        let cfg = DaemonConfig.parse([
            "--brand-new-flag", "value",
            "--legacy-python",
            "--another", "thing",
        ])
        XCTAssertTrue(cfg.legacyPython)
        XCTAssertEqual(cfg.intervalSeconds, 120)
    }

    func test_parses_invalid_numeric_value_falls_back_to_default() {
        // Invalid number for `--interval` → keep default 120.
        let cfg = DaemonConfig.parse(["--interval", "not-a-number"])
        XCTAssertEqual(cfg.intervalSeconds, 120)
    }
}
