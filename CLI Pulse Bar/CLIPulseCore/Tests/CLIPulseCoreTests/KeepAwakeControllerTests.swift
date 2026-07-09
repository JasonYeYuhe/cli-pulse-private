#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.42 Keep Awake — the IOPM-assertion wrapper, driven with injected
/// create/release closures + a mutable monotonic clock (no real IOKit calls).
/// The real-time TTL task is NOT exercised here (it sleeps wall-clock); the
/// clamp + arming math is verified via `remainingSeconds`, and the executor
/// integration is covered in RemoteMachineExecutorTests.
///
/// Every `await` is pulled into a `let` before XCTAssert (strict-concurrency CI).
@MainActor
final class KeepAwakeControllerTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var clock = 10_000.0
        var nextID: UInt32 = 7
        var createReasons: [String] = []
        var released: [UInt32] = []
        var failCreate = false
    }

    private func makeController(_ box: Box) -> KeepAwakeController {
        KeepAwakeController(
            createAssertion: { reason in
                box.createReasons.append(reason)
                return box.failCreate ? nil : box.nextID
            },
            releaseAssertion: { box.released.append($0) },
            now: { box.clock }
        )
    }

    func test_enable_creates_assertion_and_disable_releases_it() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertFalse(ka.isActive)
        XCTAssertTrue(ka.enable(ttlSeconds: nil))
        XCTAssertTrue(ka.isActive)
        XCTAssertEqual(box.createReasons.count, 1)
        XCTAssertNil(ka.remainingSeconds)          // indefinite
        XCTAssertNil(ka.endsAt)
        ka.disable()
        XCTAssertFalse(ka.isActive)
        XCTAssertEqual(box.released, [7])
    }

    func test_enable_failure_stays_inactive() {
        let box = Box(); box.failCreate = true
        let ka = makeController(box)
        XCTAssertFalse(ka.enable(ttlSeconds: 600))
        XCTAssertFalse(ka.isActive)
        XCTAssertNil(ka.remainingSeconds)
    }

    func test_reenable_reuses_live_assertion_and_rearms_ttl() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: 600))
        let firstRemaining = ka.remainingSeconds
        XCTAssertEqual(firstRemaining, 600)
        box.clock += 100
        XCTAssertTrue(ka.enable(ttlSeconds: 600))  // re-arm, same assertion
        XCTAssertEqual(box.createReasons.count, 1) // NOT a second create
        let rearmed = ka.remainingSeconds
        XCTAssertEqual(rearmed, 600)               // fresh window from re-enable
        ka.disable()
        XCTAssertEqual(box.released.count, 1)
    }

    func test_ttl_clamped_to_floor_and_cap() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: 5))            // below 60s floor
        XCTAssertEqual(ka.remainingSeconds, 60)
        XCTAssertTrue(ka.enable(ttlSeconds: 9_999_999))    // above 24h cap
        XCTAssertEqual(ka.remainingSeconds, 86_400)
        ka.disable()
    }

    func test_switching_to_indefinite_clears_countdown() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: 600))
        XCTAssertNotNil(ka.remainingSeconds)
        XCTAssertTrue(ka.enable(ttlSeconds: nil))          // re-enable indefinite
        XCTAssertNil(ka.remainingSeconds)
        XCTAssertNil(ka.endsAt)
        ka.disable()
    }

    func test_disable_is_idempotent() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: nil))
        ka.disable()
        ka.disable()                                        // second call: no double release
        XCTAssertEqual(box.released, [7])
        XCTAssertFalse(ka.isActive)
    }

    func test_protocol_seam_setKeepAwake_maps_on_off() async {
        let box = Box()
        let ka = makeController(box)
        let onOK = await ka.setKeepAwake(true, ttlSeconds: 120)
        XCTAssertTrue(onOK)
        let active = await ka.isKeepAwakeActive()
        XCTAssertTrue(active)
        let offOK = await ka.setKeepAwake(false, ttlSeconds: nil)
        XCTAssertTrue(offOK)
        let inactive = await ka.isKeepAwakeActive()
        XCTAssertFalse(inactive)
    }
}
#endif
