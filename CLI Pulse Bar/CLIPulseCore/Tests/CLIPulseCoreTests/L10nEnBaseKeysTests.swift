import XCTest
@testable import CLIPulseCore

/// H-13 (2026-06-07 review): two L10n keys referenced by
/// `L10n.providerConfig.autoImportNote` / `.autoImportFailed`
/// (`provider_config.auto_import_note` / `_failed`) existed in
/// zh-Hans/ja/zh-Hant but were missing from the **en** base locale.
/// Because en.lproj is the development-region fallback, an English
/// user — or any es/ko user falling back to en — saw the literal key
/// string instead of copy.
///
/// These tests force the locale override to `en` and resolve through
/// the production `L10n.tr` path (which reads
/// `LocaleOverrideStore.shared.bundle`), so they assert against the en
/// base regardless of the CI machine's preferred language and would
/// have caught the gap. `NSLocalizedString` echoes the key back when
/// it's missing, which is exactly the "missing" signal asserted here.
final class L10nEnBaseKeysTests: XCTestCase {

    private var savedOverride: String?

    override func setUp() {
        super.setUp()
        savedOverride = LocaleOverrideStore.shared.override
        LocaleOverrideStore.shared.set("en")
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(savedOverride)
        super.tearDown()
    }

    func test_providerConfigAutoImportKeys_resolveInEnBase() {
        let note = L10n.providerConfig.autoImportNote
        let failed = L10n.providerConfig.autoImportFailed
        // A missing key resolves to the raw key string echoed back.
        XCTAssertNotEqual(note, "provider_config.auto_import_note",
                          "auto_import_note is missing from en.lproj")
        XCTAssertNotEqual(failed, "provider_config.auto_import_failed",
                          "auto_import_failed is missing from en.lproj")
        XCTAssertFalse(note.isEmpty)
        XCTAssertFalse(failed.isEmpty)
        // Must be real English copy, not the dotted key echoed back.
        XCTAssertFalse(note.hasPrefix("provider_config."))
        XCTAssertFalse(failed.hasPrefix("provider_config."))
    }

    /// Harness guard: a known-present key resolves under the same
    /// forced-`en` path, so the test above can't pass vacuously if the
    /// en bundle ever failed to load entirely.
    func test_enOverrideResolvesAKnownKey() {
        XCTAssertEqual(L10n.providerConfig.capabilities, "Capabilities")
    }
}
