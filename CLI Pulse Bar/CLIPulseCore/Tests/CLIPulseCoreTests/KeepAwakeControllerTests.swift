#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.42 Keep Awake — the IOPM-assertion wrapper, driven with injected
/// create/release closures + a mutable monotonic clock (no real IOKit calls).
/// The real-time TTL task is NOT exercised here (it sleeps wall-clock); the
/// clamp + arming math is verified via `remainingSeconds`, and the executor
/// integration is covered in RemoteMachineExecutorTests.
///
/// v1.42.1 adds the LID-CLOSED option: a SECOND PreventSystemSleep assertion
/// (AC-only at the OS level; here we only verify the create/release plumbing
/// and graceful degrade).
///
/// Every `await` is pulled into a `let` before XCTAssert (strict-concurrency CI).
@MainActor
final class KeepAwakeControllerTests: XCTestCase {

    private final class Box: @unchecked Sendable {
        var clock = 10_000.0
        var nextID: UInt32 = 7
        var created: [(reason: String, type: String)] = []
        var released: [UInt32] = []
        /// Assertion types that should FAIL to create (graceful-degrade tests).
        var failTypes: Set<String> = []
    }

    private func makeController(_ box: Box) -> KeepAwakeController {
        KeepAwakeController(
            createAssertion: { reason, type in
                box.created.append((reason, type))
                if box.failTypes.contains(type) { return nil }
                box.nextID += 1
                return box.nextID
            },
            releaseAssertion: { box.released.append($0) },
            now: { box.clock }
        )
    }

    private var idle: String { KeepAwakeController.idleAssertionType }
    private var system: String { KeepAwakeController.systemAssertionType }

    func test_enable_creates_idle_assertion_and_disable_releases_it() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertFalse(ka.isActive)
        XCTAssertTrue(ka.enable(ttlSeconds: nil))
        XCTAssertTrue(ka.isActive)
        XCTAssertFalse(ka.lidSleepPrevented)
        XCTAssertEqual(box.created.map(\.type), [idle])
        XCTAssertNil(ka.remainingSeconds)          // indefinite
        XCTAssertNil(ka.endsAt)
        ka.disable()
        XCTAssertFalse(ka.isActive)
        XCTAssertEqual(box.released, [8])
    }

    func test_enable_failure_stays_inactive() {
        let box = Box(); box.failTypes = [idle]
        let ka = makeController(box)
        XCTAssertFalse(ka.enable(ttlSeconds: 600))
        XCTAssertFalse(ka.isActive)
        XCTAssertNil(ka.remainingSeconds)
    }

    func test_reenable_reuses_live_assertion_and_rearms_ttl() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: 600))
        XCTAssertEqual(ka.remainingSeconds, 600)
        box.clock += 100
        XCTAssertTrue(ka.enable(ttlSeconds: 600))  // re-arm, same assertion
        XCTAssertEqual(box.created.count, 1)       // NOT a second create
        XCTAssertEqual(ka.remainingSeconds, 600)   // fresh window from re-enable
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
        XCTAssertEqual(box.released, [8])
        XCTAssertFalse(ka.isActive)
    }

    // MARK: - Lid-closed hold (v1.42.1)

    func test_enable_with_lid_holds_both_assertions_and_disable_releases_both() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: nil, preventLidSleep: true))
        XCTAssertTrue(ka.isActive)
        XCTAssertTrue(ka.lidSleepPrevented)
        XCTAssertEqual(box.created.map(\.type), [idle, system])
        ka.disable()
        XCTAssertFalse(ka.isActive)
        XCTAssertFalse(ka.lidSleepPrevented)
        XCTAssertEqual(Set(box.released), [8, 9])          // both released
    }

    func test_setPreventLidSleep_live_adds_and_removes_system_assertion() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: nil))          // no lid
        XCTAssertFalse(ka.lidSleepPrevented)
        ka.setPreventLidSleep(true)                        // live add
        XCTAssertTrue(ka.lidSleepPrevented)
        XCTAssertEqual(box.created.map(\.type), [idle, system])
        ka.setPreventLidSleep(false)                       // live remove
        XCTAssertFalse(ka.lidSleepPrevented)
        XCTAssertEqual(box.released, [9])                  // only the system one
        XCTAssertTrue(ka.isActive)                         // base hold untouched
        ka.disable()
    }

    func test_setPreventLidSleep_noop_when_inactive() {
        let box = Box()
        let ka = makeController(box)
        ka.setPreventLidSleep(true)
        XCTAssertFalse(ka.lidSleepPrevented)
        XCTAssertTrue(box.created.isEmpty)
    }

    func test_lid_create_failure_degrades_gracefully() {
        let box = Box(); box.failTypes = [system]
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: nil, preventLidSleep: true))
        XCTAssertTrue(ka.isActive)                         // base hold works
        XCTAssertFalse(ka.lidSleepPrevented)               // UI tells the truth
        ka.disable()
        XCTAssertEqual(box.released, [8])                  // only the idle one existed
    }

    func test_reenable_can_change_lid_mode() {
        let box = Box()
        let ka = makeController(box)
        XCTAssertTrue(ka.enable(ttlSeconds: nil, preventLidSleep: true))
        XCTAssertTrue(ka.lidSleepPrevented)
        XCTAssertTrue(ka.enable(ttlSeconds: nil, preventLidSleep: false))  // remote re-enable w/o lid
        XCTAssertFalse(ka.lidSleepPrevented)
        XCTAssertEqual(box.released, [9])                  // system assertion dropped
        XCTAssertTrue(ka.isActive)
        ka.disable()
    }

    func test_protocol_seam_setKeepAwake_maps_on_off_and_lid() async {
        let box = Box()
        let ka = makeController(box)
        let onOK = await ka.setKeepAwake(true, ttlSeconds: 120, preventLidSleep: true)
        XCTAssertTrue(onOK)
        let active = await ka.isKeepAwakeActive()
        XCTAssertTrue(active)
        let lid = await ka.isLidSleepPrevented()
        XCTAssertTrue(lid)
        let offOK = await ka.setKeepAwake(false, ttlSeconds: nil, preventLidSleep: false)
        XCTAssertTrue(offOK)
        let inactive = await ka.isKeepAwakeActive()
        XCTAssertFalse(inactive)
        let lidOff = await ka.isLidSleepPrevented()
        XCTAssertFalse(lidOff)
    }
}
#endif
