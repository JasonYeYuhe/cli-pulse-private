import XCTest
@testable import RootHelperCore

/// The command guards are pure and reachable only in M3/M4, but they're the
/// safety floor for a root process writing SMC / signalling arbitrary pids, so
/// they're proven now.
final class CommandGuardTests: XCTestCase {

    // MARK: fan clamp (M3)

    func testClampsWithinRange() {
        XCTAssertEqual(try! CommandGuard.clampFanTarget(requestedRPM: 3000, minRPM: 1499, maxRPM: 4296).get(), 3000)
    }
    func testClampsBelowMinUpToMin() {
        XCTAssertEqual(try! CommandGuard.clampFanTarget(requestedRPM: 500, minRPM: 1499, maxRPM: 4296).get(), 1499)
    }
    func testClampsAboveMaxDownToMax() {
        XCTAssertEqual(try! CommandGuard.clampFanTarget(requestedRPM: 9000, minRPM: 1499, maxRPM: 4296).get(), 4296)
    }
    func testRefusesWhenRangeUnavailable() {
        // No known floor → refuse, never guess (this is how you cook a machine).
        XCTAssertEqual(CommandGuard.clampFanTarget(requestedRPM: 3000, minRPM: nil, maxRPM: 4296),
                       .failure(.rangeUnavailable))
        XCTAssertEqual(CommandGuard.clampFanTarget(requestedRPM: 3000, minRPM: 1499, maxRPM: nil),
                       .failure(.rangeUnavailable))
    }
    func testRefusesInvalidRange() {
        XCTAssertEqual(CommandGuard.clampFanTarget(requestedRPM: 3000, minRPM: 4000, maxRPM: 1000),
                       .failure(.invalidRange))
        XCTAssertEqual(CommandGuard.clampFanTarget(requestedRPM: 3000, minRPM: 0, maxRPM: 0),
                       .failure(.invalidRange))
    }
    func testValidFanModes() {
        XCTAssertTrue(CommandGuard.isValidFanMode(0))
        XCTAssertTrue(CommandGuard.isValidFanMode(1))
        XCTAssertFalse(CommandGuard.isValidFanMode(2))
        XCTAssertFalse(CommandGuard.isValidFanMode(-1))
    }

    // MARK: boost-only clamp (M3 core safety rule)

    func testBoostClampRaisesBelowAutoUpToAutoFloor() {
        // The safety-critical case: a below-auto request must NEVER reduce
        // cooling — it's raised up to the current auto floor.
        XCTAssertEqual(try! CommandGuard.clampBoostTarget(requestedRPM: 800, autoFloorRPM: 1520,
                                                          minRPM: 1499, maxRPM: 4296).get(), 1520)
    }
    func testBoostClampKeepsInRangeRequest() {
        XCTAssertEqual(try! CommandGuard.clampBoostTarget(requestedRPM: 3000, autoFloorRPM: 1520,
                                                          minRPM: 1499, maxRPM: 4296).get(), 3000)
    }
    func testBoostClampCapsAtMax() {
        XCTAssertEqual(try! CommandGuard.clampBoostTarget(requestedRPM: 9000, autoFloorRPM: 1520,
                                                          minRPM: 1499, maxRPM: 4296).get(), 4296)
    }
    func testBoostClampFloorItselfCappedAtMax() {
        // A bogus auto reading above max must not push the target past max.
        XCTAssertEqual(try! CommandGuard.clampBoostTarget(requestedRPM: 2000, autoFloorRPM: 99999,
                                                          minRPM: 1499, maxRPM: 4296).get(), 4296)
    }
    func testBoostClampRefusesUnknownRangeOrFloor() {
        XCTAssertEqual(CommandGuard.clampBoostTarget(requestedRPM: 3000, autoFloorRPM: nil,
                                                     minRPM: 1499, maxRPM: 4296), .failure(.rangeUnavailable))
        XCTAssertEqual(CommandGuard.clampBoostTarget(requestedRPM: 3000, autoFloorRPM: 1520,
                                                     minRPM: nil, maxRPM: 4296), .failure(.rangeUnavailable))
    }

    // MARK: kill deny-list (M4)

    func testDenyListRefusesCriticalProcesses() {
        XCTAssertFalse(CommandGuard.isKillablePid(1, comm: "launchd"))
        XCTAssertFalse(CommandGuard.isKillablePid(0, comm: "kernel_task"))
        XCTAssertFalse(CommandGuard.isKillablePid(50, comm: "WindowServer"))
        XCTAssertFalse(CommandGuard.isKillablePid(60, comm: "/usr/sbin/loginwindow"))  // basename matched
        XCTAssertFalse(CommandGuard.isKillablePid(70, comm: "machine-root-helper"))     // never signal self
    }
    func testDenyListAllowsOrdinaryProcess() {
        XCTAssertTrue(CommandGuard.isKillablePid(4321, comm: "python3"))
        XCTAssertTrue(CommandGuard.isKillablePid(4322, comm: "/Applications/Foo.app/Contents/MacOS/Foo"))
    }
}
