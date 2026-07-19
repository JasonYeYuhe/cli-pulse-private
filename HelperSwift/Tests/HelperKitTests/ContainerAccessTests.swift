import XCTest
@testable import HelperKit
import Foundation

/// `ContainerAccess.rotateTokenWaitingForContainer` — the Swift side of the
/// container-stall problem. Cousin of `helper/test_container_watchdog.py`, but
/// deliberately NOT the same design (see below).
///
/// The bundled Swift helper called `AuthToken.rotateToken()` straight on the main
/// thread with only a `try/catch`. The catch encoded the right policy ("continuing
/// with empty token") but a HANG never throws, so it never ran. Observed live
/// 2026-07-17: blocked in `open` for minutes (2564/2564 samples) inside a TCC
/// `kTCCServiceSystemPolicyAppData` consult, holding a "CLI Pulse would like to
/// access data from other apps" dialog open. Worse than the Python helper's
/// respawn loop, because launchd cannot recover a hung process.
///
/// Why this WAITS instead of degrading like the Python fix does: the Swift helper's
/// pairing lives in the same container (`UserDefaults(suiteName:)`), so a stalled
/// container leaves nothing to degrade to. And it must not retry: a retry opens a
/// SECOND consult (a second dialog) and races the first on AuthToken's fixed tmp
/// path.
final class ContainerAccessTests: XCTestCase {

    func testFastRotationReturnsTheToken() throws {
        let token = try ContainerAccess.rotateTokenWaitingForContainer(
            reportEvery: 5.0, rotate: { "TOKEN-OK" })
        XCTAssertEqual(token, "TOKEN-OK")
    }

    func testSlowButCompletingRotationStillReturnsItsToken() throws {
        // The TCC consult is routinely slow under launchd (1–10s) and then
        // COMPLETES. A ceiling tuned to an imagined "warm" cost kills exactly
        // these starts — that was the Python helper's 12s mistake, and the reason
        // this side has no ceiling at all.
        var reports = 0
        let token = try ContainerAccess.rotateTokenWaitingForContainer(
            reportEvery: 0.1,
            rotate: {
                Thread.sleep(forTimeInterval: 0.45)
                return "TOKEN-SLOW"
            },
            log: { _ in reports += 1 }
        )
        XCTAssertEqual(token, "TOKEN-SLOW", "a slow-but-completing consult must never be abandoned")
        XCTAssertGreaterThan(reports, 0, "a stall must be reported, not silent")
    }

    func testRotateIsCalledExactlyOnceEvenWhenSlow() throws {
        // The property that matters most for the USER's symptom. Each rotate() is
        // an open(2) = a fresh TCC consult = another permission dialog. The old
        // Python design re-asked 2,816 times in a night. Exactly one consult must
        // be in flight, ever.
        let lock = NSLock()
        var calls = 0
        _ = try ContainerAccess.rotateTokenWaitingForContainer(
            reportEvery: 0.05,
            rotate: {
                lock.lock(); calls += 1; lock.unlock()
                Thread.sleep(forTimeInterval: 0.4)   // several report intervals
                return "TOKEN"
            }
        )
        lock.lock(); let n = calls; lock.unlock()
        XCTAssertEqual(n, 1, "must hold ONE consult open, never open a second dialog")
    }

    func testStallDoesNotBlockInsideOpenOnTheCallingThread() throws {
        // The regression that matters. Pre-fix, rotate ran ON the caller, so a
        // stall parked the main thread inside open(2) in the kernel: silent,
        // unkillable by launchd, forever. Now the caller waits on a semaphore it
        // can observe and report from, and the process stays killable.
        let observed = expectation(description: "caller observed the stall and reported it")
        observed.expectedFulfillmentCount = 1
        observed.assertForOverFulfill = false
        DispatchQueue.global().async {
            _ = try? ContainerAccess.rotateTokenWaitingForContainer(
                reportEvery: 0.1,
                rotate: {
                    Thread.sleep(forTimeInterval: 0.6)
                    return "LATE"
                },
                log: { _ in observed.fulfill() }
            )
        }
        wait(for: [observed], timeout: 2.0)
    }

