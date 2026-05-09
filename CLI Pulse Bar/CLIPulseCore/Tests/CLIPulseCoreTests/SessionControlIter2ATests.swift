import XCTest
@testable import CLIPulseCore

/// Phase 3 unified PR (replaces #15) — iter 2A coverage on top of
/// the iter-1 baseline in `SessionControlClientTests`.
///
/// What this file pins:
///   * New typed errors: `sessionNotFound`, `notControllable`.
///   * Wire-code mapping for `session_not_found` and
///     `not_controllable` strings emitted by the helper.
///   * `SessionControlCapabilities.iter2aLocal` matches the helper's
///     advertised `{send_input: true, subscribe_events: false,
///     approvals: false}`.
///   * `SessionControlSummary` carries `controllable` + `source`
///     and round-trips through Equatable.
///   * Default `sendInput` implementation throws `notImplemented` so
///     transports that don't support stdin (the remote / Supabase
///     path before its explicit override) get the right typed error.
///   * Stub client end-to-end for `sendInput` happy + error paths.
final class SessionControlIter2ATests: XCTestCase {

    // MARK: - Wire-code mapping for the new error codes

    func testWireCodeMapping_sessionNotFound() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "session_not_found", message: "x"),
            .sessionNotFound
        )
    }

    func testWireCodeMapping_notControllable() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "not_controllable", message: "x"),
            .notControllable
        )
    }

    // MARK: - Capability invariants

    func testIter2aLocalCapabilities_advertiseSendInputOnly() {
        let caps = SessionControlCapabilities.iter2aLocal
        XCTAssertTrue(caps.sendInput,
            "send_input must be advertised so the macOS UI enables the prompt")
        XCTAssertFalse(caps.subscribeEvents,
            "subscribe_events stays deferred to iter 2B")
        XCTAssertFalse(caps.approvals,
            "approvals stays deferred to iter 2B")
    }

    func testIter1AndIter2aLocalCapabilities_differOnSendInput() {
        XCTAssertNotEqual(
            SessionControlCapabilities.iter1Local,
            SessionControlCapabilities.iter2aLocal
        )
        XCTAssertEqual(
            SessionControlCapabilities.iter1Local.sendInput, false
        )
        XCTAssertEqual(
            SessionControlCapabilities.iter2aLocal.sendInput, true
        )
    }

    // MARK: - SessionControlSummary controllability + source

    func testSummary_managedDefaultsToControllableTrue() {
        let row = SessionControlSummary(
            id: "x", provider: "Claude", clientLabel: "X",
            status: "running"
        )
        XCTAssertTrue(row.controllable)
        XCTAssertEqual(row.source, .managed)
    }

    func testSummary_detectedSourceForcedNonControllable() {
        let row = SessionControlSummary(
            id: "x", provider: "Claude", clientLabel: "X",
            status: "running",
            controllable: false, source: .detected
        )
        XCTAssertFalse(row.controllable)
        XCTAssertEqual(row.source, .detected)
    }

    // MARK: - Default sendInput throws notImplemented

    /// Minimal client that conforms to the protocol WITHOUT
    /// overriding `sendInput`. The default extension implementation
    /// must throw `notImplemented` so a transport that can't accept
    /// stdin doesn't silently no-op.
    private struct InputSilentClient: SessionControlClient {
        func hello() async throws -> SessionControlHello {
            .init(protocolVersion: 0, supportedMethods: [], capabilities: .iter1Local)
        }
        func startManagedSession(
            provider: String,
            clientLabel: String?, cwdBasename: String?, cwdHmac: String?
        ) async throws -> SessionControlStartResult { .init(sessionId: "x") }
        func listSessions() async throws -> [SessionControlSummary] { [] }
        func stopSession(sessionId: String) async throws {}
    }

    func testDefaultSendInputThrowsNotImplemented() async {
        let client = InputSilentClient()
        do {
            try await client.sendInput(sessionId: "x", payload: "y")
            XCTFail("expected throw")
        } catch let err as SessionControlError {
            XCTAssertEqual(err, .notImplemented)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Stub client send_input round-trip + typed errors

    /// Override-friendly stub that records send_input calls and can
    /// be primed to throw a specific typed error.
    private final class StubInputClient: SessionControlClient {
        var sendCalls: [(String, String)] = []
        var sendError: SessionControlError?
        let summaries: [SessionControlSummary]

        init(summaries: [SessionControlSummary] = [], sendError: SessionControlError? = nil) {
            self.summaries = summaries
            self.sendError = sendError
        }

        func hello() async throws -> SessionControlHello {
            .init(protocolVersion: 1, supportedMethods: ["send_input"], capabilities: .iter2aLocal)
        }
        func startManagedSession(
            provider: String,
            clientLabel: String?, cwdBasename: String?, cwdHmac: String?
        ) async throws -> SessionControlStartResult { .init(sessionId: "x") }
        func listSessions() async throws -> [SessionControlSummary] { summaries }
        func stopSession(sessionId: String) async throws {}
        func sendInput(sessionId: String, payload: String) async throws {
            sendCalls.append((sessionId, payload))
            if let sendError { throw sendError }
        }
    }

    func testStubInputClient_sendInputRecordsExactPayload() async throws {
        let stub = StubInputClient()
        try await stub.sendInput(sessionId: "S-1", payload: "hello\n")
        XCTAssertEqual(stub.sendCalls.count, 1)
        XCTAssertEqual(stub.sendCalls[0].0, "S-1")
        XCTAssertEqual(stub.sendCalls[0].1, "hello\n")
    }

    func testStubInputClient_sendInputPropagatesSessionNotFound() async {
        let stub = StubInputClient(sendError: .sessionNotFound)
        do {
            try await stub.sendInput(sessionId: "missing", payload: "hi")
            XCTFail("expected throw")
        } catch let err as SessionControlError {
            XCTAssertEqual(err, .sessionNotFound)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStubInputClient_sendInputPropagatesNotControllable() async {
        let stub = StubInputClient(sendError: .notControllable)
        do {
            try await stub.sendInput(sessionId: "proc-1", payload: "hi")
            XCTFail("expected throw")
        } catch let err as SessionControlError {
            XCTAssertEqual(err, .notControllable)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testStubInputClient_listSessionsPreservesControllabilityAndSource() async throws {
        let stub = StubInputClient(summaries: [
            .init(id: "M-1", provider: "Claude", clientLabel: "Mac",
                  status: "running", controllable: true, source: .managed),
            .init(id: "proc-7", provider: "Claude", clientLabel: "claude",
                  status: "running", controllable: false, source: .detected),
        ])
        let rows = try await stub.listSessions()
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].controllable)
        XCTAssertEqual(rows[0].source, .managed)
        XCTAssertFalse(rows[1].controllable)
        XCTAssertEqual(rows[1].source, .detected)
    }
}

#if os(macOS)
/// macOS-only tests for the local UDS client's new types.
///
/// Note: wire-level "missing socket → helperNotRunning" and
/// "missing token → unauthenticated" coverage already lives in
/// `LocalSessionControlClientMacTests` (the iter-1 file). Adding
/// duplicates here caused a flake in full-suite parallel runs (the
/// duplicate connection attempts against `/tmp/cli-pulse-iter*-no-*`
/// paths starved each other on the shared NWConnection queue).
/// Wire-level end-to-end for the NEW iter-2A RPCs is covered by the
/// helper-side pytest suite (`test_local_session_server.py`) AND
/// `/tmp/cli-pulse-iter2a-smoke.py` against a live daemon — both
/// passed in this branch's validation run.
final class LocalSessionControlClientIter2ATests: XCTestCase {

    /// LocalControlStatus is Sendable + Equatable — round-trip the
    /// shape so a future field addition lands as a deliberate diff
    /// here rather than silent breakage.
    func testLocalControlStatusEquatable() {
        let a = LocalControlStatus(localControlEnabled: true, protocolVersion: 1)
        let b = LocalControlStatus(localControlEnabled: true, protocolVersion: 1)
        let c = LocalControlStatus(localControlEnabled: false, protocolVersion: 1)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    /// Construction round-trips the explicit defaults so a future
    /// field-name typo lands here rather than as a silent decode
    /// failure on the live daemon.
    func testLocalControlStatusFieldNames() {
        let s = LocalControlStatus(localControlEnabled: true, protocolVersion: 7)
        XCTAssertTrue(s.localControlEnabled)
        XCTAssertEqual(s.protocolVersion, 7)
    }
}
#endif
