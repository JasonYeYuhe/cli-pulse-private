import XCTest
@testable import RootHelperCore

/// The fan controller is what stands between "a boost feature" and "a stuck fan
/// cooks the machine". Since the firmware won't self-revert (M0), every fail-safe
/// layer is proven here with a fake SMC + fake clock — no hardware.
final class FanControllerTests: XCTestCase {

    final class FakeSMC: FanSMC {
        var fans: [Int: FanState]
        private(set) var writes: [(index: Int, kind: String, value: Double)] = []
        var failReadIndices: Set<Int> = []
        // Write-failure injection (safety-review fix): a failing write returns
        // false and does NOT mutate the fan's state — exactly what a transient
        // SMC/IOKit error does on real hardware.
        var failModeWriteIndices: Set<Int> = []
        var failTargetWriteIndices: Set<Int> = []
        init(_ fans: [FanState]) { self.fans = Dictionary(uniqueKeysWithValues: fans.map { ($0.index, $0) }) }
        func clearWrites() { writes.removeAll() }
        func fanCount() -> Int { fans.count }
        func readFan(_ i: Int) -> FanState? { failReadIndices.contains(i) ? nil : fans[i] }
        func writeManualMode(_ i: Int, manual: Bool) -> Bool {
            if failModeWriteIndices.contains(i) { return false }   // no state mutation on failure
            writes.append((i, "mode", manual ? 1 : 0))
            if let f = fans[i] {
                fans[i] = FanState(index: i, minRPM: f.minRPM, maxRPM: f.maxRPM,
                                   actualRPM: f.actualRPM, targetRPM: f.targetRPM, mode: manual ? 1 : 0)
            }
            return true
        }
        func writeTargetRPM(_ i: Int, rpm: Double) -> Bool {
            if failTargetWriteIndices.contains(i) { return false }
            writes.append((i, "target", rpm))
            if let f = fans[i] {
                fans[i] = FanState(index: i, minRPM: f.minRPM, maxRPM: f.maxRPM,
                                   actualRPM: f.actualRPM, targetRPM: rpm, mode: f.mode)
            }
            return true
        }
        var modeWritesToAuto: Int { writes.filter { $0.kind == "mode" && $0.value == 0 }.count }
        var targetWrites: [(index: Int, value: Double)] { writes.filter { $0.kind == "target" }.map { ($0.index, $0.value) } }
    }

    final class Clock { var t = 1000.0; func now() -> Double { t } }

    private func twoFans(mode: Int = 0) -> FakeSMC {
        FakeSMC([
            FanState(index: 0, minRPM: 1499, maxRPM: 4296, actualRPM: 1520, targetRPM: 1520, mode: mode),
            FanState(index: 1, minRPM: 1499, maxRPM: 4744, actualRPM: 1640, targetRPM: 1640, mode: mode),
        ])
    }

