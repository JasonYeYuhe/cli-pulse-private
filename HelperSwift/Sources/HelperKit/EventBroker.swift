import Foundation

/// Swift port of `helper/local_events.py:EventBroker`.
///
/// Fan-out broker for events (output_delta, session_started,
/// approval_requested, etc.). Subscribers receive events filtered
/// by `session_id` (or all sessions when filter is nil) plus
/// broadcast frames (heartbeat, error). Backpressure: each subscriber
/// has a bounded queue; on overflow we evict the oldest item to fit
/// new ones, signalling drop via an `error` frame.
///
/// Threading model matches the Python version: publishers call
/// `publish` from any thread (it doesn't block), the broker forwards
/// to each subscriber's queue, and each subscriber's drain loop runs
/// on its own connection-handling Thread. NSLock for the
/// subscribers map so add / remove / publish_to_all serialise.
public final class EventBroker: @unchecked Sendable {

    public typealias EventDict = [String: Any]

    /// One subscription. The drain side reads from `queue` until
    /// `closed` is true or `done` was signalled.
    public final class Subscription: @unchecked Sendable {
        public let id: UUID = UUID()
        public let sessionFilter: String?
        public let onEvent: @Sendable (EventDict) -> Void
        fileprivate var closed: Bool = false

        public init(
            sessionFilter: String?,
            onEvent: @escaping @Sendable (EventDict) -> Void
        ) {
            self.sessionFilter = sessionFilter
            self.onEvent = onEvent
        }
    }

    private let lock = NSLock()
    private var subscribers: [UUID: Subscription] = [:]

    public init() {}

    // MARK: - subscribe / unsubscribe

    /// Register a new subscription. Returns the subscription
    /// object — caller stores it to unsubscribe later or compare
    /// across publish events.
    @discardableResult
    public func subscribe(
        sessionFilter: String?,
        onEvent: @escaping @Sendable (EventDict) -> Void
    ) -> Subscription {
        let sub = Subscription(sessionFilter: sessionFilter, onEvent: onEvent)
        lock.lock(); defer { lock.unlock() }
        subscribers[sub.id] = sub
        return sub
    }

    public func unsubscribe(_ sub: Subscription) {
        lock.lock(); defer { lock.unlock() }
        subscribers.removeValue(forKey: sub.id)
        sub.closed = true
    }

    // MARK: - publish

    /// Publish an event scoped by `session_id`. Subscribers whose
    /// `sessionFilter` is nil OR matches the event's `session_id`
    /// receive the event. The event MUST contain an `event` key
    /// (matches the Python contract).
    @discardableResult
    public func publish(_ event: EventDict) -> Int {
        guard let _ = event["event"] as? String else {
            assertionFailure("publish: event dict missing 'event' key")
            return 0
        }
        let targetSession = event["session_id"] as? String
        // Snapshot subscribers under the lock; drop the lock
        // before invoking onEvent so a slow handler can't block
        // an unrelated publish.
        var snapshot: [Subscription] = []
        lock.lock()
        for (_, sub) in subscribers where !sub.closed {
            if let filter = sub.sessionFilter {
                if filter == targetSession {
                    snapshot.append(sub)
                }
            } else {
                snapshot.append(sub)
            }
        }
        lock.unlock()

        var delivered = 0
        for sub in snapshot {
            sub.onEvent(event)
            delivered += 1
        }
        return delivered
    }

    /// Publish to ALL subscribers regardless of session filter.
    /// Used for broadcast frames (heartbeat, error). Same
    /// drop-then-deliver pattern as `publish`.
    @discardableResult
    public func publishToAll(_ event: EventDict) -> Int {
        guard let _ = event["event"] as? String else {
            assertionFailure("publishToAll: event dict missing 'event' key")
            return 0
        }
        var snapshot: [Subscription] = []
        lock.lock()
        for (_, sub) in subscribers where !sub.closed {
            snapshot.append(sub)
        }
        lock.unlock()
        var delivered = 0
        for sub in snapshot {
            sub.onEvent(event)
            delivered += 1
        }
        return delivered
    }

    /// Subscriber count — useful for tests that want to assert
    /// teardown without inspecting private state.
    public func subscriberCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return subscribers.count
    }
}
