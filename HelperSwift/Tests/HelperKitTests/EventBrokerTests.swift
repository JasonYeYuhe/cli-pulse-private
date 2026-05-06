import XCTest
@testable import HelperKit
import Foundation

/// Swift port of `helper/test_local_events.py`. Pins the broker
/// invariants the macOS app's streaming subscription depends on.
final class EventBrokerTests: XCTestCase {

    func testSubscribeReceivesScopedEvents() {
        let broker = EventBroker()
        var captured: [[String: Any]] = []
        let lock = NSLock()
        _ = broker.subscribe(sessionFilter: "S") { ev in
            lock.lock(); defer { lock.unlock() }
            captured.append(ev)
        }
        broker.publish([
            "event": "output_delta",
            "session_id": "S",
            "payload": "hello",
        ])
        broker.publish([
            "event": "output_delta",
            "session_id": "OTHER",
            "payload": "should not arrive",
        ])
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(captured.count, 1)
        XCTAssertEqual(captured.first?["session_id"] as? String, "S")
    }

    func testNilFilterReceivesAllScopedEvents() {
        let broker = EventBroker()
        var captured: [[String: Any]] = []
        let lock = NSLock()
        _ = broker.subscribe(sessionFilter: nil) { ev in
            lock.lock(); defer { lock.unlock() }
            captured.append(ev)
        }
        broker.publish([
            "event": "output_delta",
            "session_id": "A",
            "payload": "x",
        ])
        broker.publish([
            "event": "output_delta",
            "session_id": "B",
            "payload": "y",
        ])
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(captured.count, 2)
    }

    func testPublishToAllReachesEveryone() {
        let broker = EventBroker()
        var aCount = 0, bCount = 0
        let lock = NSLock()
        _ = broker.subscribe(sessionFilter: "A") { _ in
            lock.lock(); aCount += 1; lock.unlock()
        }
        _ = broker.subscribe(sessionFilter: "B") { _ in
            lock.lock(); bCount += 1; lock.unlock()
        }
        broker.publishToAll(["event": "heartbeat", "ts": 1.0])
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(aCount, 1)
        XCTAssertEqual(bCount, 1)
    }

    func testUnsubscribeStopsDelivery() {
        let broker = EventBroker()
        var count = 0
        let lock = NSLock()
        let sub = broker.subscribe(sessionFilter: nil) { _ in
            lock.lock(); count += 1; lock.unlock()
        }
        broker.publish(["event": "x", "session_id": "S"])
        broker.unsubscribe(sub)
        broker.publish(["event": "x", "session_id": "S"])
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(count, 1, "publish AFTER unsubscribe must not deliver")
    }

    func testSubscriberCountReflectsState() {
        let broker = EventBroker()
        XCTAssertEqual(broker.subscriberCount(), 0)
        let s1 = broker.subscribe(sessionFilter: nil) { _ in }
        let s2 = broker.subscribe(sessionFilter: "X") { _ in }
        XCTAssertEqual(broker.subscriberCount(), 2)
        broker.unsubscribe(s1)
        broker.unsubscribe(s2)
        XCTAssertEqual(broker.subscriberCount(), 0)
    }
}
