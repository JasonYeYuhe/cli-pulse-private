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
        lock.lock(); defer { lock.unlock() }
        // Re-spawn of the same id → invalidate the prior generation's
        // pending approvals so a stale wait can never resolve.
        if managedSessions[sessionId] != nil {
            cancelSessionLocked(sessionId, reason: "resession")
        }
        managedSessions[sessionId] = ManagedSessionRecord(
            sessionId: sessionId,
            capabilityToken: token,
            claudePid: claudePid,
            startedAtMono: ProcessInfo.processInfo.systemUptime
        )
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
        let cancelled = cancelSessionLocked(sessionId, reason: "stop")
        lock.unlock()
        if existed {
            // Lifecycle log mirrors the Python helper's INFO line so
            // operators can tail the same string in either build.
            FileHandle.standardError.write(Data(
                "approvals: unregistered session=\(sessionId) cancelled=\(cancelled)\n".utf8
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

    // MARK: - pending approval lifecycle

    public enum RegistryError: Error, Equatable {
        case sessionNotFound
        case approvalLimitReached
        case approvalNotFound
        case approvalAlreadyResolved(currentStatus: String)
        case approvalNotAllowed
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
        lock.unlock()

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

    /// Cancel every pending approval bound to `sessionId`. Caller
    /// must hold `lock`. Returns count.
    @discardableResult
    private func cancelSessionLocked(_ sessionId: String, reason: String) -> Int {
        guard let bucket = pendingBySession.removeValue(forKey: sessionId) else {
            return 0
        }
        var cancelled = 0
        let now = Date().timeIntervalSince1970
        var resolvedRows: [PendingApproval] = []
        for (aid, row) in bucket {
            if row.status != .pending { continue }
            var updated = row
            updated.status = .cancelled
            updated.decidedDecision = "cancelled"
            updated.decidedAtWall = now
            updated.decidedComment = reason
            approvalIdToSession.removeValue(forKey: aid)
            resolvedRows.append(updated)
            cancelled += 1
        }
        // Drop lock before publishing — but cancelSessionLocked is
        // called from inside the lock. Defer the publish to the
        // caller in iter 3 when wait-for-decision needs the
        // notification timing precise. iter 2: best-effort emit
        // from inside the lock — broker.publish takes its own
        // lock, but the broker's lock is independent of this
        // registry's lock so there's no nested-lock hazard.
        for row in resolvedRows {
            broker?.publish([
                "event": "approval_resolved",
                "session_id": row.sessionId,
                "approval_id": row.approvalId,
                "decision": "cancelled",
                "status": row.status.rawValue,
                "approval": row.toDictSafe(),
                "ts": now,
            ])
        }
        return cancelled
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
