#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.41 "Mobile Machine" — the Mac executor that turns cloud fan/LPM REQUESTS
/// into local FanControlClient calls. Driven synchronously via `tick()` with a
/// fake fan daemon + fake relay + a mutable clock (no real timers / XPC / UDS),
/// mirroring the root daemon's DeadMansSwitch test pattern. Covers the
/// TTL/heartbeat/revert matrix the plan calls out: opt-in gating, daemon-vanish,
/// disable-while-boosting, TTL expiry, phone-vanish (empty pull), typed acks.
final class RemoteMachineExecutorTests: XCTestCase {

    // MARK: - fakes

    private final class Box: @unchecked Sendable {
        var clock = 1_000.0
        var enabled = true
    }

    private struct FakeError: Error {}

    private actor FakeFan: FanControlling {
        var available = true
        var boostOK = true
        var boostError: String?
        private(set) var boostCalls: [Int] = []
        private(set) var revertCount = 0
        private(set) var lpmCalls: [Bool] = []

        func setAvailable(_ b: Bool) { available = b }
        func setBoost(ok: Bool, error: String?) { boostOK = ok; boostError = error }

        func isAvailable() async -> Bool { available }
        func startBoost(targetRPM: Int) async -> (ok: Bool, error: String?) {
            boostCalls.append(targetRPM); return (boostOK, boostError)
        }
        func revert() async -> Bool { revertCount += 1; return true }
        func setLowPowerMode(_ on: Bool) async -> Bool { lpmCalls.append(on); return true }
    }

    private actor FakeRelay: MachineControlRelaying {
        var pullThrows = false
        private var queued: [RemoteMachineCommand] = []
        private(set) var completions: [(id: String, status: String, error: String?)] = []
        private(set) var reports: [RemoteMachineControlState] = []

        func enqueue(_ c: RemoteMachineCommand) { queued.append(c) }
        func setPullThrows(_ b: Bool) { pullThrows = b }

        func pullMachineCommands() async throws -> [RemoteMachineCommand] {
            if pullThrows { throw FakeError() }
            let out = queued; queued = []; return out
        }
        func completeMachineCommand(id: String, status: String, error: String?) async throws {
            completions.append((id, status, error))
        }
        func reportMachineControlState(_ state: RemoteMachineControlState) async throws {
            reports.append(state)
        }
    }

    private func makeExecutor(_ box: Box, fan: FakeFan, relay: FakeRelay) -> RemoteMachineExecutor {
        RemoteMachineExecutor(
            fan: fan, relay: relay,
            isEnabled: { box.enabled },
            now: { box.clock }
        )
    }

    // MARK: - gating

    func test_disabled_is_idle() async {
        let box = Box(); box.enabled = false
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4000, ttlSeconds: 120))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        // No report, no pull-driven completion, no fan actuation while off.
        let reports = await relay.reports
        let completions = await relay.completions
        let boostCalls = await fan.boostCalls
        XCTAssertTrue(reports.isEmpty, "disabled executor must not report")
        XCTAssertTrue(completions.isEmpty)
        XCTAssertTrue(boostCalls.isEmpty)
    }

    func test_daemon_unavailable_reports_false_and_skips_pull() async {
        let box = Box()
        let fan = FakeFan(); await fan.setAvailable(false)
        let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4000, ttlSeconds: 120))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let reports = await relay.reports
        XCTAssertEqual(reports.count, 1)
        XCTAssertFalse(reports[0].remoteFan, "unavailable daemon -> phone hides controls")
        XCTAssertFalse(reports[0].remoteLPM)
        let completions = await relay.completions
        XCTAssertTrue(completions.isEmpty, "no pull when daemon unavailable")
    }

    // MARK: - execute

    func test_set_fan_target_boosts_and_acks_done() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 120))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let boostCalls = await fan.boostCalls
        XCTAssertEqual(boostCalls, [4200])
        let completions = await relay.completions
        XCTAssertEqual(completions.count, 1)
        XCTAssertEqual(completions[0].id, "c1")
        XCTAssertEqual(completions[0].status, "done")
        XCTAssertNil(completions[0].error)
        let boosting = await ex.isBoosting
        XCTAssertTrue(boosting)
        // reported state reflects the active boost
        let reports = await relay.reports
        XCTAssertTrue(reports.last?.boostActive ?? false)
        XCTAssertEqual(reports.last?.boostTargetRPM, 4200)
    }

    func test_startBoost_failure_acks_failed_with_error() async {
        let box = Box()
        let fan = FakeFan(); await fan.setBoost(ok: false, error: "daemon_unavailable")
        let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 120))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let completions = await relay.completions
        XCTAssertEqual(completions[0].status, "failed")
        XCTAssertEqual(completions[0].error, "daemon_unavailable")
        let boosting = await ex.isBoosting
        XCTAssertFalse(boosting)
    }

    func test_revert_fan_auto_command() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "revert_fan_auto"))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let revertCount = await fan.revertCount
        XCTAssertGreaterThanOrEqual(revertCount, 1)
        let completions = await relay.completions
        XCTAssertEqual(completions[0].status, "done")
    }

    func test_set_low_power_mode_command() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_low_power_mode", on: true))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let lpmCalls = await fan.lpmCalls
        XCTAssertEqual(lpmCalls, [true])
        let completions = await relay.completions
        XCTAssertEqual(completions[0].status, "done")
    }

    // MARK: - TTL / revert matrix

    func test_ttl_expiry_reverts_boost() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 120))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                     // start boost at t=1000
        XCTAssertTrue(await ex.isBoosting)
        box.clock += 121                    // past the 120s TTL
        await ex.tick()                     // should revert
        XCTAssertFalse(await ex.isBoosting)
        let revertCount = await fan.revertCount
        XCTAssertEqual(revertCount, 1)
    }

    func test_boost_persists_before_ttl() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 120))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        box.clock += 60                     // still within TTL
        await ex.tick()
        XCTAssertTrue(await ex.isBoosting)
        XCTAssertEqual(await fan.revertCount, 0)
    }

    func test_disable_while_boosting_reverts() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                     // boosting
        box.enabled = false                 // owner flips opt-in off
        await ex.tick()                     // must revert immediately
        XCTAssertFalse(await ex.isBoosting)
        XCTAssertGreaterThanOrEqual(await fan.revertCount, 1)
    }

    func test_daemon_vanish_while_boosting_reverts() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                     // boosting
        await fan.setAvailable(false)       // daemon disappears
        await ex.tick()
        XCTAssertFalse(await ex.isBoosting)
    }

    // MARK: - resilience

    func test_pull_error_is_skipped_but_state_still_reported() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.setPullThrows(true)     // e.g. helper too old -> notImplemented
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        // report still happened (helper freshness); no crash; no completion
        XCTAssertEqual(await relay.reports.count, 1)
        XCTAssertTrue(await relay.completions.isEmpty)
    }

    func test_stop_reverts_and_reports_off() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                     // boosting
        await ex.stop()
        XCTAssertFalse(await ex.isBoosting)
        XCTAssertGreaterThanOrEqual(await fan.revertCount, 1)
        // final report announces controls off
        let last = await relay.reports.last
        XCTAssertEqual(last?.remoteFan, false)
        XCTAssertEqual(last?.boostActive, false)
    }
}
#endif
