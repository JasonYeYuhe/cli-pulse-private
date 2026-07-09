#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.41 "Mobile Machine" — the Mac executor that turns cloud fan/LPM REQUESTS
/// into local FanControlClient calls. Driven synchronously via `tick()` with a
/// fake fan daemon + fake relay + a mutable clock (no real timers / XPC / UDS),
/// mirroring the root daemon's DeadMansSwitch test pattern. Covers the
/// TTL/heartbeat/revert matrix the plan calls out: opt-in gating, daemon-vanish,
/// disable-while-boosting, TTL expiry (precise boundary), local clamp, re-boost
/// newest-wins, revert-failure, phone-vanish (empty pull), typed acks, stop.
///
/// Note: every `await` is pulled into a `let` before XCTAssert — `await` inside
/// an assert autoclosure is a hard error under CI's strict-concurrency build.
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
        var revertOK = true
        private(set) var boostCalls: [Int] = []
        private(set) var revertCount = 0
        private(set) var lpmCalls: [Bool] = []

        func setAvailable(_ b: Bool) { available = b }
        func setBoost(ok: Bool, error: String?) { boostOK = ok; boostError = error }
        func setRevertOK(_ b: Bool) { revertOK = b }

        func isAvailable() async -> Bool { available }
        func startBoost(targetRPM: Int) async -> (ok: Bool, error: String?) {
            boostCalls.append(targetRPM); return (boostOK, boostError)
        }
        func revert() async -> Bool { revertCount += 1; return revertOK }
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

    private actor FakeKeepAwake: KeepAwakeControlling {
        private(set) var calls: [(on: Bool, ttl: Int?, lid: Bool)] = []
        var active = false
        var lidActive = false
        var ok = true
        func setOK(_ b: Bool) { ok = b }
        func setKeepAwake(_ on: Bool, ttlSeconds: Int?, preventLidSleep: Bool) async -> Bool {
            calls.append((on, ttlSeconds, preventLidSleep))
            if ok { active = on; lidActive = on && preventLidSleep }
            return ok
        }
        func isKeepAwakeActive() async -> Bool { active }
        func isLidSleepPrevented() async -> Bool { lidActive }
    }

    private func makeExecutor(_ box: Box, fan: FakeFan, relay: FakeRelay,
                              keepAwake: FakeKeepAwake? = nil) -> RemoteMachineExecutor {
        RemoteMachineExecutor(
            fan: fan, relay: relay,
            keepAwake: keepAwake,
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
        let reports = await relay.reports
        XCTAssertEqual(reports.last?.boostActive, true)
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

    // MARK: - Keep Awake (v1.42)

    func test_set_keep_awake_on_and_off_ack_done() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay(); let ka = FakeKeepAwake()
        await relay.enqueue(.init(id: "k1", kind: "set_keep_awake", ttlSeconds: 3600, on: true, lid: true))
        await relay.enqueue(.init(id: "k2", kind: "set_keep_awake", on: false))
        let ex = makeExecutor(box, fan: fan, relay: relay, keepAwake: ka)
        await ex.tick()
        let calls = await ka.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].on, true)
        XCTAssertEqual(calls[0].ttl, 3600)
        XCTAssertEqual(calls[0].lid, true)      // v1.42.1 lid pass-through
        XCTAssertEqual(calls[1].on, false)
        XCTAssertNil(calls[1].ttl)
        XCTAssertEqual(calls[1].lid, false)     // absent → false
        let completions = await relay.completions
        XCTAssertEqual(completions.map(\.status), ["done", "done"])
        // The report right after execute carries the lid state from k2 (off).
        let last = await relay.reports.last
        XCTAssertEqual(last?.keepAwakeLidActive, false)
    }

    func test_keep_awake_lid_state_reported_while_held() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay(); let ka = FakeKeepAwake()
        await relay.enqueue(.init(id: "k1", kind: "set_keep_awake", on: true, lid: true))
        let ex = makeExecutor(box, fan: fan, relay: relay, keepAwake: ka)
        await ex.tick()
        let last = await relay.reports.last
        XCTAssertEqual(last?.keepAwakeActive, true)
        XCTAssertEqual(last?.keepAwakeLidActive, true)
    }

    func test_set_keep_awake_without_controller_fails_unavailable() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "k1", kind: "set_keep_awake", on: true))
        let ex = makeExecutor(box, fan: fan, relay: relay)   // keepAwake: nil
        await ex.tick()
        let completions = await relay.completions
        XCTAssertEqual(completions[0].status, "failed")
        XCTAssertEqual(completions[0].error, "unavailable")
    }

    func test_keep_awake_executes_without_fan_daemon() async {
        // v1.42 review HIGH: a fanless/daemonless Mac (fan.isAvailable()==false)
        // still advertises + must EXECUTE keep-awake — the pull gate may not be
        // fan-only, or the phone shows a toggle that silently does nothing.
        let box = Box()
        let fan = FakeFan(); await fan.setAvailable(false)
        let relay = FakeRelay(); let ka = FakeKeepAwake()
        await relay.enqueue(.init(id: "k1", kind: "set_keep_awake", on: true))
        let ex = makeExecutor(box, fan: fan, relay: relay, keepAwake: ka)
        await ex.tick()
        let calls = await ka.calls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].on, true)
        let completions = await relay.completions
        XCTAssertEqual(completions.first?.status, "done")
        let last = await relay.reports.last
        XCTAssertEqual(last?.remoteFan, false)       // fan surface hidden
        XCTAssertEqual(last?.keepAwake, true)        // keep-awake still honest
        XCTAssertEqual(last?.keepAwakeActive, true)
    }

    func test_report_carries_keep_awake_capability_and_state() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay(); let ka = FakeKeepAwake()
        await relay.enqueue(.init(id: "k1", kind: "set_keep_awake", on: true))
        let ex = makeExecutor(box, fan: fan, relay: relay, keepAwake: ka)
        await ex.tick()
        let last = await relay.reports.last
        XCTAssertEqual(last?.keepAwake, true)          // capability: controller present
        XCTAssertEqual(last?.keepAwakeActive, true)    // executed THIS tick (report after execute)
        // Without a controller the capability must report false.
        let relay2 = FakeRelay()
        let ex2 = makeExecutor(box, fan: fan, relay: relay2)
        await ex2.tick()
        let last2 = await relay2.reports.last
        XCTAssertEqual(last2?.keepAwake, false)
        XCTAssertEqual(last2?.keepAwakeActive, false)
    }

    // MARK: - TTL / revert matrix

    func test_ttl_expiry_reverts_boost_at_precise_boundary() async {
        let box = Box(); box.clock = 5_000
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 100))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                          // started at 5000, ttl 100 -> expires 5100
        box.clock = 5_099                         // 99s elapsed < ttl -> still holding
        await ex.tick()
        let holding = await ex.isBoosting
        XCTAssertTrue(holding)
        box.clock = 5_100                         // exactly ttl -> revert
        await ex.tick()
        let reverted = await ex.isBoosting
        XCTAssertFalse(reverted)
        let revertCount = await fan.revertCount
        XCTAssertEqual(revertCount, 1)
    }

    func test_reboost_refreshes_ttl_newest_wins() async {
        let box = Box(); box.clock = 1_000
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 3000, ttlSeconds: 100))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                           // c1 at 1000 -> old expiry 1100
        box.clock = 1_090
        await relay.enqueue(.init(id: "c2", kind: "set_fan_target", rpm: 5000, ttlSeconds: 100))
        await ex.tick()                           // c2 at 1090 -> new expiry 1190
        let reportedTarget = await relay.reports.last?.boostTargetRPM
        XCTAssertEqual(reportedTarget, 5000, "newer target replaces the older")
        box.clock = 1_150                         // past OLD expiry (1100), within NEW (1190)
        await ex.tick()
        let holding = await ex.isBoosting
        XCTAssertTrue(holding, "newer boost's TTL wins; old TTL must not revert it")
    }

    func test_rpm_and_ttl_clamped_locally() async {
        // Defense-in-depth: even an out-of-band payload is clamped before actuation.
        let box = Box(); box.clock = 1_000
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 99_999, ttlSeconds: 99_999))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let boostCalls = await fan.boostCalls
        XCTAssertEqual(boostCalls, [30_000], "rpm clamped to maxRPM")
        box.clock = 1_000 + 3_599                 // within clamped ttl (3600)
        await ex.tick()
        let holding = await ex.isBoosting
        XCTAssertTrue(holding)
        box.clock = 1_000 + 3_601                 // past clamped ttl
        await ex.tick()
        let reverted = await ex.isBoosting
        XCTAssertFalse(reverted, "ttl clamped to maxTTL")
    }

    func test_disable_while_boosting_reverts() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                           // boosting
        box.enabled = false                        // owner flips opt-in off
        await ex.tick()                           // must revert immediately
        let boosting = await ex.isBoosting
        XCTAssertFalse(boosting)
        let revertCount = await fan.revertCount
        XCTAssertGreaterThanOrEqual(revertCount, 1)
    }

    func test_daemon_vanish_while_boosting_reverts() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                           // boosting
        await fan.setAvailable(false)              // daemon disappears
        await ex.tick()
        let boosting = await ex.isBoosting
        XCTAssertFalse(boosting)
    }

    func test_revert_failure_still_clears_local_state() async {
        // If the daemon revert reports failure, we still clear local boost state —
        // FanControlClient stops its heartbeat first, so the daemon's 8s dead-man
        // reverts. The executor must not get stuck believing it's still boosting.
        let box = Box()
        let fan = FakeFan(); await fan.setRevertOK(false)
        let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "revert_fan_auto"))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let boosting = await ex.isBoosting
        XCTAssertFalse(boosting)
        let completions = await relay.completions
        XCTAssertEqual(completions[0].status, "failed")
    }

    // MARK: - resilience / lifecycle

    func test_pull_error_is_skipped_but_state_still_reported() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.setPullThrows(true)            // e.g. helper too old -> notImplemented
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()
        let reportCount = await relay.reports.count
        XCTAssertEqual(reportCount, 1)
        let completions = await relay.completions
        XCTAssertTrue(completions.isEmpty)
    }

    func test_stop_reverts_and_reports_off() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.tick()                           // boosting
        await ex.stop()
        let boosting = await ex.isBoosting
        XCTAssertFalse(boosting)
        let revertCount = await fan.revertCount
        XCTAssertGreaterThanOrEqual(revertCount, 1)
        let last = await relay.reports.last
        XCTAssertEqual(last?.remoteFan, false)
        XCTAssertEqual(last?.boostActive, false)
    }

    func test_stopped_executor_does_not_execute_new_commands() async {
        let box = Box()
        let fan = FakeFan(); let relay = FakeRelay()
        let ex = makeExecutor(box, fan: fan, relay: relay)
        await ex.stop()                            // sets the stopped guard
        await relay.enqueue(.init(id: "c1", kind: "set_fan_target", rpm: 4200, ttlSeconds: 900))
        await ex.tick()                            // must not pull/execute after stop
        let boostCalls = await fan.boostCalls
        XCTAssertTrue(boostCalls.isEmpty)
    }
}
#endif
