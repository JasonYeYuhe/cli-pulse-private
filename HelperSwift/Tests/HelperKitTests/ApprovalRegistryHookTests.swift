import XCTest
@testable import HelperKit
import Foundation
import Darwin

/// Iter 4 tests: hook ingress — `authenticateHook` (capability
/// token + descent) and `waitForDecision` (blocking wait that wakes
/// on `decide` or cancel-on-stop).
final class ApprovalRegistryHookTests: XCTestCase {

    // MARK: - authenticateHook

    func testAuthenticateHookAcceptsCorrectTokenAndDescent() throws {
        let r = ApprovalRegistry()
        // Configure the test seam to simulate descent verification
        // without spawning a real process. Pretend the peer is
        // pid 200, parent 100.
        r.peerPidResolver = { _ in 200 }
        r.parentPidResolver = { pid in pid == 200 ? 100 : nil }
        let token = r.registerSession("S")
        r.updateSessionPid("S", claudePid: 100)
        XCTAssertNoThrow(try r.authenticateHook(
            sessionId: "S", capabilityToken: token, peerFD: 0
        ))
    }

    func testAuthenticateHookRejectsBadToken() throws {
        let r = ApprovalRegistry()
        r.allowDescentSkip = true
        _ = r.registerSession("S")
        r.updateSessionPid("S", claudePid: 100)
        XCTAssertThrowsError(try r.authenticateHook(
            sessionId: "S", capabilityToken: "wrong-token", peerFD: 0
        )) { err in
            guard case ApprovalRegistry.RegistryError.capabilityInvalid = err else {
                XCTFail("expected capabilityInvalid, got \(err)"); return
            }
        }
    }

    func testAuthenticateHookRejectsUnknownSession() throws {
        let r = ApprovalRegistry()
        XCTAssertThrowsError(try r.authenticateHook(
            sessionId: "ghost", capabilityToken: "x", peerFD: 0
        )) { err in
            guard case ApprovalRegistry.RegistryError.sessionNotFound = err else {
                XCTFail("expected sessionNotFound"); return
            }
        }
    }

    func testAuthenticateHookRejectsDescentMismatch() throws {
        let r = ApprovalRegistry()
        // Peer pid 999, parent 1 (launchd) — NOT in claude=100's tree.
        r.peerPidResolver = { _ in 999 }
        r.parentPidResolver = { pid in pid == 999 ? 1 : nil }
        let token = r.registerSession("S")
        r.updateSessionPid("S", claudePid: 100)
        XCTAssertThrowsError(try r.authenticateHook(
            sessionId: "S", capabilityToken: token, peerFD: 0
        )) { err in
            guard case ApprovalRegistry.RegistryError.descentMismatch = err else {
                XCTFail("expected descentMismatch"); return
            }
        }
    }

    /// Codex review on PR #18 hardened the original fail-open
    /// posture: when the recorded Claude pid is missing AND
    /// `allowDescentSkip` is false, registry MUST fail closed
    /// rather than degrade to token-only.
    func testAuthenticateHookFailsClosedWhenClaudePidMissing() throws {
        let r = ApprovalRegistry()
        r.allowDescentSkip = false
        let token = r.registerSession("S", claudePid: nil)
        XCTAssertThrowsError(try r.authenticateHook(
            sessionId: "S", capabilityToken: token, peerFD: 0
        )) { err in
            guard case ApprovalRegistry.RegistryError.descentMismatch = err else {
                XCTFail("expected descentMismatch under fail-closed posture"); return
            }
        }
    }

    func testAuthenticateHookAllowsSkipWhenExplicitOptIn() throws {
        let r = ApprovalRegistry()
        r.allowDescentSkip = true
        let token = r.registerSession("S", claudePid: nil)
        // Even with no claude pid + no peerFD, opt-in skip means
        // token-only auth passes — used by unit tests that don't
        // spawn real Claude PTY.
        XCTAssertNoThrow(try r.authenticateHook(
            sessionId: "S", capabilityToken: token, peerFD: nil
        ))
    }

    // MARK: - waitForDecision

