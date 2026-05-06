import XCTest
@testable import HelperKit
import Foundation

/// Swift port of `helper/test_local_approvals.py` — pins the
/// pending-approval data plane invariants. Iter 2 covers register
/// / unregister / createPending / decide / listPending / expire +
/// cancel-on-stop. Iter 3 will add the wait-for-decision blocking
/// path + descent verification (peer pid + ppid walk).
final class ApprovalRegistryTests: XCTestCase {

    private func makeRegistry(_ broker: EventBroker? = nil) -> ApprovalRegistry {
        return ApprovalRegistry(broker: broker)
    }

    // MARK: - session lifecycle

    func testRegisterSessionReturnsToken() {
        let r = makeRegistry()
        let token = r.registerSession("S1", claudePid: 1234)
        XCTAssertEqual(token.count, 44, "32 raw bytes → 44 chars padded base64")
        XCTAssertTrue(r.hasSession("S1"))
        XCTAssertEqual(r.capabilityToken(for: "S1"), token)
    }

    func testRegisterSessionEachCallNewToken() {
        let r = makeRegistry()
        let t1 = r.registerSession("S1")
        let t2 = r.registerSession("S2")
        XCTAssertNotEqual(t1, t2)
    }

    func testReregisterSessionInvalidatesOldToken() {
        let r = makeRegistry()
        let t1 = r.registerSession("S1")
        // Simulate a stale pending from the first generation.
        _ = try? r.createPending(
            sessionId: "S1", kind: "Bash",
            title: "ls", summary: "ls /etc",
            toolMetadata: [:]
        )
        XCTAssertFalse(r.listPending(sessionId: "S1").isEmpty)
        // Re-register triggers cancel-on-stop semantics for the
        // prior generation's pending rows.
        let t2 = r.registerSession("S1")
        XCTAssertNotEqual(t1, t2, "re-register must rotate the cap token")
        XCTAssertTrue(r.listPending(sessionId: "S1").isEmpty,
                      "stale pending from old generation must be cancelled")
    }

    func testUnregisterSessionDropsState() {
        let r = makeRegistry()
        _ = r.registerSession("S1")
        r.unregisterSession("S1")
        XCTAssertFalse(r.hasSession("S1"))
        XCTAssertNil(r.capabilityToken(for: "S1"))
    }

    func testUnregisterSessionIsIdempotent() {
        let r = makeRegistry()
        _ = r.registerSession("S1")
        r.unregisterSession("S1")
        // Second call must not throw / not affect anything.
        r.unregisterSession("S1")
        XCTAssertFalse(r.hasSession("S1"))
    }

    func testUpdateSessionPidIsNoopForUnknownSession() {
        let r = makeRegistry()
        // Should not throw, should not create a session.
        r.updateSessionPid("ghost", claudePid: 9999)
        XCTAssertFalse(r.hasSession("ghost"))
    }

    // MARK: - createPending

    func testCreatePendingThrowsOnUnregisteredSession() {
        let r = makeRegistry()
        XCTAssertThrowsError(try r.createPending(
            sessionId: "ghost", kind: "Bash",
            title: "x", summary: "x", toolMetadata: [:]
        )) { err in
            guard case ApprovalRegistry.RegistryError.sessionNotFound = err else {
                XCTFail("expected sessionNotFound, got \(err)"); return
            }
        }
    }

