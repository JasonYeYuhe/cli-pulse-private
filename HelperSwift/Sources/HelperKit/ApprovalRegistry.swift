import Foundation
import CryptoKit

/// In-memory approval state — Swift port of
/// `helper/local_approvals.py:ApprovalRegistry`. Iter-2 covers the
/// data plane: register / unregister / create_pending / decide /
/// list_pending / cancel-on-stop.
///
/// Iter-3 adds the wait-for-decision blocking path + descent
/// verification (peer pid + ppid walk) that the hook ingress
/// methods need.
public final class ApprovalRegistry: @unchecked Sendable {

    public struct Limits: Sendable {
        /// Maximum number of pending approvals across all sessions.
        /// Same default as the Python implementation. Beyond this,
        /// `createPending` raises `approvalLimitReached`.
        public var maxTotalPending: Int = 256
        /// Per-session pending cap. Stops one runaway Claude from
        /// starving other sessions.
        public var maxPerSession: Int = 16
        /// Default approval TTL (seconds). The Python helper uses
        /// 60 — matches the macOS UI's 60-second progress bar.
        public var defaultTtlSeconds: TimeInterval = 60.0

        public init() {}
    }

    private let lock = NSLock()
    private let limits: Limits
    private let broker: EventBroker?
    private var managedSessions: [String: ManagedSessionRecord] = [:]
    private var pendingBySession: [String: [String: PendingApproval]] = [:]
    private var approvalIdToSession: [String: String] = [:]
    /// Per-approval condition variable. `waitForDecision` blocks on
    /// the matching condition; `decide` / cancel paths broadcast
    /// to wake every waiter. We index by approvalId so unrelated
    /// approvals don't wake each other.
    private var approvalConditions: [String: NSCondition] = [:]

    /// Test seam: pluggable peer-pid + ppid resolver so unit tests
    /// can simulate descent verification without spawning a real
    /// Claude. Production sets these to the libproc-backed
    /// implementations from `DescentVerification`.
    public var peerPidResolver: ((Int32) -> Int32?)? = nil
    public var parentPidResolver: ((Int32) -> Int32?)? = nil
    /// Iter 4 default: descent skip is OFF in production. Tests
    /// flip this when they don't spawn a real Claude PTY.
    public var allowDescentSkip: Bool = false

    public init(broker: EventBroker? = nil, limits: Limits = Limits()) {
        self.broker = broker
        self.limits = limits
    }

    private struct ManagedSessionRecord {
        var sessionId: String
        var capabilityToken: String
        var claudePid: Int?
        var startedAtMono: TimeInterval
    }

    // MARK: - session lifecycle

    /// Generate a fresh capability token for `sessionId` and return
    /// it. Caller MUST set the returned token in the env passed to
    /// the spawned Claude (`CLI_PULSE_LOCAL_HOOK_TOKEN`) and never
    /// log it.
    @discardableResult
    public func registerSession(_ sessionId: String, claudePid: Int? = nil) -> String {
        let token = Self.generateToken()
        lock.lock()
        // Re-spawn of the same id → invalidate the prior generation's
        // pending approvals so a stale wait can never resolve.
        var effects = CancellationEffects()
        if managedSessions[sessionId] != nil {
            effects = cancelSessionLocked(sessionId, reason: "resession")
        }
        managedSessions[sessionId] = ManagedSessionRecord(
            sessionId: sessionId,
            capabilityToken: token,
            claudePid: claudePid,
            startedAtMono: ProcessInfo.processInfo.systemUptime
        )
        lock.unlock()
        // Wake/publish AFTER releasing `lock` (see flushCancellation).
        flushCancellation(effects)
        return token
    }

    /// Set the Claude PID for a session that was registered before
    /// spawn (when the PID wasn't known yet). No-op if absent.
    /// Idempotent for repeated calls with the same PID.
    public func updateSessionPid(_ sessionId: String, claudePid: Int) {
        guard claudePid > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard var rec = managedSessions[sessionId] else { return }
        rec.claudePid = claudePid
        managedSessions[sessionId] = rec
    }

