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

    // MARK: - TerminalSessionAdapter.deliver with nil view

    /// `deliver(event:to:nil)` is the safety net for the
    /// "subscription fired after view was torn down" race.
    /// Pure check — no WKWebView instantiation (XCTest hosts on
    /// macOS abort on WKWebView creation outside an AppKit
    /// event loop).
    @MainActor
    func test_deliverWithNilView_isNoOp() {
        let event = LocalSessionEvent.outputDelta(
            sessionId: "S",
            payload: "x",
            ts: 0)
        TerminalSessionAdapter.deliver(event: event, to: nil)
        // Should not crash.
    }
}
#endif
