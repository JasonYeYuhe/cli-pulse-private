#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Helper-detection path resolution — guards the "helper running but app
/// reports not detected" bug: when `containerURL(forSecurityApplicationGroup
/// Identifier:)` is nil, the app must fall back to the REAL-home group
/// container the (unsandboxed) helper binds in, NOT `NSHomeDirectory()` (the
/// app's PRIVATE sandbox container, a path the helper never uses).
final class HelperSocketPathResolutionTests: XCTestCase {

    func testGroupContainerBaseIsTheSharedGroupContainerNotSandboxPrivate() {
        let base = LocalSessionControlClient.groupContainerBasePath()
        XCTAssertTrue(
            base.hasSuffix("Library/Group Containers/group.yyh.CLI-Pulse"),
            "base must resolve to the shared group container, got: \(base)")
        XCTAssertFalse(
            base.contains("Library/Containers/yyh.CLI-Pulse"),
            "base must NOT be the app's private sandbox container, got: \(base)")
    }

    /// The contract this test pins CHANGED: the bundled helper's rendezvous moved
    /// out of the app-group container to `~/.clipulse`, because binding inside the
    /// container made every launchd start a TCC `SystemPolicyAppData` consult (the
    /// "CLI Pulse would like to access data from other apps" prompt). The `.pkg`
    /// Python helper still binds the container, so the client now picks between
    /// the two by probing for a LIVE listener.
    ///
    /// The old assertion ("must resolve under Group Containers") passes today ONLY
    /// by accident on a machine where the `.pkg` helper happens to be running — on
    /// a clean CI runner with no helper listening it resolves to `~/.clipulse` and
    /// fails (review: codex). So assert the real invariants instead of one
    /// hard-coded base.
    func testClientResolvesSocketAndTokenUnderTheSameLiveBase() {
        let diag = LocalSessionControlClient().diagnostics()
        let sock = diag.resolvedSocketPath
        let token = diag.resolvedTokenPath

        // 1. Both must come from the SAME base — each helper rotates its own token
        //    beside its own socket, so a split base authenticates against the
        //    wrong helper's token.
        XCTAssertEqual(
            (sock as NSString).deletingLastPathComponent,
            (token as NSString).deletingLastPathComponent,
            "socket and token must resolve under one base (\(sock) vs \(token))")

        // 2. That base must be one of the two legitimate candidates.
        let base = (sock as NSString).deletingLastPathComponent
        XCTAssertTrue(
            LocalSessionControlClient.candidateBasePaths().contains(base),
            "resolved base \(base) is not a known candidate")

        // 3. Filenames unchanged.
        XCTAssertTrue(sock.hasSuffix("/clipulse-helper.sock"), sock)
        XCTAssertTrue(token.hasSuffix("/helper-auth-token"), token)

        // 4. The original point of this test, still true and still important:
        //    never the app's PRIVATE sandbox container, which the helper never
        //    writes to — that produced permanent ENOENT and "helper running but
        //    app reports not detected".
        XCTAssertFalse(
            sock.contains("Library/Containers/yyh.CLI-Pulse"),
            "socket must not be under the private sandbox container: \(sock)")
    }
}
#endif
