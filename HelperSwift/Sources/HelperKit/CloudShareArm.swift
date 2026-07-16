import Foundation

/// M4.4d: a late-bound handle to `RemoteAgentCloud`'s share/unshare entry
/// points, plus the async→sync bridge the UDS layer needs.
///
/// Two mismatches make this indirection necessary, and neither is worth
/// restructuring the daemon over:
///
///  1. **Ordering.** `LocalSessionServer` is constructed and started BEFORE
///     `RemoteAgentCloud` — and the cloud arm only exists at all when the
///     helper is paired. The server's hook closure therefore has to resolve the
///     arm at CALL time, not at construction time.
///  2. **Concurrency domain.** `RemoteAgentCloud` is an actor, but the UDS
///     dispatch path is synchronous. Each connection runs on its own thread
///     (`LocalSessionServer.start()`), so blocking that thread on the actor
///     call stalls only the client that asked — which is exactly the semantics
///     a user's toggle wants anyway: it should not report success until the
///     cloud row actually exists.
///
/// While unpaired, `cloud` stays nil and the verb reports `not_implemented`
/// rather than flipping a local flag nothing would act on.
public final class CloudShareArm: @unchecked Sendable {
    private let lock = NSLock()
    private var cloud: RemoteAgentCloud?

    public init() {}

    /// Called by the daemon once the cloud arm is constructed (paired only).
    public func attach(_ cloud: RemoteAgentCloud) {
        lock.lock(); defer { lock.unlock() }
        self.cloud = cloud
    }

    private func current() -> RemoteAgentCloud? {
        lock.lock(); defer { lock.unlock() }
        return cloud
    }

    /// Synchronous bridge for `LocalSessionServer.Hooks.setWrappedSessionCloudShared`.
    /// Returns (ok, error). Blocks the calling thread until the actor call
    /// completes — see the type doc for why that's the right trade here.
    public func setShared(_ sessionId: String, _ shared: Bool) -> (Bool, String) {
        guard let cloud = current() else {
            return (false, "cloud sharing is unavailable — this Mac is not paired with an account")
        }
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: (Bool, String) = (false, "cloud share bridge: no result")
            func set(_ v: (Bool, String)) { lock.lock(); value = v; lock.unlock() }
            func get() -> (Bool, String) { lock.lock(); defer { lock.unlock() }; return value }
        }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let r = shared
                ? await cloud.shareAttachedSession(sessionId: sessionId)
                : await cloud.unshareAttachedSession(sessionId: sessionId)
            box.set((r.ok, r.error))
            sem.signal()
        }
        // Bounded so a wedged network can't pin a connection thread forever.
        if sem.wait(timeout: .now() + 20) == .timedOut {
            // The detached Task is NOT cancelled by our giving up, and it isn't
            // cancellation-aware anyway — a slow `register_session` can still
            // land and flip the opt-in ON minutes later, while we've already
            // told the user it failed and their toggle reads OFF. That is the
            // exact shape of a silent privacy leak (review: agy).
            //
            // So make the truth match what we reported: force the session back
            // OFF. Either order converges — if the late share flips it on first,
            // this turns it off; if this runs first, it bumps the opt-in
            // sequence and the late share resumes into its superseded check and
            // declines to flip at all.
            if shared {
                Task.detached { _ = await cloud.unshareAttachedSession(sessionId: sessionId) }
            }
            return (false, "timed out talking to the cloud — try again")
        }
        return box.get()
    }
}
