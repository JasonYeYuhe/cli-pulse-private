import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// Real-process tests for the PTY transport. We spawn `/bin/echo`
/// and `/bin/sh` to exercise the spawn / read / write / signal /
/// close paths end-to-end. These tests run the actual binary so
/// they catch real macOS posix_spawn / openpty edge cases the
/// pure unit tests would miss.
final class PtyTransportTests: XCTestCase {

    func testSpawnEchoAndReadOutput() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "T1",
            argv: ["/bin/echo", "hello-from-pty"],
            env: [:]
        )
        defer { pty.close(handle) }
        // Drain the output until EOF or 1s elapses.
        var output = Data()
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            let chunk = try pty.readStdout(handle)
            if !chunk.isEmpty {
                output.append(chunk)
            } else if !pty.isAlive(handle) {
                // Drain once more then break.
                let tail = try pty.readStdout(handle)
                output.append(tail)
                break
            }
            usleep(20_000)
        }
        let asString = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(asString.contains("hello-from-pty"),
                      "expected 'hello-from-pty' in PTY output, got: \(asString.debugDescription)")
    }

    func testSpawnEmptyArgvThrows() {
        let pty = PtyTransport()
        XCTAssertThrowsError(try pty.start(sessionId: "X", argv: [], env: [:])) { err in
            guard case PtyTransport.TransportError.emptyArgv = err else {
                XCTFail("expected emptyArgv, got \(err)"); return
            }
        }
    }

    func testSpawnNonexistentBinaryThrowsSpawnFailed() {
        let pty = PtyTransport()
        XCTAssertThrowsError(try pty.start(
            sessionId: "X",
            argv: ["/nonexistent/path/blam"],
            env: [:]
        )) { err in
            guard case PtyTransport.TransportError.spawnFailed = err else {
                XCTFail("expected spawnFailed, got \(err)"); return
            }
        }
    }

    func testWriteToShellAndReadEcho() throws {
        let pty = PtyTransport()
        // /bin/sh in interactive-ish mode (no -i; just a single
        // command via stdin then exit). Send a command, read back
        // the echo + result, then SIGTERM.
        let handle = try pty.start(
            sessionId: "T2",
            argv: ["/bin/sh"],
            env: [:]
        )
        defer { pty.close(handle) }
        // The shell may not be ready immediately; brief sleep
        // before the first write.
        usleep(100_000)
        let cmd = Data("echo writepath-ok\nexit\n".utf8)
        let n = try pty.writeStdin(handle, cmd)
        XCTAssertEqual(n, cmd.count)
        // Drain output until child exits or 2s.
        var output = Data()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let chunk = try pty.readStdout(handle)
            output.append(chunk)
            if !pty.isAlive(handle) {
                output.append(try pty.readStdout(handle))
                break
            }
            usleep(20_000)
        }
        let asString = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(asString.contains("writepath-ok"),
                      "expected 'writepath-ok' in shell output, got: \(asString.debugDescription)")
    }

    func testTerminateKillsPgid() throws {
        let pty = PtyTransport()
        // /bin/sh -c 'sleep 100' — gives us a long-running child
        // that won't exit on its own.
        let handle = try pty.start(
            sessionId: "T3",
            argv: ["/bin/sh", "-c", "sleep 100"],
            env: [:]
        )
        XCTAssertTrue(pty.isAlive(handle))
        pty.terminate(handle)
        // Should die within 1 s.
        var alive = true
        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            if !pty.isAlive(handle) { alive = false; break }
            usleep(20_000)
        }
        XCTAssertFalse(alive, "child must die within 1 s of SIGTERM")
        pty.close(handle)
    }

    func testCloseIsIdempotent() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "T4",
            argv: ["/bin/echo", "tmp"],
            env: [:]
        )
        XCTAssertFalse(handle.isClosed)
        pty.close(handle)
        XCTAssertTrue(handle.isClosed)
        // Second close → no crash.
        pty.close(handle)
        // Operations on closed handle return safe defaults.
        let chunk = try pty.readStdout(handle)
        XCTAssertEqual(chunk.count, 0)
        let written = try pty.writeStdin(handle, Data("x".utf8))
        XCTAssertEqual(written, 0)
    }

    // MARK: - v1.24 Phase 2a: winsize + ioLock + raw stdin

    /// Spawn with explicit cols/rows; verify the child sees them via
    /// `stty size` (which the kernel populates from the slave PTY's
    /// winsize set in openpty at spawn).
    func testInitialWinsizeReachesChild() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "WS1",
            argv: ["/bin/sh", "-c", "stty size; exit"],
            env: [:],
            cols: 132, rows: 50
        )
        defer { pty.close(handle) }
        var output = Data()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let chunk = try pty.readStdout(handle)
            if !chunk.isEmpty { output.append(chunk) }
            else if !pty.isAlive(handle) {
                output.append(try pty.readStdout(handle))
                break
            }
            usleep(20_000)
        }
        let s = String(data: output, encoding: .utf8) ?? ""
        // `stty size` prints "<rows> <cols>" (rows first per POSIX).
        XCTAssertTrue(s.contains("50 132"),
                      "expected '50 132' in stty size output, got: \(s.debugDescription)")
    }

    /// COLUMNS/LINES env hints should be present in the child's
    /// environment when not overridden by the caller.
    func testColumnsLinesEnvDefaultsInjected() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "WS2",
            argv: ["/bin/sh", "-c", "echo \"C=$COLUMNS L=$LINES\"; exit"],
            env: [:],
            cols: 100, rows: 30
        )
        defer { pty.close(handle) }
        var output = Data()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let chunk = try pty.readStdout(handle)
            if !chunk.isEmpty { output.append(chunk) }
            else if !pty.isAlive(handle) {
                output.append(try pty.readStdout(handle))
                break
            }
            usleep(20_000)
        }
        let s = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("C=100 L=30"),
                      "expected 'C=100 L=30' from child env, got: \(s.debugDescription)")
    }

    /// Caller-supplied env should win over the COLUMNS/LINES defaults.
    func testColumnsLinesEnvOverrideRespected() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "WS3",
            argv: ["/bin/sh", "-c", "echo \"C=$COLUMNS L=$LINES\"; exit"],
            env: ["COLUMNS": "200", "LINES": "60"],
            cols: 100, rows: 30
        )
        defer { pty.close(handle) }
        var output = Data()
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let chunk = try pty.readStdout(handle)
            if !chunk.isEmpty { output.append(chunk) }
            else if !pty.isAlive(handle) {
                output.append(try pty.readStdout(handle))
                break
            }
            usleep(20_000)
        }
        let s = String(data: output, encoding: .utf8) ?? ""
        XCTAssertTrue(s.contains("C=200 L=60"),
                      "expected caller env to win, got: \(s.debugDescription)")
    }

    /// setWinsize on a live handle updates the slave PTY without
    /// throwing. We can't easily observe SIGWINCH from a `sh -c`
    /// child, so we settle for: ioctl returns 0, no exception thrown.
    func testSetWinsizeOnLiveHandleSucceeds() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "WS4",
            argv: ["/bin/sh", "-c", "sleep 1; exit"],
            env: [:]
        )
        defer { pty.close(handle) }
        usleep(50_000)
        XCTAssertNoThrow(try pty.setWinsize(handle, cols: 120, rows: 40))
        XCTAssertNoThrow(try pty.setWinsize(handle, cols: 80, rows: 24))
    }

    /// setWinsize on a closed handle is a no-op (early return),
    /// not a throw — survives the inevitable resize-after-close
    /// race the UI will produce.
    func testSetWinsizeOnClosedHandleIsNoOp() throws {
        let pty = PtyTransport()
        let handle = try pty.start(
            sessionId: "WS5",
            argv: ["/bin/sh", "-c", "exit 0"],
            env: [:]
        )
        pty.close(handle)
        XCTAssertNoThrow(try pty.setWinsize(handle, cols: 100, rows: 30))
    }
}
