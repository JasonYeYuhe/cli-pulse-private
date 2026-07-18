import XCTest
@testable import CLIPulseCore
import Foundation
import Darwin

/// Base-path resolution for the local helper socket.
///
/// Context: the bundled DEVID helper moved its socket + auth token out of the
/// app-group container into `~/.clipulse`, because binding inside the container
/// made every launchd start a `kTCCServiceSystemPolicyAppData` consult — the
/// recurring "CLI Pulse would like to access data from other apps" prompt. The
/// `.pkg` Python helper still binds in the container, so the app must now pick
/// between two candidate bases.
///
/// The dangerous failure mode this pins: an AF_UNIX socket NODE outlives the
/// process that bound it. A SIGKILLed or `launchctl bootout`-ed helper leaves the
/// file behind. Selecting by "does the file exist" would therefore pin the app to
/// a dead socket and hide a perfectly healthy helper at the other base — which is
/// exactly the state the owner's Mac was in while the bundled helper was disabled.
final class HelperBaseResolutionTests: XCTestCase {

    private var tmp: URL!

    override func setUp() {
        super.setUp()
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("clipulse-base-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: tmp)
        super.tearDown()
    }

    /// Bind a real listening UDS and return its fd (caller closes).
    private func bindListener(at path: String) -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let c = (path as NSString).fileSystemRepresentation
        guard strlen(c) < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { _ = memcpy($0.baseAddress!, c, strlen(c) + 1) }
        let ok = withUnsafePointer(to: &addr) { p -> Bool in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok, Darwin.listen(fd, 4) == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    func testLiveListenerIsDetected() throws {
        let sock = tmp.appendingPathComponent("live.sock").path
        guard let fd = bindListener(at: sock) else { throw XCTSkip("could not bind UDS") }
        defer { Darwin.close(fd) }
        XCTAssertTrue(LocalSessionControlClient.socketHasLiveListener(atPath: sock),
                      "a bound+listening socket must be detected as live")
    }

    func testStaleSocketNodeIsNotMistakenForLive() throws {
        // THE REGRESSION THIS FILE EXISTS FOR. Bind, then close the listener while
        // leaving the node on disk — precisely what a killed/disabled helper does.
        let sock = tmp.appendingPathComponent("stale.sock").path
        if let fd = bindListener(at: sock) { Darwin.close(fd) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: sock),
                      "precondition: the socket NODE must still exist on disk")
        XCTAssertFalse(LocalSessionControlClient.socketHasLiveListener(atPath: sock),
                       "a leftover node with no listener must NOT count as live — "
                       + "an existence check here would pin the app to a dead helper")
    }

    func testMissingSocketIsNotLive() {
        XCTAssertFalse(LocalSessionControlClient.socketHasLiveListener(
            atPath: tmp.appendingPathComponent("nope.sock").path))
    }

    func testOverlongPathIsRefusedRatherThanTruncated() {
        // sun_path is ~104 bytes; silently truncating would connect to a DIFFERENT
        // path than requested, which is worse than failing.
        let tooLong = "/tmp/" + String(repeating: "x", count: 300) + ".sock"
        XCTAssertFalse(LocalSessionControlClient.socketHasLiveListener(atPath: tooLong))
    }

    func testRuntimeRootHonoursTheSharedOverrideEnvVar() {
        // The helper (HelperKit.RuntimeRoot) and the app must resolve the SAME
        // root or they rendezvous in different places. Both read
        // CLIPULSE_HELPER_ROOT; this pins the app half.
        let base = LocalSessionControlClient.runtimeRootBasePath()
        XCTAssertFalse(base.isEmpty)
        if ProcessInfo.processInfo.environment["CLIPULSE_HELPER_ROOT"] == nil {
            XCTAssertTrue(base.hasSuffix("/.clipulse"),
                          "default runtime root must be ~/.clipulse, got \(base)")
        }
    }

    func testRuntimeRootIsPreferredOverTheContainer() {
        let candidates = LocalSessionControlClient.candidateBasePaths()
        XCTAssertGreaterThanOrEqual(candidates.count, 1)
        XCTAssertEqual(candidates.first, LocalSessionControlClient.runtimeRootBasePath(),
                       "the bundled helper's private root must be probed FIRST")
        if candidates.count > 1 {
            XCTAssertTrue(candidates[1].contains("Group Containers"),
                          "the container (where the .pkg helper binds) must remain a fallback")
        }
    }

    func testResolvedBaseFallsBackWhenNothingIsListening() {
        // With no live helper anywhere, resolution must still yield a usable path
        // (the preferred root) rather than nil/empty.
        let base = LocalSessionControlClient.resolveBasePath()
        XCTAssertFalse(base.isEmpty)
        XCTAssertTrue(LocalSessionControlClient.candidateBasePaths().contains(base))
    }
}
