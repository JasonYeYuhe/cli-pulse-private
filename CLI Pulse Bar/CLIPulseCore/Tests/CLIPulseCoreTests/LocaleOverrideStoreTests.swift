import XCTest
@testable import CLIPulseCore

/// iter22: pin the in-app language switcher contract — overrides
/// must resolve to a real `.lproj` bundle, fall back to system
/// default when nil, and ignore unknown values gracefully.
final class LocaleOverrideStoreTests: XCTestCase {
    override func tearDown() {
        // Always restore default after each test so other suites in
        // the same process aren't affected.
        LocaleOverrideStore.shared.set(nil)
        super.tearDown()
    }

    func test_default_isNil() {
        LocaleOverrideStore.shared.set(nil)
        XCTAssertNil(LocaleOverrideStore.shared.override)
    }

    func test_setEnglish_resolvesToEnLproj() {
        LocaleOverrideStore.shared.set("en")
        XCTAssertEqual(LocaleOverrideStore.shared.override, "en")
        // The english bundle should resolve key tab.overview to "Overview"
        // regardless of the system locale running these tests.
        let translated = NSLocalizedString("tab.overview", bundle: LocaleOverrideStore.shared.bundle, comment: "")
        XCTAssertEqual(translated, "Overview")
    }

    func test_setJapanese_resolvesToJaLproj() {
        LocaleOverrideStore.shared.set("ja")
        let translated = NSLocalizedString("tab.overview", bundle: LocaleOverrideStore.shared.bundle, comment: "")
        XCTAssertEqual(translated, "概要")
    }

    func test_setSimplifiedChinese_resolvesToZhHansLproj() {
        LocaleOverrideStore.shared.set("zh-Hans")
        let translated = NSLocalizedString("tab.overview", bundle: LocaleOverrideStore.shared.bundle, comment: "")
        XCTAssertEqual(translated, "概览")
    }

    func test_setTraditionalChinese_resolvesToZhHantLproj() {
        LocaleOverrideStore.shared.set("zh-Hant")
        let translated = NSLocalizedString("tab.overview", bundle: LocaleOverrideStore.shared.bundle, comment: "")
        XCTAssertEqual(translated, "概覽")
    }

    func test_unknownOverride_fallsBackToBaseBundle() {
        LocaleOverrideStore.shared.set("xx-Unknown")
        // Should NOT crash; should resolve via the base `.module` bundle.
        let translated = NSLocalizedString("tab.overview", bundle: LocaleOverrideStore.shared.bundle, comment: "")
        XCTAssertFalse(translated.isEmpty)
    }

    func test_setNil_clearsOverride() {
        LocaleOverrideStore.shared.set("ja")
        LocaleOverrideStore.shared.set(nil)
        XCTAssertNil(LocaleOverrideStore.shared.override)
    }
}
