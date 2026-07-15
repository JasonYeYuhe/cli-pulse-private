import XCTest
@testable import HelperKit
import Foundation

/// M4.4a PR-B: TmuxTransport. Swift twin of `helper/test_tmux_transport.py`.
/// Pure logic (unescape / sanitize / foreign-handle) always runs; the real-tmux
/// round-trip is skipped when no tmux binary is on PATH.
final class TmuxTransportTests: XCTestCase {

    // MARK: - control-mode unescape (pure, byte-exact)

    private func unesc(_ s: String) -> [UInt8] {
        [UInt8](TmuxTransport.unescapeControlOutput(Data(s.utf8)))
    }

    func testUnescapeBackslashDouble() {
        // `\\` → single backslash.
        XCTAssertEqual(unesc(#"a\\b"#), Array("a\\b".utf8))
    }

    func testUnescapeOctalTriplet() {
        // `\015` → 0x0D (CR); `\012` → 0x0A (LF).
        XCTAssertEqual(TmuxTransport.unescapeControlOutput(Data(#"\015\012"#.utf8)),
                       Data([0x0D, 0x0A]))
        // `\033` → ESC 0x1B (common in ANSI sequences).
        XCTAssertEqual(TmuxTransport.unescapeControlOutput(Data(#"\033[0m"#.utf8)),
                       Data([0x1B]) + Data("[0m".utf8))
    }

    func testUnescapePassesPrintableAndUTF8Raw() {
        XCTAssertEqual(TmuxTransport.unescapeControlOutput(Data("hello 世界".utf8)),
                       Data("hello 世界".utf8))
    }

    func testUnescapeLoneTrailingBackslashVerbatim() {
        // A lone/invalid trailing backslash is emitted verbatim (defensive).
        XCTAssertEqual(unesc(#"x\"#), Array("x\\".utf8))
        // `\9` isn't an octal triplet → both bytes verbatim.
        XCTAssertEqual(unesc(#"\9"#), Array("\\9".utf8))
    }

    func testUnescapeMaskHighOctal() {
        // `\777` = 0o777 = 511, which OVERFLOWS a byte; the `& 0xFF` mask must
        // truncate 511 → 255 (0xFF). (`\377` = 255 wouldn't exercise the mask.)
        XCTAssertEqual(TmuxTransport.unescapeControlOutput(Data(#"\777"#.utf8)),
                       Data([0xFF]))
        // And a plain in-range triplet round-trips exactly.
        XCTAssertEqual(TmuxTransport.unescapeControlOutput(Data(#"\101"#.utf8)),
                       Data([0x41]))   // 0o101 = 'A'
    }

    func testStartAppliesEnvRemove() throws {
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let sock = NSTemporaryDirectory() + "clipulse-tmuxtest-\(UUID().uuidString.prefix(8)).sock"
        let transport = TmuxTransport(socketPath: sock, tmuxBin: bin)
        // Seed the env, then blank it via envRemove; the session's process must
        // NOT see the value. The child emits only AFTER reading a line, so the
        // output lands post-attach (tmux control mode doesn't replay pre-attach
        // pane content — a start-time printf would be missed).
        setenv("CLIPULSE_TMUX_ENVTEST", "leaked", 1)
        defer { unsetenv("CLIPULSE_TMUX_ENVTEST") }
        let handle = try transport.start(
            sessionId: "envrm",
            argv: ["/bin/sh", "-c", "IFS= read -r _; printf 'V=[%s]\\n' \"$CLIPULSE_TMUX_ENVTEST\"; exec cat"],
            envRemove: ["CLIPULSE_TMUX_ENVTEST"])
        defer { transport.close(handle); try? FileManager.default.removeItem(atPath: sock) }
        // Give the control client a moment to attach, then trigger the read.
        Thread.sleep(forTimeInterval: 0.2)
        _ = try transport.writeStdin(handle, Data("go\n".utf8))
        var got = Data()
        for _ in 0..<60 {
            got.append(try transport.readStdout(handle, maxBytes: 4096))
            if String(data: got, encoding: .utf8)?.contains("V=[") == true { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        let text = String(data: got, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("V=[]"), "envRemove should blank the var; got \(text)")
        XCTAssertFalse(text.contains("leaked"), text)
    }

    // MARK: - session-name sanitization (review bug #4)

    func testSanitizeDotAndColon() {
        XCTAssertEqual(TmuxTransport.sanitize("a.b:c"), "a_b_c")
        XCTAssertEqual(TmuxTransport.sanitize("plain"), "plain")
    }

    // MARK: - foreign-handle guard

    func testForeignHandleRejected() throws {
        final class Foreign: SessionHandle, @unchecked Sendable {
            let sessionId = "x"; let pid: pid_t = 0; let isClosed = false
        }
        let t = TmuxTransport(socketPath: "/tmp/nonexistent.sock", tmuxBin: "/opt/homebrew/bin/tmux")
        XCTAssertThrowsError(try t.writeStdin(Foreign(), Data([0x41]))) { err in
            XCTAssertEqual(err as? SessionTransportError, .foreignHandle)
        }
        XCTAssertFalse(t.isAlive(Foreign()))
    }

    // MARK: - real tmux round-trip (skipped when tmux absent)

    private var tmuxBin: String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let c = "\(dir)/tmux"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
        return FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/tmux")
            ? "/opt/homebrew/bin/tmux" : nil
    }

    func testRealTmuxRoundTripAndAttachDoesNotKill() throws {
        guard let bin = tmuxBin else {
            throw XCTSkip("tmux not available on this host")
        }
        let sock = NSTemporaryDirectory() + "clipulse-tmuxtest-\(UUID().uuidString.prefix(8)).sock"
        let transport = TmuxTransport(socketPath: sock, tmuxBin: bin)
        // Start a session running `cat` — it echoes stdin back to stdout, so we
        // can prove the input→output round-trip through control mode.
        let handle = try transport.start(sessionId: "sess.one:1", argv: ["cat"])
        defer {
            // owns_session handle: close kills it + the server.
            transport.close(handle)
            try? FileManager.default.removeItem(atPath: sock)
        }
        XCTAssertTrue(transport.isAlive(handle))
        // Inject "ping\n"; cat echoes it. Poll readStdout until it shows up.
        _ = try transport.writeStdin(handle, Data("ping\n".utf8))
        var got = Data()
        for _ in 0..<50 {   // up to ~2.5s
            got.append(try transport.readStdout(handle, maxBytes: 4096))
            if String(data: got, encoding: .utf8)?.contains("ping") == true { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertTrue(String(data: got, encoding: .utf8)?.contains("ping") == true,
                      "cat should echo injected input back through control mode; got \(got.count)B")

        // ATTACH (non-owning) to the SAME session, then close the attach handle
        // — it must NOT kill the real session (owns_session=false).
        let attach = try transport.attachExisting(sessionId: "watcher", tmuxSessionName: "sess_one_1")
        XCTAssertTrue(transport.isAlive(attach))
        transport.close(attach)   // non-owning close
        XCTAssertTrue(transport.isAlive(handle), "detaching a non-owning attach must leave the session ALIVE")
    }

    func testTerminateThenCloseKillsOnlyOnce() throws {
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let sock = NSTemporaryDirectory() + "clipulse-tmuxtest-\(UUID().uuidString.prefix(8)).sock"
        let transport = TmuxTransport(socketPath: sock, tmuxBin: bin)
        let handle = try transport.start(sessionId: "killonce", argv: ["cat"])
        defer { try? FileManager.default.removeItem(atPath: sock) }
        XCTAssertTrue(transport.isAlive(handle))
        // terminate() kills the owned session and records killIssued…
        transport.terminate(handle)
        XCTAssertFalse(transport.isAlive(handle))
        // …so a subsequent close() must NOT issue a second kill-session (which,
        // if the name were reused, would kill a DIFFERENT session). We can't
        // observe the absence of a kill directly, but close() must not crash or
        // hang and the handle ends up closed.
        transport.close(handle)
        XCTAssertTrue(handle.isClosed)
    }

    func testAttachExistingMissingSessionThrows() throws {
        guard let bin = tmuxBin else { throw XCTSkip("tmux not available") }
        let sock = NSTemporaryDirectory() + "clipulse-tmuxtest-\(UUID().uuidString.prefix(8)).sock"
        let transport = TmuxTransport(socketPath: sock, tmuxBin: bin)
        XCTAssertThrowsError(try transport.attachExisting(sessionId: "w", tmuxSessionName: "nope")) { err in
            guard case TmuxTransport.TmuxTransportError.sessionNotFound = err else {
                return XCTFail("expected sessionNotFound, got \(err)")
            }
        }
    }
}
