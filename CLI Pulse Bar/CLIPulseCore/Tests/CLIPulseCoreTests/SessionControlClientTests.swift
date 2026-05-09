import XCTest
@testable import CLIPulseCore

/// Phase 3 Iter 1 — protocol-level tests for SessionControlClient.
///
/// These cover the wire-code → typed-error mapping AND the parity
/// surface between RemoteSessionControlClient (existing Supabase
/// path) and a fake LocalSessionControlClient stand-in. We don't
/// stand up a real UDS socket here — that lives in the helper-side
/// pytest suite (test_local_session_server.py end-to-end test). The
/// XCTest job here is to assert the Swift side honours its half of
/// the contract.
final class SessionControlClientTests: XCTestCase {

    // MARK: - Wire-code → typed-error mapping

    func testWireCodeMapping_unauthenticated() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "unauthenticated", message: "x"),
            .unauthenticated
        )
    }

    func testWireCodeMapping_versionMismatch() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "version_mismatch", message: "x"),
            .versionMismatch
        )
    }

    func testWireCodeMapping_notImplemented() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "not_implemented", message: "x"),
            .notImplemented
        )
        // unknown_method is treated as not_implemented per the spec —
        // the helper rejected a method the iter-1 caps say it speaks,
        // which is functionally equivalent for the UI.
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "unknown_method", message: "x"),
            .notImplemented
        )
    }

    func testWireCodeMapping_localControlOff() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "local_control_off", message: "x"),
            .localControlOff
        )
    }

    // MARK: - v1.15 spawn-failed error wiring (Codex review round 2)

    func testSpawnFailed_descriptionIncludesDetail() {
        // Pre-fix LocalSessionControlClient ignored `ok: false` from
        // the helper's start_session reply, optimistically appending a
        // running session that didn't exist. The fix added a
        // `.spawnFailed(detail:)` case that the client throws when
        // `result["ok"] == false`. Pin the description shape so any
        // future enum change has to update the tests intentionally —
        // the macOS / iOS UI uses `String(describing:)` to render the
        // helper's reason inline.
        let err = SessionControlError.spawnFailed(
            detail: "helper reported start_session ok=false (provider codex)"
        )
        XCTAssertTrue(
            String(describing: err).contains("spawn failed"),
            "spawnFailed description must lead with 'spawn failed'; got \(err)"
        )
        XCTAssertTrue(
            String(describing: err).contains("provider codex"),
            "spawnFailed detail must round-trip into description"
        )
    }

    func testSpawnFailed_isNotEqualToOtherCases() {
        // Equatable conformance is auto-synthesized; pin that the new
        // case is distinct from the existing `notImplemented` (the
        // earlier failure mode for "helper rejected this provider")
        // so a test that asserts notImplemented can't accidentally
        // pass for an actual spawn failure.
        XCTAssertNotEqual(
            SessionControlError.spawnFailed(detail: "x"),
            SessionControlError.notImplemented
        )
        XCTAssertEqual(
            SessionControlError.spawnFailed(detail: "x"),
            SessionControlError.spawnFailed(detail: "x")
        )
        XCTAssertNotEqual(
            SessionControlError.spawnFailed(detail: "x"),
            SessionControlError.spawnFailed(detail: "y")
        )
    }

    // MARK: - v1.15 provider availability shape

    func testHello_providerAvailability_defaultsEmpty() {
        // Existing call sites used the 3-arg init before v1.15. The
        // new providerAvailability field MUST default to an empty
        // array so a stale caller (e.g. test stubs that haven't been
        // updated) keeps compiling without a forced relink.
        let hello = SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello"],
            capabilities: .iter1Local
        )
        XCTAssertEqual(hello.providerAvailability, [])
    }

    func testHello_providerAvailability_roundTrip() {
        let hello = SessionControlHello(
            protocolVersion: 1,
            supportedMethods: ["hello", "start_session"],
            capabilities: .iter2bLocal,
            providerAvailability: ["claude", "codex"]
        )
        XCTAssertEqual(hello.providerAvailability, ["claude", "codex"])
        // Equatable conformance must include providerAvailability —
        // otherwise picker UI tests that compare against expected
        // shapes will silently pass on stale data.
        XCTAssertNotEqual(
            hello,
            SessionControlHello(
                protocolVersion: 1,
                supportedMethods: ["hello", "start_session"],
                capabilities: .iter2bLocal,
                providerAvailability: ["claude"]
            )
        )
    }

    func testWireCodeMapping_internalAndBadRequest() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "internal", message: "boom"),
            .internalError("boom")
        )
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "bad_request", message: "x"),
            .invalidResponse("x")
        )
    }

    func testWireCodeMapping_frameTooLargeMapsToInvalidResponse() {
        // A peer that sends an oversize frame is malformed at the
        // transport layer. We surface it as invalidResponse rather
        // than disconnected so the UI hint is "the helper sent
        // something malformed" rather than "your connection broke."
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "frame_too_large", message: "1234"),
            .invalidResponse("1234")
        )
    }

    func testWireCodeMapping_frameTruncatedMapsToDisconnected() {
        // Truncated == peer hung up mid-frame. Disconnect is the right
        // user-facing story.
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "frame_truncated", message: "x"),
            .disconnected
        )
    }

    func testWireCodeMapping_unknownCodeFallsBackToInternalError() {
        let err = SessionControlErrorMapping.error(forWireCode: "totally-new", message: "msg")
        guard case .internalError(let detail) = err else {
            XCTFail("expected .internalError, got \(err)"); return
        }
        XCTAssertTrue(detail.contains("totally-new"))
        XCTAssertTrue(detail.contains("msg"))
    }

    // MARK: - Capability defaults reflect iter-1 invariants

    func testIter1LocalCapabilities_areAllOff() {
        let caps = SessionControlCapabilities.iter1Local
        XCTAssertFalse(caps.sendInput)
        XCTAssertFalse(caps.subscribeEvents)
        XCTAssertFalse(caps.approvals)
    }

    func testSupabaseFullCapabilities_matchExistingProductSurface() {
        let caps = SessionControlCapabilities.supabaseFull
        XCTAssertTrue(caps.sendInput)
        XCTAssertTrue(caps.subscribeEvents)
        XCTAssertTrue(caps.approvals)
    }

    // MARK: - Parity through a fake conformance

    /// In-memory client that conforms to SessionControlClient. Used
    /// to prove a single shape of caller code can drive both transports
    /// without branching, AND to assert each method is reachable.
    private final class StubClient: SessionControlClient {
        var helloCallCount = 0
        // v1.15: provider is part of the captured tuple now.
        var startCalls: [(String, String?, String?, String?)] = []
        var listCallCount = 0
        var stopCalls: [String] = []

        let helloResult: SessionControlHello
        let startResult: SessionControlStartResult
        let listResult: [SessionControlSummary]
        let stopError: SessionControlError?

        init(
            helloResult: SessionControlHello = .init(
                protocolVersion: 1,
                supportedMethods: ["hello", "start_session"],
                capabilities: .iter1Local
            ),
            startResult: SessionControlStartResult = .init(sessionId: "abc"),
            listResult: [SessionControlSummary] = [],
            stopError: SessionControlError? = nil
        ) {
            self.helloResult = helloResult
            self.startResult = startResult
            self.listResult = listResult
            self.stopError = stopError
        }

        func hello() async throws -> SessionControlHello {
            helloCallCount += 1
            return helloResult
        }

        func startManagedSession(
            provider: String,
            clientLabel: String?, cwdBasename: String?, cwdHmac: String?
        ) async throws -> SessionControlStartResult {
            startCalls.append((provider, clientLabel, cwdBasename, cwdHmac))
            return startResult
        }

        func listSessions() async throws -> [SessionControlSummary] {
            listCallCount += 1
            return listResult
        }

        func stopSession(sessionId: String) async throws {
            stopCalls.append(sessionId)
            if let stopError { throw stopError }
        }
    }

    func testStubClient_helloRoundTripsExpectedShape() async throws {
        let stub = StubClient()
        let hello = try await stub.hello()
        XCTAssertEqual(hello.protocolVersion, 1)
        XCTAssertTrue(hello.supportedMethods.contains("start_session"))
        XCTAssertEqual(hello.capabilities, .iter1Local)
    }

    func testStubClient_startListStopParity() async throws {
        let stub = StubClient(
            startResult: .init(sessionId: "S-1", commandId: nil),
            listResult: [
                .init(id: "S-1", provider: "claude", clientLabel: "Mac", status: "running"),
            ]
        )
        let start = try await stub.startClaudeSession(
            clientLabel: "Mac", cwdBasename: nil, cwdHmac: nil
        )
        XCTAssertEqual(start.sessionId, "S-1")
        XCTAssertNil(start.commandId)

        let list = try await stub.listSessions()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].id, "S-1")

        try await stub.stopSession(sessionId: "S-1")
        XCTAssertEqual(stub.stopCalls, ["S-1"])
    }

    func testStubClient_stopPropagatesTypedError() async {
        let stub = StubClient(stopError: .helperNotRunning)
        do {
            try await stub.stopSession(sessionId: "X")
            XCTFail("expected throw")
        } catch let err as SessionControlError {
            XCTAssertEqual(err, .helperNotRunning)
        } catch {
            XCTFail("expected SessionControlError, got \(error)")
        }
    }
}

