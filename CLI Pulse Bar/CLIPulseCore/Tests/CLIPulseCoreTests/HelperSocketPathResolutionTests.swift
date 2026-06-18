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

    func testClientResolvesSocketAndTokenUnderGroupContainer() {
        let diag = LocalSessionControlClient().diagnostics()
        XCTAssertTrue(
            diag.resolvedSocketPath.hasSuffix(
                "Group Containers/group.yyh.CLI-Pulse/clipulse-helper.sock"),
            diag.resolvedSocketPath)
        XCTAssertTrue(
            diag.resolvedTokenPath.hasSuffix(
                "Group Containers/group.yyh.CLI-Pulse/helper-auth-token"),
            diag.resolvedTokenPath)
        XCTAssertFalse(
            diag.resolvedSocketPath.contains("Library/Containers/yyh.CLI-Pulse"),
            "socket must not be under the private sandbox container: \(diag.resolvedSocketPath)")
    }
}
#endif
