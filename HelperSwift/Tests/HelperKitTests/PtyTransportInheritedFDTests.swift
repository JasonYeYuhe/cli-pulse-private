import XCTest
@testable import HelperKit

/// Validates the leak-safe fd injection PtyTransport gained for the Claude
/// subscription OAuth token: the child must be able to read the payload from the
/// inherited fd named by the env var — proving posix_spawn inherits the pipe
/// read end and the env carries its number. This is the plumbing the real
/// `CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR` injection rides on.
final class PtyTransportInheritedFDTests: XCTestCase {

    private func readUntil(
        _ t: PtyTransport, _ h: PtyTransport.Handle,
        contains needle: String, timeout: TimeInterval
    ) -> String {
        var acc = ""
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let chunk = try? t.readStdout(h), !chunk.isEmpty {
                acc += String(decoding: chunk, as: UTF8.self)
                if acc.contains(needle) { return acc }
            } else {
                usleep(20_000)
            }
        }
        return acc
    }

    func test_childReadsSecretFromInheritedFD() throws {
        let secret = "SECRET-\(UUID().uuidString)"
        let t = PtyTransport()
        // The child `cat`s the inherited fd (number is in $CLI_PULSE_TEST_FD) to
        // stdout → it surfaces on the PTY master, which we read back.
        let handle = try t.start(
            sessionId: "fd-inherit-test",
            argv: ["/bin/sh", "-c", "eval \"cat <&$CLI_PULSE_TEST_FD\""],
            inheritedFD: ("CLI_PULSE_TEST_FD", Data(secret.utf8))
        )
        defer { t.close(handle) }
        let out = readUntil(t, handle, contains: secret, timeout: 3)
        XCTAssertTrue(out.contains(secret),
                      "child should read the injected secret from the inherited fd; got: \(out.debugDescription)")
    }

    func test_noInheritedFD_doesNotSetEnvVar() throws {
        // Without inheritedFD, the child env must NOT contain the FD var.
        let t = PtyTransport()
        let handle = try t.start(
            sessionId: "fd-absent-test",
            argv: ["/bin/sh", "-c", "echo \"FD=[${CLI_PULSE_TEST_FD:-unset}]\""]
        )
        defer { t.close(handle) }
        let out = readUntil(t, handle, contains: "FD=[", timeout: 3)
        XCTAssertTrue(out.contains("FD=[unset]"),
                      "no inheritedFD → env var must be absent; got: \(out.debugDescription)")
    }
}
