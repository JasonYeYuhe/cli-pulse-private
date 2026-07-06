import XCTest
@testable import RootHelperCore

/// The dead-man's-switch timing contract must be proven BEFORE any fan write
/// exists (that's the whole point of building it in M2). Fake clock; no timers.
final class DeadMansSwitchTests: XCTestCase {

    final class Clock { var t = 1000.0; func now() -> Double { t } }

    func testDoesNotLapseWithinTimeout() {
        let clock = Clock()
        var lapses = 0
        let dm = DeadMansSwitch(timeoutSeconds: 5, now: clock.now, onLapse: { lapses += 1 })
        clock.t += 3
        XCTAssertFalse(dm.check())
        XCTAssertEqual(lapses, 0)
    }

    func testLapsesPastTimeoutAndFiresOnce() {
        let clock = Clock()
        var lapses = 0
        let dm = DeadMansSwitch(timeoutSeconds: 5, now: clock.now, onLapse: { lapses += 1 })
        clock.t += 6
        XCTAssertTrue(dm.check())
        // A tight poll loop must NOT re-fire the revert.
        XCTAssertTrue(dm.check())
        XCTAssertTrue(dm.check())
        XCTAssertEqual(lapses, 1, "onLapse must fire exactly once per lapse")
    }

    func testBeatReArmsAndPreventsLapse() {
        let clock = Clock()
        var lapses = 0
        let dm = DeadMansSwitch(timeoutSeconds: 5, now: clock.now, onLapse: { lapses += 1 })
        clock.t += 4; dm.beat()          // heartbeat keeps it alive
        clock.t += 4                     // 4s since the beat → still under 5
        XCTAssertFalse(dm.check())
        XCTAssertEqual(lapses, 0)
    }

    func testReArmsAfterLapseSoASecondSilenceFiresAgain() {
        let clock = Clock()
        var lapses = 0
        let dm = DeadMansSwitch(timeoutSeconds: 5, now: clock.now, onLapse: { lapses += 1 })
        clock.t += 6; XCTAssertTrue(dm.check())      // lapse #1
        dm.beat()                                    // recovered
        clock.t += 6; XCTAssertTrue(dm.check())      // lapse #2 fires again
        XCTAssertEqual(lapses, 2)
    }

    func testSilenceSeconds() {
        let clock = Clock()
        let dm = DeadMansSwitch(timeoutSeconds: 5, now: clock.now, onLapse: {})
        clock.t += 2.5
        XCTAssertEqual(dm.silenceSeconds(), 2.5, accuracy: 0.0001)
    }
}