    func testCreatePendingEnforcesPerSessionLimit() {
        var limits = ApprovalRegistry.Limits()
        limits.maxPerSession = 2
        let r = ApprovalRegistry(limits: limits)
        _ = r.registerSession("S")
        _ = try? r.createPending(sessionId: "S", kind: "Bash",
                                  title: "1", summary: "", toolMetadata: [:])
        _ = try? r.createPending(sessionId: "S", kind: "Bash",
                                  title: "2", summary: "", toolMetadata: [:])
        XCTAssertThrowsError(try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "3", summary: "", toolMetadata: [:]
        )) { err in
            guard case ApprovalRegistry.RegistryError.approvalLimitReached = err else {
                XCTFail("expected approvalLimitReached"); return
            }
        }
    }

    func testCreatePendingPublishesApprovalRequestedEvent() throws {
        let broker = EventBroker()
        var captured: [[String: Any]] = []
        let captureLock = NSLock()
        _ = broker.subscribe(sessionFilter: nil) { ev in
            captureLock.lock(); defer { captureLock.unlock() }
            captured.append(ev)
        }
        let r = ApprovalRegistry(broker: broker)
        _ = r.registerSession("S")
        _ = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "ls /etc/hosts",
            summary: "List /etc/hosts file details",
            toolMetadata: ["tool_name": "Bash"]
        )
        captureLock.lock(); defer { captureLock.unlock() }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?["event"] as? String, "approval_requested")
        XCTAssertEqual(captured.first?["session_id"] as? String, "S")
    }

    // MARK: - decide

    func testDecideApproveMarksRowResolved() throws {
        let r = makeRegistry()
        _ = r.registerSession("S")
        let pending = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "ls", summary: "ls /etc/hosts", toolMetadata: [:]
        )
        let resolved = try r.decide(sessionId: "S", approvalId: pending.approvalId,
                                     decision: "approve")
        XCTAssertEqual(resolved.status, .approved)
        XCTAssertEqual(resolved.decidedDecision, "approved")
        XCTAssertNotNil(resolved.decidedAtWall)
        // Pending list no longer contains this row.
        XCTAssertTrue(r.listPending(sessionId: "S").isEmpty)
    }

    func testDecideRejectMarksRowResolved() throws {
        let r = makeRegistry()
        _ = r.registerSession("S")
        let p = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "rm -rf", summary: "", toolMetadata: [:]
        )
        let resolved = try r.decide(sessionId: "S", approvalId: p.approvalId,
                                     decision: "reject", comment: "obviously not")
        XCTAssertEqual(resolved.status, .rejected)
        XCTAssertEqual(resolved.decidedComment, "obviously not")
    }

    func testDecideThrowsOnDoubleResolve() throws {
        let r = makeRegistry()
        _ = r.registerSession("S")
        let p = try r.createPending(sessionId: "S", kind: "Bash",
                                     title: "x", summary: "", toolMetadata: [:])
        _ = try r.decide(sessionId: "S", approvalId: p.approvalId, decision: "approve")
        XCTAssertThrowsError(try r.decide(
            sessionId: "S", approvalId: p.approvalId, decision: "approve"
        )) { err in
            guard case ApprovalRegistry.RegistryError.approvalAlreadyResolved = err else {
                XCTFail("expected approvalAlreadyResolved"); return
            }
        }
    }

    func testDecideThrowsOnUnknownApprovalId() {
        let r = makeRegistry()
        _ = r.registerSession("S")
        XCTAssertThrowsError(try r.decide(sessionId: "S",
                                           approvalId: "nope",
                                           decision: "approve")) { err in
            guard case ApprovalRegistry.RegistryError.approvalNotFound = err else {
                XCTFail("expected approvalNotFound"); return
            }
        }
    }

    func testDecideThrowsWhenSessionMismatch() throws {
        let r = makeRegistry()
        _ = r.registerSession("A")
        _ = r.registerSession("B")
        let p = try r.createPending(sessionId: "A", kind: "Bash",
                                     title: "x", summary: "", toolMetadata: [:])
        XCTAssertThrowsError(try r.decide(sessionId: "B",
                                           approvalId: p.approvalId,
                                           decision: "approve")) { err in
            guard case ApprovalRegistry.RegistryError.approvalNotAllowed = err else {
                XCTFail("expected approvalNotAllowed"); return
            }
        }
    }

    // MARK: - cancel-on-stop (Stop-with-pending invariant from iter6 e2e)

    func testUnregisterSessionCancelsPendingApprovals() throws {
        let broker = EventBroker()
        let captureLock = NSLock()
        var events: [[String: Any]] = []
        _ = broker.subscribe(sessionFilter: nil) { ev in
            captureLock.lock(); defer { captureLock.unlock() }
            events.append(ev)
        }
        let r = ApprovalRegistry(broker: broker)
        _ = r.registerSession("S")
        _ = try r.createPending(sessionId: "S", kind: "Bash",
                                 title: "x", summary: "", toolMetadata: [:])
        XCTAssertEqual(r.listPending(sessionId: "S").count, 1)
        // Stop without resolving — must cancel + emit
        // approval_resolved (status=cancelled) for the pending row.
        r.unregisterSession("S")
        XCTAssertTrue(r.listPending(sessionId: "S").isEmpty)
        captureLock.lock(); defer { captureLock.unlock() }
        let resolved = events.first { ($0["event"] as? String) == "approval_resolved" }
        XCTAssertNotNil(resolved, "cancel-on-stop must publish approval_resolved")
        XCTAssertEqual(resolved?["status"] as? String, "cancelled")
    }

    // MARK: - listPending + expireOld

    func testListPendingFiltersBySession() throws {
        let r = makeRegistry()
        _ = r.registerSession("A")
        _ = r.registerSession("B")
        _ = try r.createPending(sessionId: "A", kind: "Bash",
                                 title: "in A", summary: "", toolMetadata: [:])
        _ = try r.createPending(sessionId: "B", kind: "Bash",
                                 title: "in B", summary: "", toolMetadata: [:])
        let allPending = r.listPending()
        XCTAssertEqual(allPending.count, 2)
        let scopedA = r.listPending(sessionId: "A")
        XCTAssertEqual(scopedA.count, 1)
        XCTAssertEqual(scopedA.first?.title, "in A")
    }

    func testExpireOldFlipsExpiredRows() throws {
        let r = makeRegistry()
        _ = r.registerSession("S")
        _ = try r.createPending(
            sessionId: "S", kind: "Bash", title: "x", summary: "",
            toolMetadata: [:],
            ttlSeconds: 0.01
        )
        // Wait past the TTL.
        usleep(100_000) // 0.1 s
        let count = r.expireOld(now: Date().timeIntervalSince1970)
        XCTAssertEqual(count, 1, "expired sweep must flip exactly the one row")
        XCTAssertTrue(r.listPending(sessionId: "S").isEmpty,
                      "expired rows must drop out of the pending list")
    }
}
