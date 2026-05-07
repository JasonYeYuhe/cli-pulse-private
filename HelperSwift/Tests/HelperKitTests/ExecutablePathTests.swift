import XCTest
@testable import HelperKit
import Foundation

/// Phase 4D iter11 (Codex P1④): pin the contract that
/// `ExecutablePath.current()` returns an actual absolute on-disk
/// path, NOT a launchd argv-label or relative form. The previous
/// implementation used `CommandLine.arguments.first` which under
/// LaunchAgent spawn returns the `ProgramArguments[0]` label
/// (e.g. `cli_pulse_helper`), not the binary path — embedding
/// that label in the `--settings` inline JSON caused Claude's
/// hook subprocess to fail-to-exec.
final class ExecutablePathTests: XCTestCase {

    func testCurrentReturnsAbsolutePath() {
        guard let path = ExecutablePath.current() else {
            XCTFail("ExecutablePath.current() returned nil — _NSGetExecutablePath should always work")
            return
        }
        XCTAssertTrue(path.hasPrefix("/"),
                      "executable path must be absolute, got: \(path)")
    }

    func testCurrentResolvesToActualOnDiskBinary() {
        guard let path = ExecutablePath.current() else {
            XCTFail("ExecutablePath.current() returned nil")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "executable path must point at a file that exists, got: \(path)")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                      "path must be executable, got: \(path)")
    }

    func testCurrentIsCanonicalised() {
        guard let path = ExecutablePath.current() else {
            XCTFail("ExecutablePath.current() returned nil")
            return
        }
        // Path should not contain `..` or `./` artifacts after
        // standardisation. Symlink traversal is allowed (the
        // resolved path may differ from the spawn-supplied
        // arg) but the result must be self-consistent.
        XCTAssertFalse(path.contains("/.."),
                       "path must not contain '..' segments after canonicalisation: \(path)")
        XCTAssertFalse(path.contains("/./"),
                       "path must not contain './' segments: \(path)")
    }
}