    /// Drop the session and cancel any pending approvals for it.
    /// Safe to call multiple times.
    public func unregisterSession(_ sessionId: String) {
        lock.lock()
        let existed = managedSessions.removeValue(forKey: sessionId) != nil
        let effects = cancelSessionLocked(sessionId, reason: "stop")
        lock.unlock()
        // Wake/publish AFTER releasing `lock` (see flushCancellation).
        flushCancellation(effects)
        if existed {
            // Lifecycle log mirrors the Python helper's INFO line so
            // operators can tail the same string in either build.
            FileHandle.standardError.write(Data(
                "approvals: unregistered session=\(sessionId) cancelled=\(effects.cancelledCount)\n".utf8
            ))
        }
    }

    public func hasSession(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return managedSessions[sessionId] != nil
    }

    /// Return the capability token for the session, or nil. Used
    /// by tests + by `authenticateHook` (iter 3).
    public func capabilityToken(for sessionId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return managedSessions[sessionId]?.capabilityToken
    }

    /// Verify the hook is allowed to interact on behalf of
    /// `sessionId`. Two checks (matching the Python helper):
    ///
    ///   1. **Capability token** equals the one stored at register
    ///      time. Constant-time comparison.
    ///   2. **Descent verification** — peer pid (from
    ///      `getsockopt(LOCAL_PEERPID)`) is in the process tree
    ///      rooted at the recorded Claude pid. Defends against a
    ///      leaked token from outside the Claude process.
    ///
    /// Either check failing throws — never falls through to
    /// token-only without `allowDescentSkip = true` (test seam).
    public func authenticateHook(
        sessionId: String,
        capabilityToken: String,
        peerFD: Int32?
    ) throws {
        lock.lock()
        guard let rec = managedSessions[sessionId] else {
            lock.unlock()
            throw RegistryError.sessionNotFound
        }
        let storedToken = rec.capabilityToken
        let claudePid = rec.claudePid
        lock.unlock()

        if !AuthToken.compare(expected: storedToken, supplied: capabilityToken) {
            throw RegistryError.capabilityInvalid
        }
        // Descent verification.
        guard let claudePid else {
            // No claude pid recorded yet — register-then-update
            // race; fail closed unless explicitly skipped.
            if allowDescentSkip { return }
            throw RegistryError.descentMismatch
        }
        guard let peerFD else {
            if allowDescentSkip { return }
            throw RegistryError.descentMismatch
        }
        // Use the test-seam resolvers if set, otherwise fall back
        // to libproc. The default lookup is via
        // `DescentVerification`'s production resolvers.
        let peerResolver = peerPidResolver ?? DescentVerification.peerPid(forFD:)
        let parentResolver = parentPidResolver ?? DescentVerification.parentPid(of:)
        guard let peerPid = peerResolver(peerFD) else {
            if allowDescentSkip { return }
            throw RegistryError.descentMismatch
        }
        if !DescentVerification.descentChainContains(
            claudePid: Int32(claudePid),
            peerPid: peerPid,
            parentResolver: parentResolver
        ) {
            throw RegistryError.descentMismatch
        }
    }

