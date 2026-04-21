import XCTest
@testable import CLIPulseCore

final class AlertThresholdsTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        // Isolated suite so tests don't pollute the user's real defaults.
        defaults = UserDefaults(suiteName: "AlertThresholdsTests-\(UUID().uuidString)")!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.dictionaryRepresentation().keys.first ?? "")
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAre80And95() {
        XCTAssertEqual(AlertThresholds.defaults.warning, 80)
        XCTAssertEqual(AlertThresholds.defaults.critical, 95)
    }

    func testLoadFallbackToDefaultsWhenMissing() {
        let loaded = AlertThresholdsStore.load(from: defaults)
        XCTAssertEqual(loaded, .defaults)
    }

    func testLoadFallbackToDefaultsWhenMalformed() {
        defaults.set(["garbage"], forKey: AlertThresholdsStore.key)
        XCTAssertEqual(AlertThresholdsStore.load(from: defaults), .defaults)

        defaults.set([80], forKey: AlertThresholdsStore.key) // wrong count
        XCTAssertEqual(AlertThresholdsStore.load(from: defaults), .defaults)
    }

    func testSaveRoundTrip() {
        let input = AlertThresholds(warning: 75, critical: 90)
        AlertThresholdsStore.save(input, to: defaults)
        let loaded = AlertThresholdsStore.load(from: defaults)
        XCTAssertEqual(loaded, input)
    }

    func testClampWarningBelowMinimum() {
        let t = AlertThresholds.clamped(warning: 10, critical: 95)
        XCTAssertEqual(t.warning, AlertThresholds.warningRange.lowerBound)  // 50
    }

    func testClampWarningAboveMaximum() {
        let t = AlertThresholds.clamped(warning: 200, critical: 99)
        XCTAssertEqual(t.warning, AlertThresholds.warningRange.upperBound)  // 94
    }

    func testClampCriticalMustExceedWarning() {
        let t = AlertThresholds.clamped(warning: 80, critical: 75)
        XCTAssertGreaterThan(t.critical, t.warning)
        XCTAssertEqual(t.critical, 81)  // forced to warning + 1
    }

    func testClampCriticalCappedAt99() {
        let t = AlertThresholds.clamped(warning: 80, critical: 500)
        XCTAssertEqual(t.critical, AlertThresholds.criticalUpperBound)  // 99
    }

    func testSaveClampsBeforePersisting() {
        let input = AlertThresholds(warning: 200, critical: 300)
        AlertThresholdsStore.save(input, to: defaults)
        let loaded = AlertThresholdsStore.load(from: defaults)
        XCTAssertEqual(loaded.warning, AlertThresholds.warningRange.upperBound)  // 94
        XCTAssertEqual(loaded.critical, AlertThresholds.criticalUpperBound)      // 99
    }

    func testResetRemovesPersistedValue() {
        AlertThresholdsStore.save(AlertThresholds(warning: 60, critical: 85), to: defaults)
        XCTAssertNotNil(defaults.array(forKey: AlertThresholdsStore.key))
        AlertThresholdsStore.reset(in: defaults)
        XCTAssertNil(defaults.array(forKey: AlertThresholdsStore.key))
        XCTAssertEqual(AlertThresholdsStore.load(from: defaults), .defaults)
    }

    func testAsArrayMatchesEvaluateQuotaAlertsSignature() {
        let t = AlertThresholds(warning: 70, critical: 90)
        XCTAssertEqual(t.asArray, [70, 90])
    }
}
