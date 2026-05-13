import XCTest
@testable import CLIPulseCore

final class PrivacySettingsTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "PrivacySettingsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func test_defaultsAreBothOff() {
        let settings = PrivacySettings(defaults: defaults)
        XCTAssertFalse(settings.skipClaudeKeychain)
        XCTAssertFalse(settings.localOnlyMode)
    }

    func test_localOnlyMode_forcesSkipClaudeKeychainOn() {
        let settings = PrivacySettings(defaults: defaults)
        XCTAssertFalse(settings.skipClaudeKeychain)
        settings.localOnlyMode = true
        XCTAssertTrue(settings.skipClaudeKeychain)
    }

    func test_skipClaudeKeychain_canBeToggledIndependentlyWhenMasterOff() {
        let settings = PrivacySettings(defaults: defaults)
        settings.skipClaudeKeychain = true
        XCTAssertTrue(settings.skipClaudeKeychain)
        XCTAssertFalse(settings.localOnlyMode)
        settings.skipClaudeKeychain = false
        XCTAssertFalse(settings.skipClaudeKeychain)
    }

    func test_userDefaultsRoundTrip_specificOnly() {
        let first = PrivacySettings(defaults: defaults)
        first.skipClaudeKeychain = true

        let second = PrivacySettings(defaults: defaults)
        XCTAssertTrue(second.skipClaudeKeychain)
        XCTAssertFalse(second.localOnlyMode)
    }

    func test_userDefaultsRoundTrip_masterImpliesSpecific() {
        let first = PrivacySettings(defaults: defaults)
        first.localOnlyMode = true

        let second = PrivacySettings(defaults: defaults)
        XCTAssertTrue(second.localOnlyMode)
        XCTAssertTrue(second.skipClaudeKeychain,
                      "Master toggle ON must force specific toggle ON after re-load")
    }

    func test_disablingMaster_doesNotAutomaticallyDisableSpecific() {
        let settings = PrivacySettings(defaults: defaults)
        settings.localOnlyMode = true
        XCTAssertTrue(settings.skipClaudeKeychain)

        settings.localOnlyMode = false
        XCTAssertFalse(settings.localOnlyMode)
        XCTAssertTrue(settings.skipClaudeKeychain,
                      "User may still want keychain skip after disabling master mode")
    }

}
