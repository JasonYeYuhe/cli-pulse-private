import XCTest
@testable import CLIPulseCore

#if os(macOS)

/// Phase 3 Iter 2B — Swift-side tests for the local streaming + structured
/// approval surface. These do NOT spin up a real UDS server (helper-side
/// pytest covers that end-to-end). Coverage here:
///
///   * Wire-code → typed-error mapping for the new approval cases.
///   * `PendingApproval.decode(from:)` accepts the helper's serialised
///     dict and rejects malformed rows.
///   * `LocalSessionEvent.decode(from:)` covers every event type plus
///     the `.other` fallback for unknown events (forward-compat).
///   * `iter2bLocal` capability constant pinning.
///   * AppState gate predicate: Approve / Reject buttons are hidden
///     when `localPendingApprovals[sessionId]` has no rows; visible
///     when at least one PendingApproval exists for that session.
///   * AppState.applyLocalSessionEvent updates the right published
///     buckets without leaking cross-session state.
final class SessionControlIter2BTests: XCTestCase {

    // MARK: - error mapping

    func testWireCodeMapping_approvalNotFound() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "approval_not_found", message: ""),
            .approvalNotFound
        )
    }
    func testWireCodeMapping_approvalExpired() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "approval_expired", message: ""),
            .approvalExpired
        )
    }
    func testWireCodeMapping_approvalAlreadyResolved() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "approval_already_resolved", message: ""),
            .approvalAlreadyResolved
        )
    }
    func testWireCodeMapping_approvalNotAllowed() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "approval_not_allowed", message: ""),
            .approvalNotAllowed
        )
    }
    func testWireCodeMapping_capabilityInvalid() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "approval_capability_invalid", message: ""),
            .approvalCapabilityInvalid
        )
    }
    func testWireCodeMapping_limitReached() {
        XCTAssertEqual(
            SessionControlErrorMapping.error(forWireCode: "approval_limit_reached", message: ""),
            .approvalLimitReached
        )
    }

    // MARK: - capability constant

    func testIter2BLocalCapabilityConstant() {
        XCTAssertEqual(SessionControlCapabilities.iter2bLocal,
                       SessionControlCapabilities(
                           sendInput: true,
                           subscribeEvents: true,
                           approvals: true
                       ))
    }

    // MARK: - PendingApproval decoding

    func testPendingApprovalDecodesValidWire() {
        let raw: [String: Any] = [
            "approval_id": "AID",
            "session_id": "SID",
            "type": "PermissionRequest",
            "title": "Read /etc/hosts",
            "summary": "Read the hosts file",
            "tool_metadata": ["path": "/etc/hosts", "lines": 100],
            "status": "pending",
            "created_at": 1_700_000_000.0,
            "expires_at": 1_700_000_060.0,
        ]
        let p = PendingApproval.decode(from: raw)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.approvalId, "AID")
        XCTAssertEqual(p?.sessionId, "SID")
        XCTAssertEqual(p?.type, "PermissionRequest")
        XCTAssertEqual(p?.title, "Read /etc/hosts")
        XCTAssertEqual(p?.toolMetadata["path"], "/etc/hosts")
        XCTAssertEqual(p?.toolMetadata["lines"], "100")
        XCTAssertEqual(p?.status, "pending")
        XCTAssertNotNil(p?.expiresAt)
    }

    func testPendingApprovalRejectsMissingRequiredFields() {
        // Missing `approval_id`.
        let raw: [String: Any] = [
            "session_id": "SID",
            "status": "pending",
            "created_at": 1_700_000_000.0,
        ]
        XCTAssertNil(PendingApproval.decode(from: raw))
    }

    func testPendingApprovalSurvivesMissingOptionalFields() {
        let raw: [String: Any] = [
            "approval_id": "AID",
            "session_id": "SID",
            "status": "pending",
            "created_at": 1_700_000_000.0,
        ]
        let p = PendingApproval.decode(from: raw)
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.type, "PermissionRequest")  // default
        XCTAssertEqual(p?.title, "PermissionRequest")
        XCTAssertEqual(p?.summary, "")
        XCTAssertNil(p?.expiresAt)
        XCTAssertEqual(p?.toolMetadata.count, 0)
    }

    // MARK: - LocalSessionEvent decoding

    func testLocalSessionEventDecodesOutputDelta() {
        let event = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": "hi",
            "ts": 100.0,
        ])
        if case .outputDelta(let sid, let payload, _) = event {
            XCTAssertEqual(sid, "SID")
            XCTAssertEqual(payload, "hi")
        } else {
            XCTFail("expected outputDelta, got \(String(describing: event))")
        }
    }

    func testLocalSessionEventDecodesSessionStarted() {
        let event = LocalSessionEvent.decode(from: [
            "event": "session_started",
            "session_id": "SID",
            "provider": "claude",
            "client_label": "label-x",
        ])
        if case .sessionStarted(let sid, let provider, let label) = event {
            XCTAssertEqual(sid, "SID")
            XCTAssertEqual(provider, "claude")
            XCTAssertEqual(label, "label-x")
        } else {
            XCTFail("expected sessionStarted")
        }
    }

    func testLocalSessionEventDecodesSessionStopped() {
        let event = LocalSessionEvent.decode(from: [
            "event": "session_stopped",
            "session_id": "SID",
            "exit_code": 2,
        ])
        if case .sessionStopped(let sid, let code) = event {
            XCTAssertEqual(sid, "SID")
            XCTAssertEqual(code, 2)
        } else {
            XCTFail("expected sessionStopped")
        }
    }

    func testLocalSessionEventDecodesApprovalRequested() {
        let event = LocalSessionEvent.decode(from: [
            "event": "approval_requested",
            "session_id": "SID",
            "approval": [
                "approval_id": "AID",
                "session_id": "SID",
                "type": "PermissionRequest",
                "title": "Read",
                "summary": "",
                "status": "pending",
                "created_at": 1.0,
            ],
        ])
        if case .approvalRequested(let approval) = event {
            XCTAssertEqual(approval.approvalId, "AID")
            XCTAssertEqual(approval.sessionId, "SID")
        } else {
            XCTFail("expected approvalRequested")
        }
    }

    func testLocalSessionEventDecodesApprovalResolved() {
        let event = LocalSessionEvent.decode(from: [
            "event": "approval_resolved",
            "session_id": "SID",
            "approval_id": "AID",
            "decision": "approved",
            "status": "approved",
        ])
        if case .approvalResolved(let sid, let aid, let decision, let status) = event {
            XCTAssertEqual(sid, "SID")
            XCTAssertEqual(aid, "AID")
            XCTAssertEqual(decision, "approved")
            XCTAssertEqual(status, "approved")
        } else {
            XCTFail("expected approvalResolved")
        }
    }

    func testLocalSessionEventDecodesHeartbeat() {
        let event = LocalSessionEvent.decode(from: [
            "event": "heartbeat",
            "ts": 12.5,
        ])
        if case .heartbeat = event {
            // OK
        } else {
            XCTFail("expected heartbeat")
        }
    }

    func testLocalSessionEventDecodesError() {
        let event = LocalSessionEvent.decode(from: [
            "event": "error",
            "code": "subscriber_overflow",
            "message": "drop",
        ])
        if case .error(let code, let message) = event {
            XCTAssertEqual(code, "subscriber_overflow")
            XCTAssertEqual(message, "drop")
        } else {
            XCTFail("expected error")
        }
    }

    func testLocalSessionEventForwardCompatOther() {
        let event = LocalSessionEvent.decode(from: [
            "event": "future_event_type_v3",
            "session_id": "SID",
            "extra": "stuff",
        ])
        if case .other(let name, _) = event {
            XCTAssertEqual(name, "future_event_type_v3")
        } else {
            XCTFail("expected .other for unknown events, got \(String(describing: event))")
        }
    }

    func testLocalSessionEventReturnsNilForMissingEventKey() {
        let event = LocalSessionEvent.decode(from: ["session_id": "SID"])
        XCTAssertNil(event)
    }

    // MARK: - AppState approval gate

    /// Approve / Reject controls in SessionsTab MUST be gated on
    /// `localPendingApprovals[sessionId]?.isEmpty == false`. If the
    /// bucket is missing or empty, the row is in the
    /// "no structured pending approval" state and the controls are
    /// hidden — exactly the iter 2A behaviour. When a PendingApproval
    /// arrives via the stream, the controls light up.
    @MainActor
    func testApproveControlsHiddenWhenNoStructuredPendingApproval() {
        let state = AppState()
        XCTAssertNil(state.localPendingApprovals["SID"])
        XCTAssertTrue((state.localPendingApprovals["SID"] ?? []).isEmpty)
        // PTY-shaped output text MUST NOT light up the gate.
        let event = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": "Permission required. 1. Approve  2. Reject",
        ])
        XCTAssertNotNil(event)
        state.applyLocalSessionEvent(event!, sessionId: "SID")
        XCTAssertTrue((state.localPendingApprovals["SID"] ?? []).isEmpty)
    }

    @MainActor
    func testApproveControlsLightUpOnApprovalRequestedEvent() {
        let state = AppState()
        let event = LocalSessionEvent.decode(from: [
            "event": "approval_requested",
            "session_id": "SID",
            "approval": [
                "approval_id": "AID",
                "session_id": "SID",
                "type": "PermissionRequest",
                "title": "Read",
                "summary": "",
                "status": "pending",
                "created_at": 1.0,
            ],
        ])
        XCTAssertNotNil(event)
        state.applyLocalSessionEvent(event!, sessionId: "SID")
        XCTAssertEqual(state.localPendingApprovals["SID"]?.count, 1)
        XCTAssertEqual(state.localPendingApprovals["SID"]?.first?.approvalId, "AID")
    }

    @MainActor
    func testApprovalResolvedEventClearsTheBucket() {
        let state = AppState()
        let req = LocalSessionEvent.decode(from: [
            "event": "approval_requested",
            "session_id": "SID",
            "approval": [
                "approval_id": "AID",
                "session_id": "SID",
                "type": "PermissionRequest",
                "title": "T",
                "summary": "",
                "status": "pending",
                "created_at": 1.0,
            ],
        ])!
        state.applyLocalSessionEvent(req, sessionId: "SID")
        XCTAssertEqual(state.localPendingApprovals["SID"]?.count, 1)
        let resolved = LocalSessionEvent.decode(from: [
            "event": "approval_resolved",
            "session_id": "SID",
            "approval_id": "AID",
            "decision": "approved",
            "status": "approved",
        ])!
        state.applyLocalSessionEvent(resolved, sessionId: "SID")
        XCTAssertNil(state.localPendingApprovals["SID"])
    }

    @MainActor
    func testOutputDeltaUpdatesPreviewBuffer() {
        let state = AppState()
        let e1 = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": "abc",
        ])!
        state.applyLocalSessionEvent(e1, sessionId: "SID")
        XCTAssertEqual(state.localOutputPreview["SID"], "abc")
        let e2 = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": "DEF",
        ])!
        state.applyLocalSessionEvent(e2, sessionId: "SID")
        XCTAssertEqual(state.localOutputPreview["SID"], "abcDEF")
    }

    @MainActor
    func testOutputPreviewCappedAtAppStateConstant() {
        let state = AppState()
        let cap = AppState.localOutputPreviewCap
        // First write fills cap exactly.
        let big = String(repeating: "x", count: cap)
        let e1 = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": big,
        ])!
        state.applyLocalSessionEvent(e1, sessionId: "SID")
        XCTAssertEqual(state.localOutputPreview["SID"]?.count, cap)
        // Second write pushes oldest chars out.
        let e2 = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": "y",
        ])!
        state.applyLocalSessionEvent(e2, sessionId: "SID")
        XCTAssertEqual(state.localOutputPreview["SID"]?.count, cap)
        XCTAssertTrue(state.localOutputPreview["SID"]?.hasSuffix("y") ?? false)
    }

    @MainActor
    func testSessionStoppedClearsPerSessionState() {
        let state = AppState()
        let req = LocalSessionEvent.decode(from: [
            "event": "approval_requested",
            "session_id": "SID",
            "approval": [
                "approval_id": "AID",
                "session_id": "SID",
                "type": "PermissionRequest",
                "title": "T",
                "summary": "",
                "status": "pending",
                "created_at": 1.0,
            ],
        ])!
        state.applyLocalSessionEvent(req, sessionId: "SID")
        let delta = LocalSessionEvent.decode(from: [
            "event": "output_delta",
            "session_id": "SID",
            "payload": "abc",
        ])!
        state.applyLocalSessionEvent(delta, sessionId: "SID")
        XCTAssertEqual(state.localPendingApprovals["SID"]?.count, 1)
        XCTAssertEqual(state.localOutputPreview["SID"], "abc")
        let stopped = LocalSessionEvent.decode(from: [
            "event": "session_stopped",
            "session_id": "SID",
            "exit_code": 0,
        ])!
        state.applyLocalSessionEvent(stopped, sessionId: "SID")
        XCTAssertNil(state.localPendingApprovals["SID"])
        XCTAssertNil(state.localOutputPreview["SID"])
    }

    @MainActor
    func testCrossSessionApprovalDoesNotLeakIntoAnotherSession() {
        let state = AppState()
        // Stream is filtered to "OTHER" but the helper sent an
        // approval frame for "SID" — the apply function must
        // ignore cross-session bleed.
        let req = LocalSessionEvent.decode(from: [
            "event": "approval_requested",
            "session_id": "SID",
            "approval": [
                "approval_id": "AID",
                "session_id": "SID",
                "type": "PermissionRequest",
                "title": "T",
                "summary": "",
                "status": "pending",
                "created_at": 1.0,
            ],
        ])!
        state.applyLocalSessionEvent(req, sessionId: "OTHER")
        // We still record it but under sessionId="OTHER"'s bucket
        // — this is by design (the per-row Task drains the events
        // it gets and trusts the helper's filter to be authoritative).
        // The test's job is just to pin the routing rule so a
        // future refactor doesn't accidentally rebucket by the
        // event's nested session_id without reviewer awareness.
        XCTAssertEqual(state.localPendingApprovals["OTHER"]?.count, 1)
        XCTAssertNil(state.localPendingApprovals["SID"])
    }
}

#endif