    func testWaitForDecisionResolvesOnDecide() throws {
        let r = ApprovalRegistry()
        _ = r.registerSession("S")
        let pending = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "ls", summary: "ls /etc/hosts", toolMetadata: [:]
        )
        // Decide on a separate thread after a short delay.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            _ = try? r.decide(sessionId: "S",
                              approvalId: pending.approvalId,
                              decision: "approve")
        }
        let resolved = try r.waitForDecision(
            sessionId: "S", approvalId: pending.approvalId, timeout: 2.0
        )
        XCTAssertEqual(resolved.status, .approved)
    }

    func testWaitForDecisionResolvesOnCancelOnStop() throws {
        let r = ApprovalRegistry()
        _ = r.registerSession("S")
        let pending = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "x", summary: "", toolMetadata: [:]
        )
        // Stop the session (cancels pending) on a separate
        // thread; waitForDecision must surface
        // approvalNotFound (the row was removed) so the hook
        // subprocess falls back to a deny.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            r.unregisterSession("S")
        }
        XCTAssertThrowsError(try r.waitForDecision(
            sessionId: "S", approvalId: pending.approvalId, timeout: 2.0
        )) { err in
            guard case ApprovalRegistry.RegistryError.approvalNotFound = err else {
                XCTFail("expected approvalNotFound after cancel-on-stop, got \(err)")
                return
            }
        }
    }

    /// ABBA-deadlock regression (2026-05-29 audit). `waitForDecision`
    /// holds the per-approval NSCondition and then reaches for the
    /// registry lock (condition→lock). The cancel path must therefore
    /// wake waiters only AFTER dropping the registry lock — never
    /// lock→condition, which would invert the order into a deadlock.
    /// This races a soon-to-block waiter against a session cancel many
    /// times to hit the tight window between `condition.lock()` and
    /// `lock.lock()`. A regression would hang one iteration; the
    /// per-iteration watchdog fails fast instead of wedging the suite.
    func testCancelDuringWaitDoesNotDeadlock() {
        let iterations = 500
        for i in 0..<iterations {
            let r = ApprovalRegistry()
            let sid = "S-\(i)"
            _ = r.registerSession(sid)
            guard let pending = try? r.createPending(
                sessionId: sid, kind: "Bash",
                title: "x", summary: "", toolMetadata: [:]
            ) else {
                XCTFail("createPending failed at iter \(i)"); return
            }

            let done = DispatchSemaphore(value: 0)
            // A waiter that, if not woken by the cancel, would block
            // for the full (long) timeout — so a return proves the
            // cancel woke it, not a timeout masking a deadlock.
            DispatchQueue.global().async {
                _ = try? r.waitForDecision(
                    sessionId: sid, approvalId: pending.approvalId, timeout: 30.0
                )
                done.signal()
            }
            // Race the cancel against the waiter entering the wait.
            DispatchQueue.global().async {
                r.unregisterSession(sid)
            }

            // Correct registry resolves the waiter in well under a ms;
            // a deadlock would block forever.
            if done.wait(timeout: .now() + 5.0) == .timedOut {
                XCTFail("waitForDecision did not return after cancel at iter \(i) — ABBA deadlock regression")
                return
            }
        }
    }

    func testWaitForDecisionTimesOut() throws {
        let r = ApprovalRegistry()
        _ = r.registerSession("S")
        let p = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "x", summary: "", toolMetadata: [:]
        )
        XCTAssertThrowsError(try r.waitForDecision(
            sessionId: "S", approvalId: p.approvalId, timeout: 0.05
        )) { err in
            guard case ApprovalRegistry.RegistryError.waitTimeout = err else {
                XCTFail("expected waitTimeout"); return
            }
        }
    }

    func testWaitForDecisionReturnsImmediatelyIfAlreadyResolved() throws {
        let r = ApprovalRegistry()
        _ = r.registerSession("S")
        let p = try r.createPending(
            sessionId: "S", kind: "Bash",
            title: "x", summary: "", toolMetadata: [:]
        )
        _ = try r.decide(sessionId: "S", approvalId: p.approvalId, decision: "reject")
        let resolved = try r.waitForDecision(
            sessionId: "S", approvalId: p.approvalId, timeout: 0.05
        )
        XCTAssertEqual(resolved.status, .rejected)
    }

    func testWaitForDecisionRejectsSessionMismatch() throws {
        let r = ApprovalRegistry()
        _ = r.registerSession("A")
        _ = r.registerSession("B")
        let p = try r.createPending(
            sessionId: "A", kind: "Bash",
            title: "x", summary: "", toolMetadata: [:]
        )
        XCTAssertThrowsError(try r.waitForDecision(
            sessionId: "B", approvalId: p.approvalId, timeout: 0.05
        )) { err in
            guard case ApprovalRegistry.RegistryError.approvalNotAllowed = err else {
                XCTFail("expected approvalNotAllowed"); return
            }
        }
    }
}
