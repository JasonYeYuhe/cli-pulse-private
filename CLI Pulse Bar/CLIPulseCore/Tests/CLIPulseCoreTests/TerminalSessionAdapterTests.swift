#if os(macOS)
import XCTest
@testable import CLIPulseCore
import Foundation

/// Phase 3 slice 3 — pure tests for the LocalSessionControlClient
/// RPC wrappers + MASSandboxGate detection + TerminalSessionAdapter
/// state machine. The actual UDS round-trip + helper spawn is
/// covered separately by HelperSwift integration tests (PR #78/79/80
/// landed those).
final class TerminalSessionAdapterTests: XCTestCase {

    // MARK: - MASSandboxGate

    func test_canHostInAppTerminal_isInverseOfIsSandboxed() {
        XCTAssertEqual(MASSandboxGate.canHostInAppTerminal,
                       !MASSandboxGate.isSandboxed)
    }

    /// XCTest hosts are unsandboxed on macOS — the test process
    /// runs from DerivedData, not from /Library/Containers/.
    /// Confirm the probe returns the expected polarity in this
    /// environment so the inversion above is meaningful (not a
    /// vacuously-true tautology).
    func test_testHostIsNotSandboxed() {
        XCTAssertFalse(MASSandboxGate.isSandboxed,
                       "test host should run unsandboxed; got home=\(NSHomeDirectory())")
    }

    // MARK: - LocalSessionControlClient.resize parameter validation

    func test_resize_rejectsZeroCols() async {
        let client = LocalSessionControlClient()
        do {
            try await client.resize(sessionId: "x", cols: 0, rows: 24)
            XCTFail("expected throw")
        } catch let SessionControlError.invalidResponse(msg) {
            XCTAssertTrue(msg.contains("cols/rows"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func test_resize_rejectsNegative() async {
        let client = LocalSessionControlClient()
        do {
            try await client.resize(sessionId: "x", cols: 80, rows: -1)
            XCTFail("expected throw")
        } catch let SessionControlError.invalidResponse(msg) {
            XCTAssertTrue(msg.contains("cols/rows"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    func test_resize_rejectsOverLimit() async {
        let client = LocalSessionControlClient()
        do {
            try await client.resize(sessionId: "x", cols: 2000, rows: 24)
            XCTFail("expected throw")
        } catch let SessionControlError.invalidResponse(msg) {
            XCTAssertTrue(msg.contains("cols/rows"))
        } catch {
            XCTFail("unexpected: \(error)")
        }
    }

    // MARK: - TerminalSessionAdapter initial state

    @MainActor
    func test_adapterStartsIdle() async {
        let adapter = TerminalSessionAdapter()
        XCTAssertEqual(adapter.state, .idle)
        XCTAssertEqual(adapter.provider, "claude")
    }

    @MainActor
    func test_adapterAcceptsCustomProvider() async {
        let adapter = TerminalSessionAdapter(provider: "codex")
        XCTAssertEqual(adapter.provider, "codex")
    }

    // MARK: - v-next P1-1: working-directory wiring

    @MainActor
    func test_adapterDefaultsCwdToNil() async {
        // No cwd ⇒ helper inherits its own dir (prior behaviour).
        XCTAssertNil(TerminalSessionAdapter().cwd)
    }

    @MainActor
    func test_adapterStoresChosenCwd() async {
        let adapter = TerminalSessionAdapter(provider: "claude", cwd: "/tmp/project")
        XCTAssertEqual(adapter.cwd, "/tmp/project")
    }

    // MARK: - W3: attachExisting reentrancy (supersession) logic

    /// The reattach must paint its snapshot ONLY while `state` still points at
    /// the same session — otherwise a rapid re-attach to a different session
    /// would flush the old snapshot into the new buffer (the bug the dead
    /// `Task.isCancelled` check failed to prevent).
    func test_reattachSuperseded_sameRunningSession_notSuperseded() {
        XCTAssertFalse(TerminalSessionAdapter.reattachSuperseded(
            state: .running(sessionId: "A"), targetSessionId: "A"))
    }

    func test_reattachSuperseded_differentRunningSession_isSuperseded() {
        // A newer attach to B replaced state while A's snapshot was in flight.
        XCTAssertTrue(TerminalSessionAdapter.reattachSuperseded(
            state: .running(sessionId: "B"), targetSessionId: "A"))
    }

    func test_reattachSuperseded_nonRunningStates_areSuperseded() {
        for state: TerminalSessionAdapter.State in [.idle, .starting, .stopping, .stopped, .failed(reason: "x")] {
            XCTAssertTrue(TerminalSessionAdapter.reattachSuperseded(
                state: state, targetSessionId: "A"),
                "state \(state) must count as superseded (don't paint a stale snapshot)")
        }
    }

    // MARK: - TerminalSessionAdapter.deliverLive with nil view

    /// `deliverLive` is the safety net for the "subscription fired after the
    /// view was torn down" race. With a nil view it must no-op for every event
    /// kind (output and non-output). Pure check — no WKWebView instantiation
    /// (XCTest hosts on macOS abort on WKWebView creation outside an AppKit
    /// event loop).
    @MainActor
    func test_deliverLiveWithNilView_isNoOp() {
        let adapter = TerminalSessionAdapter()  // view is nil, no reattach buffer
        adapter.deliverLive(.outputRaw(sessionId: "S", payload: "\u{1b}[31mhi", ts: 0))
        adapter.deliverLive(.outputDelta(sessionId: "S", payload: "x", ts: 0))
        adapter.deliverLive(.heartbeat(ts: 0))
        adapter.deliverLive(.sessionStatus(sessionId: "S", status: "running"))
        // Should not crash.
    }
}
#endif