    // Layer 1 — the most important line: a relaunched daemon clears stuck manual.
    func testRevertsEveryFanToAutoOnInit() {
        let smc = twoFans(mode: 1)   // both stuck in manual (as if predecessor was killed)
        _ = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: true)
        XCTAssertEqual(smc.modeWritesToAuto, 2, "init must revert BOTH fans to auto")
        XCTAssertEqual(smc.fans[0]?.mode, 0)
        XCTAssertEqual(smc.fans[1]?.mode, 0)
    }

    // Layer 2 — boost-only clamp.
    func testApplyBoostClampsBoostOnly() {
        let smc = twoFans(); let clock = Clock()
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: clock.now, revertOnInit: false)
        // Normal boost within range → applied as-is.
        let r1 = fc.applyBoost(targetRPM: 3000)
        XCTAssertTrue(r1.ok)
        XCTAssertEqual(r1.appliedTargets[0], 3000)
        XCTAssertEqual(r1.appliedTargets[1], 3000)
        // Below the auto floor → raised UP to the floor (never reduce cooling).
        let r2 = fc.applyBoost(targetRPM: 800)
        XCTAssertEqual(r2.appliedTargets[0], 1520)   // fan0 auto floor
        XCTAssertEqual(r2.appliedTargets[1], 1640)   // fan1 auto floor
        // Above max → clamped to each fan's own max.
        let r3 = fc.applyBoost(targetRPM: 9000)
        XCTAssertEqual(r3.appliedTargets[0], 4296)
        XCTAssertEqual(r3.appliedTargets[1], 4744)
    }

    func testFullBlastAppliesMaxWithNoResidual() {
        let smc = twoFans(); let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: false)
        let r = fc.applyBoost(targetRPM: 4744)   // >= every fan's max → full blast
        XCTAssertEqual(r.appliedTargets[0], 4296)
        XCTAssertEqual(r.appliedTargets[1], 4744)
    }

    // No half-applied boost if any fan is unreadable — refuse before writing.
    func testApplyBoostRefusesAndDoesNotHalfApplyOnUnreadableFan() {
        let smc = twoFans(); smc.failReadIndices = [1]
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: false)
        smc.clearWrites()
        let r = fc.applyBoost(targetRPM: 3000)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.appliedTargets.isEmpty)
        XCTAssertTrue(smc.targetWrites.isEmpty, "must NOT write any target when a fan is unreadable")
        XCTAssertFalse(fc.isBoostActive)
    }

    // Layer 3 — heartbeat-gated hold: lapse reverts to auto, once.
    func testHeartbeatLapseRevertsToAutoExactlyOnce() {
        let smc = twoFans(); let clock = Clock()
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: clock.now, revertOnInit: false)
        fc.applyBoost(targetRPM: 3000)
        smc.clearWrites()
        XCTAssertFalse(fc.tick())        // within timeout, no revert
        clock.t += 9                     // heartbeat lapses
        XCTAssertTrue(fc.tick(), "lapsed heartbeat must revert to auto")
        XCTAssertEqual(smc.modeWritesToAuto, 2)
        XCTAssertFalse(fc.isBoostActive)
        XCTAssertFalse(fc.tick(), "revert fires exactly once per lapse")
        XCTAssertFalse(fc.tick())
    }

    func testHeartbeatReArmsAndHoldsBoost() {
        let smc = twoFans(); let clock = Clock()
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: clock.now, revertOnInit: false)
        fc.applyBoost(targetRPM: 3000)
        clock.t += 5; fc.heartbeat()     // client still alive
        clock.t += 5                     // 5s since last beat, < 8 timeout
        XCTAssertFalse(fc.tick())
        XCTAssertTrue(fc.isBoostActive)
    }

    // Layer 4 — explicit revert.
    func testRevertToAutoWritesModeZeroToEveryFan() {
        let smc = twoFans(); let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: false)
        fc.applyBoost(targetRPM: 3000)
        smc.clearWrites()
        let r = fc.revertToAuto()
        XCTAssertTrue(r.ok)
        XCTAssertEqual(smc.modeWritesToAuto, 2)
        XCTAssertFalse(fc.isBoostActive)
    }

    func testNoFansIsHandled() {
        let smc = FakeSMC([]); let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now)
        XCTAssertFalse(fc.applyBoost(targetRPM: 3000).ok)
        XCTAssertFalse(fc.tick())
    }

    // ── Write-failure fail-safe (safety-review defects A/B/C/E) ──────────────

    // Defect A: a target-write failure must NOT leave a fan stuck in manual — the
    // whole apply reverts to auto and reports failure.
    func testApplyBoostRevertsToAutoWhenAnyTargetWriteFails() {
        let smc = twoFans(); smc.failTargetWriteIndices = [1]
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: false)
        let r = fc.applyBoost(targetRPM: 3000)
        XCTAssertFalse(r.ok, "must report failure, not the pre-fix ok:true")
        XCTAssertFalse(fc.isBoostActive, "must not hold a boost after a failed write")
        // Every fan must end in auto (mode 0) — never stranded in manual.
        XCTAssertEqual(smc.fans[0]?.mode, 0)
        XCTAssertEqual(smc.fans[1]?.mode, 0)
    }

    func testApplyBoostRevertsWhenModeWriteFails() {
        let smc = twoFans(); smc.failModeWriteIndices = [0]
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: false)
        let r = fc.applyBoost(targetRPM: 3000)
        XCTAssertFalse(r.ok)
        XCTAssertFalse(fc.isBoostActive)
        XCTAssertEqual(smc.fans[0]?.mode, 0)
        XCTAssertEqual(smc.fans[1]?.mode, 0)
    }

    // Defect B: a FAILED dead-man revert must stay armed and RETRY on the next
    // tick — never abandon the fan in manual.
    func testTickRetriesRevertUntilWriteSucceeds() {
        let smc = twoFans(); let clock = Clock()
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: clock.now, revertOnInit: false)
        fc.applyBoost(targetRPM: 3000)
        smc.failModeWriteIndices = [1]      // revert of fan 1 will fail
        clock.t += 9                        // heartbeat lapses
        XCTAssertFalse(fc.tick(), "revert failed → tick reports not-yet-reverted")
        XCTAssertTrue(fc.isBoostActive, "must stay armed so it retries")
        smc.failModeWriteIndices = []       // transient error clears
        XCTAssertTrue(fc.tick(), "next tick retries and succeeds")
        XCTAssertFalse(fc.isBoostActive)
        XCTAssertEqual(smc.fans[0]?.mode, 0)
        XCTAssertEqual(smc.fans[1]?.mode, 0)
    }

    // Defect B (explicit revert variant): a failed revertToAuto stays armed.
    func testRevertToAutoFailureKeepsBoostArmed() {
        let smc = twoFans()
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: Clock().now, revertOnInit: false)
        fc.applyBoost(targetRPM: 3000)
        smc.failModeWriteIndices = [0]
        let r = fc.revertToAuto()
        XCTAssertFalse(r.ok)
        XCTAssertTrue(fc.isBoostActive, "failed revert must stay armed for the dead-man to retry")
    }

    // Defect C: concurrent applyBoost + revertToAuto on the shared controller must
    // not corrupt state or crash (all state + SMC access is now under one lock).
    // Exercises the lock under contention; a data race would trip TSan / crash.
    func testConcurrentBoostAndRevertIsRaceFree() {
        let smc = twoFans()
        let fc = FanController(smc: smc, heartbeatTimeout: 8, now: { 1000 }, revertOnInit: false)
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter(); DispatchQueue.global().async { fc.applyBoost(targetRPM: 3000); group.leave() }
            group.enter(); DispatchQueue.global().async { _ = fc.revertToAuto(); group.leave() }
            group.enter(); DispatchQueue.global().async { _ = fc.tick(); group.leave() }
            group.enter(); DispatchQueue.global().async { _ = fc.snapshot(); group.leave() }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        // Final explicit revert leaves a consistent, un-boosted, all-auto state.
        XCTAssertTrue(fc.revertToAuto().ok)
        XCTAssertFalse(fc.isBoostActive)
        XCTAssertEqual(smc.fans[0]?.mode, 0)
        XCTAssertEqual(smc.fans[1]?.mode, 0)
    }
}