    func testThrowPropagates() {
        // A throw is NOT a stall — the container answered, it just refused. So the
        // caller's existing best-effort path (start with an empty token) is
        // correct, and binding stays safe.
        struct Boom: Error {}
        XCTAssertThrowsError(
            try ContainerAccess.rotateTokenWaitingForContainer(
                reportEvery: 1.0, rotate: { throw Boom() })
        ) { error in
            XCTAssertTrue(error is Boom)
        }
    }

    func testEmptyTokenNeverAuthenticates() {
        // What makes the throw path safe: main.swift starts the server with token
        // "" when rotation THROWS. On a socket any local process can connect(2)
        // to, an empty expected token must never match.
        XCTAssertFalse(AuthToken.compare(expected: "", supplied: ""))
        XCTAssertFalse(AuthToken.compare(expected: "", supplied: "anything"))
        XCTAssertFalse(AuthToken.compare(expected: "real-token", supplied: ""))
        XCTAssertTrue(AuthToken.compare(expected: "real-token", supplied: "real-token"))
    }
}

/// `RuntimeRoot` — the private runtime root that replaces the app-group container.
final class RuntimeRootTests: XCTestCase {

    private func scratch() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse-rr-\(UUID().uuidString.prefix(8))")
    }

    func testCreatesRootAt0700WhenAbsent() throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        setenv(RuntimeRoot.overrideEnvVar, root.path, 1)
        defer { unsetenv(RuntimeRoot.overrideEnvVar) }

        let resolved = try RuntimeRoot.secureRoot()
        XCTAssertEqual(resolved.path, root.path)
        var st = stat()
        XCTAssertEqual(lstat(root.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "a fresh root must be created private")
    }

    func testTightensAPreExistingLooseRootInsteadOfRefusing() throws {
        // THE REGRESSION THIS PINS. ~/.clipulse already exists at 0755 on real
        // machines (ClaudeSnapshotWriter has written there for ages). Refusing it
        // would fail token rotation on every existing install — the helper would
        // run with an empty token and every gated RPC would fail closed, i.e.
        // local session control silently dead.
        let root = scratch()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        chmod(root.path, 0o755)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv(RuntimeRoot.overrideEnvVar, root.path, 1)
        defer { unsetenv(RuntimeRoot.overrideEnvVar) }

        XCTAssertNoThrow(try RuntimeRoot.secureRoot(),
                         "a loose root we OWN must be tightened, never refused")
        var st = stat()
        XCTAssertEqual(lstat(root.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700, "it must end up private")
    }

    func testRefusesASymlinkedRoot() throws {
        // A symlink lets another user redirect our auth token to a path they
        // control. No chmod fixes that, so it must be refused.
        let real = scratch(); let link = scratch()
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link); try? FileManager.default.removeItem(at: real) }
        setenv(RuntimeRoot.overrideEnvVar, link.path, 1)
        defer { unsetenv(RuntimeRoot.overrideEnvVar) }

        XCTAssertThrowsError(try RuntimeRoot.secureRoot(),
                             "a symlinked runtime root must be refused")
    }

    func testRefusesANonDirectory() throws {
        let file = scratch()
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        setenv(RuntimeRoot.overrideEnvVar, file.path, 1)
        defer { unsetenv(RuntimeRoot.overrideEnvVar) }
        XCTAssertThrowsError(try RuntimeRoot.secureRoot())
    }

    func testDefaultRootIsTheHomeDotdirNotTheContainer() {
        unsetenv(RuntimeRoot.overrideEnvVar)
        let p = RuntimeRoot.path().path
        XCTAssertTrue(p.hasSuffix("/.clipulse"), "got \(p)")
        XCTAssertFalse(p.contains("Group Containers"),
                       "the runtime root must NOT be under the TCC-protected container prefix")
    }
}