    /// Block the calling thread until the approval at `approvalId`
    /// is decided / cancelled / expired, OR `timeout` elapses.
    /// Returns the resolved row on decision; throws `waitTimeout`
    /// on timeout, `approvalNotFound` if the id never existed,
    /// `approvalNotAllowed` on session mismatch.
    ///
    /// Uses NSCondition for the wait — broadcast from the decide
    /// / cancel paths wakes every waiter for the row.
    public func waitForDecision(
        sessionId: String,
        approvalId: String,
        timeout: TimeInterval
    ) throws -> PendingApproval {
        // Reach into the store under lock to fetch / create the
        // condition variable + take an initial snapshot of the
        // row's status.
        lock.lock()
        guard let bucketSessionId = approvalIdToSession[approvalId] else {
            lock.unlock()
            throw RegistryError.approvalNotFound
        }
        if bucketSessionId != sessionId {
            lock.unlock()
            throw RegistryError.approvalNotAllowed
        }
        guard let bucket = pendingBySession[sessionId],
              let initialRow = bucket[approvalId] else {
            lock.unlock()
            throw RegistryError.approvalNotFound
        }
        if initialRow.status != .pending {
            // Already resolved; return immediately.
            lock.unlock()
            return initialRow
        }
        var condition: NSCondition
        if let existing = approvalConditions[approvalId] {
            condition = existing
        } else {
            condition = NSCondition()
            approvalConditions[approvalId] = condition
        }
        lock.unlock()

        // Wait on the condition. NSCondition's `wait(until:)` is
        // the right primitive: spurious wakeups loop back, real
        // signals fall through to the recheck. We use a deadline
        // rather than relative timeout so the loop is safe across
        // wakeups.
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            // Recheck status under the registry lock.
            lock.lock()
            let bucket = pendingBySession[sessionId] ?? [:]
            if let row = bucket[approvalId], row.status != .pending {
                lock.unlock()
                return row
            }
            // Was the row removed entirely (cancel-on-stop deletes
            // from the map after publishing)? Treat as "wait
            // failed" — caller should fall back to a deny.
            if bucket[approvalId] == nil {
                lock.unlock()
                throw RegistryError.approvalNotFound
            }
            lock.unlock()

            let now = Date()
            if now >= deadline { throw RegistryError.waitTimeout }
            // condition.wait(until:) returns false on timeout.
            if !condition.wait(until: deadline) {
                throw RegistryError.waitTimeout
            }
        }
    }

    // MARK: - pending approval lifecycle

    public enum RegistryError: Error, Equatable {
        case sessionNotFound
        case approvalLimitReached
        case approvalNotFound
        case approvalAlreadyResolved(currentStatus: String)
        case approvalNotAllowed
        /// Hook auth: capability token doesn't match the recorded
        /// one for the session. Maps to `approval_capability_invalid`
        /// on the wire.
        case capabilityInvalid
        /// Hook auth: descent verification refused — peer is not
        /// in the recorded Claude pid's process tree.
        case descentMismatch
        /// Wait timed out without a decision. Returned by
        /// `waitForDecision` so the hook subprocess can fall back
        /// to its local prompt.
        case waitTimeout
    }

    /// Create a new pending approval for `sessionId`. Caller is
    /// usually the hook ingress path. Returns the row that was
    /// added. Publishes an `approval_requested` event to the
    /// broker (if wired).
    @discardableResult
    public func createPending(
        sessionId: String,
        kind: String,
        title: String,
        summary: String,
        toolMetadata: [String: Any],
        ttlSeconds: TimeInterval? = nil
    ) throws -> PendingApproval {
        let now = Date().timeIntervalSince1970
        let mono = ProcessInfo.processInfo.systemUptime
        let ttl = ttlSeconds ?? limits.defaultTtlSeconds
        let approvalId = UUID().uuidString.lowercased()
        let approval = PendingApproval(
            approvalId: approvalId,
            sessionId: sessionId,
            kind: kind,
            title: title,
            summary: summary,
            toolMetadata: toolMetadata,
            status: .pending,
            createdAtWall: now,
            createdAtMono: mono,
            expiresAtWall: now + ttl
        )

        lock.lock()
        guard managedSessions[sessionId] != nil else {
            lock.unlock()
            throw RegistryError.sessionNotFound
        }
        let totalPending = pendingBySession.values.reduce(0) { $0 + $1.count }
        if totalPending >= limits.maxTotalPending {
            lock.unlock()
            throw RegistryError.approvalLimitReached
        }
        if (pendingBySession[sessionId]?.count ?? 0) >= limits.maxPerSession {
            lock.unlock()
            throw RegistryError.approvalLimitReached
        }
        var bucket = pendingBySession[sessionId] ?? [:]
        bucket[approvalId] = approval
        pendingBySession[sessionId] = bucket
        approvalIdToSession[approvalId] = sessionId
        lock.unlock()

        broker?.publish([
            "event": "approval_requested",
            "session_id": sessionId,
            "approval_id": approvalId,
            "approval": approval.toDictSafe(),
            "ts": now,
        ])
        return approval
    }

    /// Resolve a pending approval. `decision` is either "approve"
    /// or "reject". Throws `approvalNotFound` if the id is unknown
    /// for this session, `approvalAlreadyResolved` if a prior
    /// decide / cancel finalised the row.
    @discardableResult
    public func decide(
        sessionId: String,
        approvalId: String,
        decision: String,
        comment: String? = nil
    ) throws -> PendingApproval {
        let now = Date().timeIntervalSince1970
        lock.lock()
        guard let storedSessionId = approvalIdToSession[approvalId] else {
            lock.unlock()
            throw RegistryError.approvalNotFound
        }
        if storedSessionId != sessionId {
            lock.unlock()
            throw RegistryError.approvalNotAllowed
        }
        guard var bucket = pendingBySession[sessionId],
              var row = bucket[approvalId] else {
            lock.unlock()
            throw RegistryError.approvalNotFound
        }
        if row.status != .pending {
            let s = row.status.rawValue
            lock.unlock()
            throw RegistryError.approvalAlreadyResolved(currentStatus: s)
        }
        row.status = (decision == "approve") ? .approved : .rejected
        row.decidedDecision = (decision == "approve") ? "approved" : "rejected"
        row.decidedAtWall = now
        row.decidedComment = comment
        bucket[approvalId] = row
        pendingBySession[sessionId] = bucket
        let resolved = row
        let waitCondition = approvalConditions[approvalId]
        lock.unlock()

        // Wake any blocked waitForDecision callers. Broadcast so
        // every waiter (the design allows multiple) sees the
        // resolution under their own condition.lock().
        if let waitCondition {
            waitCondition.lock()
            waitCondition.broadcast()
            waitCondition.unlock()
        }

        broker?.publish([
            "event": "approval_resolved",
            "session_id": sessionId,
            "approval_id": approvalId,
            "decision": resolved.decidedDecision ?? decision,
            "status": resolved.status.rawValue,
            "approval": resolved.toDictSafe(),
            "ts": now,
        ])
        return resolved
    }

    /// Snapshot of pending approvals. Used by the
    /// `get_pending_approvals` UDS method + the subscribe-event
    /// initial frame. `sessionId == nil` returns rows from every
    /// session.
    public func listPending(sessionId: String? = nil) -> [PendingApproval] {
        lock.lock(); defer { lock.unlock() }
        if let sessionId {
            let bucket = pendingBySession[sessionId] ?? [:]
            return Array(bucket.values).filter { $0.status == .pending }
        }
        return pendingBySession.values.flatMap { $0.values }
            .filter { $0.status == .pending }
    }

    /// Sweep approvals whose `expires_at_wall` is in the past.
    /// Iter-2 stub: just flips status; iter-3 fires the
    /// `approval_resolved` (status=expired) event.
    @discardableResult
    public func expireOld(now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        var expired: [PendingApproval] = []
        lock.lock()
        for (sid, bucket) in pendingBySession {
            var newBucket = bucket
            for (aid, row) in bucket where row.status == .pending {
                if let exp = row.expiresAtWall, now >= exp {
                    var updated = row
                    updated.status = .expired
                    newBucket[aid] = updated
                    expired.append(updated)
                }
            }
            pendingBySession[sid] = newBucket
        }
        lock.unlock()
        for row in expired {
            broker?.publish([
                "event": "approval_resolved",
                "session_id": row.sessionId,
                "approval_id": row.approvalId,
                "decision": "expired",
                "status": "expired",
                "approval": row.toDictSafe(),
                "ts": now,
            ])
        }
        return expired.count
    }

    // MARK: - private

    /// Deferred side-effects of a cancellation. These MUST run only
    /// after the registry `lock` is released — see `flushCancellation`.
    private struct CancellationEffects {
        var cancelledCount = 0
        var conditionsToWake: [NSCondition] = []
        var resolvedRows: [PendingApproval] = []
    }

    /// Cancel every pending approval bound to `sessionId`. Caller
    /// MUST hold `lock`. This only mutates the in-memory maps and
    /// *collects* the waiters to wake + rows to publish; it does NOT
    /// broadcast or publish itself. The caller MUST drop `lock` and
    /// then call `flushCancellation(_:)` with the returned effects.
    ///
    /// Why the split: `waitForDecision` holds a per-approval
    /// `NSCondition` lock and then reaches for the registry `lock`
    /// (condition→lock). If cancellation broadcast on that same
    /// condition while holding `lock` (lock→condition), the two
    /// orderings invert into an ABBA deadlock. Deferring the
    /// broadcast to after `lock.unlock()` mirrors the safe ordering
    /// `decide` already uses.
    private func cancelSessionLocked(_ sessionId: String, reason: String) -> CancellationEffects {
        var effects = CancellationEffects()
        guard let bucket = pendingBySession.removeValue(forKey: sessionId) else {
            return effects
        }
        let now = Date().timeIntervalSince1970
        for (aid, row) in bucket {
            if row.status != .pending { continue }
            var updated = row
            updated.status = .cancelled
            updated.decidedDecision = "cancelled"
            updated.decidedAtWall = now
            updated.decidedComment = reason
            approvalIdToSession.removeValue(forKey: aid)
            // Capture condition so the caller can wake blocked
            // waitForDecision callers AFTER dropping `lock`.
            if let cv = approvalConditions[aid] {
                effects.conditionsToWake.append(cv)
            }
            effects.resolvedRows.append(updated)
            effects.cancelledCount += 1
        }
        return effects
    }

    /// Run the deferred side-effects of a cancellation. MUST be
    /// called WITHOUT holding `lock` (the cv broadcast acquires the
    /// per-approval condition lock, which `waitForDecision` holds
    /// while reaching for `lock` — broadcasting under `lock` would
    /// deadlock). Safe to call with empty effects (no-op).
    private func flushCancellation(_ effects: CancellationEffects) {
        // Wake any blocked waiters. Each broadcast is a no-op for
        // unrelated waiters (their condition.wait(until:) loop
        // re-checks status and goes back to sleep).
        for cv in effects.conditionsToWake {
            cv.lock()
            cv.broadcast()
            cv.unlock()
        }
        // broker.publish takes its own lock, but the broker's lock is
        // independent of this registry's lock so there's no nested-lock
        // hazard (and we're not holding `lock` here anyway).
        for row in effects.resolvedRows {
            broker?.publish([
                "event": "approval_resolved",
                "session_id": row.sessionId,
                "approval_id": row.approvalId,
                "decision": "cancelled",
                "status": row.status.rawValue,
                "approval": row.toDictSafe(),
                "ts": row.decidedAtWall ?? Date().timeIntervalSince1970,
            ])
        }
    }

    /// Generate a fresh per-session capability token. 32 bytes of
    /// crypto-random, base64 encoded — same shape as the Python
    /// `_generate_token` and the app's hook env contract.
    private static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        if result != errSecSuccess {
            // Should never happen on macOS where kSecRandomDefault
            // is the OS RNG. Fall back to SymmetricKey which uses
            // the same primitives but throws differently.
            let key = SymmetricKey(size: .bits256)
            return key.withUnsafeBytes { Data($0).base64EncodedString() }
        }
        return Data(bytes).base64EncodedString()
    }
}