#if os(macOS)
/// macOS-only smoke tests for the LocalSessionControlClient. We don't
/// stand up a real helper here (no Python in XCTest); instead we
/// point the client at a non-existent socket path and assert that
/// the connection failure surfaces as `.helperNotRunning`. This
/// proves the POSIX error mapping path without a process dependency.
final class LocalSessionControlClientMacTests: XCTestCase {
    func testConnectingToMissingSocketReportsHelperNotRunning() async {
        let client = LocalSessionControlClient(
            socketPath: "/tmp/cli-pulse-iter1-no-such-socket.sock",
            tokenPath: "/tmp/cli-pulse-iter1-no-such-token",
            connectTimeout: 0.5,
            requestTimeout: 0.5
        )
        do {
            _ = try await client.hello()
            XCTFail("expected throw")
        } catch let err as SessionControlError {
            XCTAssertTrue(
                err == .helperNotRunning || err == .timeout || err == .disconnected,
                "expected helperNotRunning / timeout / disconnected, got \(err)"
            )
        } catch {
            XCTFail("expected SessionControlError, got \(error)")
        }
    }

    func testAuthenticatedCallWithMissingTokenReportsUnauthenticated() async {
        // Even if the socket existed, an authenticated method without
        // a token must short-circuit to .unauthenticated before hitting
        // the wire. Use a tmp socket path the connect attempt will
        // fail on, but the token check fires first inside `send`.
        let client = LocalSessionControlClient(
            socketPath: "/tmp/cli-pulse-iter1-no-such-socket.sock",
            tokenPath: "/tmp/cli-pulse-iter1-no-such-token-2",
            connectTimeout: 0.2,
            requestTimeout: 0.2
        )
        do {
            try await client.stopSession(sessionId: "any")
            XCTFail("expected throw")
        } catch let err as SessionControlError {
            // The auth gate fires before connect, so we should see
            // .unauthenticated rather than .helperNotRunning here.
            XCTAssertEqual(err, .unauthenticated)
        } catch {
            XCTFail("expected SessionControlError, got \(error)")
        }
    }
}
#endif
