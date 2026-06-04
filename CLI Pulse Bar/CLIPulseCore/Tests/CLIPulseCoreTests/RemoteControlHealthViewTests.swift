import XCTest
@testable import CLIPulseCore

/// Pins the non-SwiftUI parts of the diagnostics UI layer: every CheckID
/// resolves to real localized strings (catches a missing L10n key), and the
/// support-export text is stable + locale-independent.
final class RemoteControlHealthViewTests: XCTestCase {
    private typealias RCH = RemoteControlHealth

    func testEveryCheckIDResolvesLocalizedStrings() {
        for id in RCH.CheckID.allCases {
            let title = id.localizedTitle
            let fix = id.localizedRemediation
            XCTAssertFalse(title.isEmpty, "\(id) title empty")
            XCTAssertFalse(fix.isEmpty, "\(id) remediation empty")
            // an unresolved L10n key falls back to the raw "diagnostics.*" key
            XCTAssertFalse(title.hasPrefix("diagnostics."), "\(id) title unresolved: \(title)")
            XCTAssertFalse(fix.hasPrefix("diagnostics."), "\(id) remediation unresolved: \(fix)")
        }
    }

    func testSupportTextIsStableAndLocaleIndependent() {
        let report = RCH.evaluate(RCH.Inputs(isPaired: true, remoteControlEnabled: false))
        let text = report.supportText()
        XCTAssertTrue(text.contains("overall: warn"))
        // every check appears by RAW id + status (not localized)
        for id in RCH.CheckID.allCases {
            XCTAssertTrue(text.contains(id.rawValue), "support text missing \(id.rawValue)")
        }
        XCTAssertTrue(text.contains("remoteControl: warn"))
        XCTAssertTrue(text.contains("paired: ok"))
    }

    private func device(_ id: String, type: String, sync: String?, helper: String) -> DeviceRecord {
        DeviceRecord(id: id, name: id, type: type, system: "x", status: "Online",
                     last_sync_at: sync, helper_version: helper,
                     current_session_count: 0, cpu_usage: nil, memory_usage: nil)
    }

    func testInputsFromDevicesPicksNewestSyncedMac() {
        let devices = [
            device("phone", type: "iPhone", sync: "2026-06-04T00:00:30Z", helper: ""),
            device("mac-old", type: "Mac", sync: "2026-06-04T00:00:00Z", helper: "1.13.0"),
            device("mac-new", type: "Mac", sync: "2026-06-04T00:00:10Z", helper: "1.16.0"),
        ]
        let inputs = RCH.Inputs.from(
            isPaired: true, remoteControlEnabled: true, devices: devices,
            notificationsAuthorized: nil,
            now: Date(timeIntervalSince1970: 2_000_000))
        XCTAssertTrue(inputs.hasMac)
        // newest-synced MAC (ignores the more-recent iPhone and the older Mac)
        XCTAssertEqual(inputs.helperVersion, "1.16.0")
        XCTAssertNotNil(inputs.macLastSyncAt)
    }

    func testInputsFromDevicesNoMac() {
        let inputs = RCH.Inputs.from(
            isPaired: true, remoteControlEnabled: true,
            devices: [device("phone", type: "iPhone", sync: "2026-06-04T00:00:00Z", helper: "")],
            notificationsAuthorized: nil)
        XCTAssertFalse(inputs.hasMac)
        XCTAssertNil(inputs.helperVersion)
        // engine then reports the mac check as a fail
        XCTAssertEqual(RCH.evaluate(inputs).checks.first { $0.id == .mac }?.status, .fail)
    }

    func testSupportTextIncludesDetail() {
        let report = RCH.evaluate(RCH.Inputs(
            isPaired: true,
            remoteControlEnabled: true,
            hasMac: true,
            macLastSyncAt: Date(timeIntervalSince1970: 1_000_000),
            helperVersion: "1.16.0",
            now: Date(timeIntervalSince1970: 1_000_000)
        ))
        XCTAssertTrue(report.supportText().contains("helper: ok (1.16.0)"))
    }
}
