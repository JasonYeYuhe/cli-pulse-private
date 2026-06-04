import XCTest
@testable import CLIPulseCore

/// Pins the Remote Control health engine's rule matrix: precondition gating
/// (paired → RC → mac → helper/realtime), stale-sync detection, notifications,
/// and overall = worst-check. Pure — no UI/L10n.
final class RemoteControlHealthTests: XCTestCase {

    private typealias RCH = RemoteControlHealth

    private func status(_ report: RCH.Report, _ id: RCH.CheckID) -> RCH.Status? {
        report.checks.first { $0.id == id }?.status
    }

    private func healthyInputs(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> RCH.Inputs {
        RCH.Inputs(
            isPaired: true,
            remoteControlEnabled: true,
            hasMac: true,
            macLastSyncAt: now.addingTimeInterval(-30), // 30s ago — fresh
            helperVersion: "1.16.0",
            notificationsAuthorized: true,
            realtimeConnected: true,
            now: now
        )
    }

    func testEveryCheckIsPresentExactlyOnce() {
        let report = RCH.evaluate(healthyInputs())
        XCTAssertEqual(report.checks.count, RCH.CheckID.allCases.count)
        XCTAssertEqual(Set(report.checks.map(\.id)), Set(RCH.CheckID.allCases))
    }

    func testFullyHealthy() {
        let report = RCH.evaluate(healthyInputs())
        for check in report.checks {
            XCTAssertEqual(check.status, .ok, "\(check.id) should be ok")
        }
        XCTAssertEqual(report.overall, .ok)
        XCTAssertTrue(report.actionableChecks.isEmpty)
    }

    func testNotPairedFailsRootAndGatesTheRest() {
        var input = healthyInputs()
        input.isPaired = false
        let report = RCH.evaluate(input)
        XCTAssertEqual(status(report, .paired), .fail)
        XCTAssertEqual(status(report, .remoteControl), .notApplicable)
        XCTAssertEqual(status(report, .mac), .notApplicable)
        XCTAssertEqual(status(report, .helper), .notApplicable)
        XCTAssertEqual(status(report, .realtime), .notApplicable)
        XCTAssertEqual(report.overall, .fail)
    }

    func testRemoteControlOffWarnsAndGatesDownstream() {
        var input = healthyInputs()
        input.remoteControlEnabled = false
        let report = RCH.evaluate(input)
        XCTAssertEqual(status(report, .paired), .ok)
        XCTAssertEqual(status(report, .remoteControl), .warn)
        XCTAssertEqual(status(report, .mac), .notApplicable)
        XCTAssertEqual(status(report, .helper), .notApplicable)
        XCTAssertEqual(status(report, .realtime), .notApplicable)
        // notifications is independent of RC
        XCTAssertEqual(status(report, .notifications), .ok)
        XCTAssertEqual(report.overall, .warn)
    }

    func testRcActiveButNoMacFails() {
        var input = healthyInputs()
        input.hasMac = false
        input.macLastSyncAt = nil
        input.helperVersion = nil
        let report = RCH.evaluate(input)
        XCTAssertEqual(status(report, .mac), .fail)
        XCTAssertEqual(status(report, .helper), .notApplicable) // gated on hasMac
        XCTAssertEqual(report.overall, .fail)
    }

    func testStaleMacSyncWarns() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var input = healthyInputs(now: now)
        input.macLastSyncAt = now.addingTimeInterval(-(RCH.macSyncStaleAfter + 60)) // just over threshold
        let report = RCH.evaluate(input)
        XCTAssertEqual(status(report, .mac), .warn)
        XCTAssertEqual(report.checks.first { $0.id == .mac }?.detail, "stale")
        XCTAssertEqual(report.overall, .warn)
    }

    func testFreshMacJustUnderThresholdIsOk() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var input = healthyInputs(now: now)
        input.macLastSyncAt = now.addingTimeInterval(-(RCH.macSyncStaleAfter - 1))
        XCTAssertEqual(status(RCH.evaluate(input), .mac), .ok)
    }

    func testMissingHelperWarnsAndCarriesNoVersion() {
        var input = healthyInputs()
        input.helperVersion = nil
        let report = RCH.evaluate(input)
        XCTAssertEqual(status(report, .helper), .warn)
        XCTAssertNil(report.checks.first { $0.id == .helper }?.detail)

        input.helperVersion = "   " // whitespace-only counts as missing
        XCTAssertEqual(status(RCH.evaluate(input), .helper), .warn)
    }

    func testHelperPresentReportsVersionDetail() {
        let report = RCH.evaluate(healthyInputs())
        let helper = report.checks.first { $0.id == .helper }
        XCTAssertEqual(helper?.status, .ok)
        XCTAssertEqual(helper?.detail, "1.16.0")
    }

    func testNotificationsTriState() {
        var input = healthyInputs()
        input.notificationsAuthorized = false
        XCTAssertEqual(status(RCH.evaluate(input), .notifications), .warn)
        input.notificationsAuthorized = nil
        XCTAssertEqual(status(RCH.evaluate(input), .notifications), .notApplicable)
        input.notificationsAuthorized = true
        XCTAssertEqual(status(RCH.evaluate(input), .notifications), .ok)
    }

    func testRealtimeDisconnectedWarnsWhileUnknownIsNotApplicable() {
        var input = healthyInputs()
        input.realtimeConnected = false
        XCTAssertEqual(status(RCH.evaluate(input), .realtime), .warn)
        input.realtimeConnected = nil // not subscribing → not a problem
        XCTAssertEqual(status(RCH.evaluate(input), .realtime), .notApplicable)
    }

    func testOverallIsWorstCheck() {
        // Mac fails (worst) even though only realtime would otherwise warn.
        var input = healthyInputs()
        input.hasMac = false
        input.realtimeConnected = false
        let report = RCH.evaluate(input)
        XCTAssertEqual(report.overall, .fail)
        // actionable list contains both the fail and any warns, none of the oks
        XCTAssertTrue(report.actionableChecks.contains { $0.id == .mac && $0.status == .fail })
        XCTAssertFalse(report.actionableChecks.contains { $0.status == .ok })
    }
}
