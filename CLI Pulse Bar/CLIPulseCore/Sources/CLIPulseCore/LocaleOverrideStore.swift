import Foundation
import Combine
#if canImport(SwiftUI)
import SwiftUI
#endif

/// Runtime UI-language override. When set, `L10n.tr` looks up strings in
/// the matching `.lproj` bundle instead of the system-default locale.
///
/// iter22 (2026-05-01): added the in-app language switcher requested by
/// manual smoke. Persisted to standard UserDefaults so the choice
/// survives restarts. Posts `objectWillChange` and a notification on
/// every change so observing views (and `AppState`, which republishes
/// to its own observers) re-render localized strings without a relaunch.
public final class LocaleOverrideStore: ObservableObject {
    public static let shared = LocaleOverrideStore()

    /// Posted whenever the active override changes. Useful for
    /// `AppState` to forward to its own subscribers so SwiftUI views
    /// that don't directly observe `LocaleOverrideStore` still
    /// re-render localized text after a language switch.
    public static let didChangeNotification = Notification.Name("CLIPulseLocaleOverrideDidChange")

    private static let defaultsKey = "cli_pulse_locale_override"

    /// `nil` means "follow system default". Non-nil values are the
    /// matching `.lproj` directory name, e.g. `"en"`, `"ja"`,
    /// `"zh-Hans"`.
    @Published public private(set) var override: String?

    private init() {
        self.override = UserDefaults.standard.string(forKey: Self.defaultsKey)
    }

    public func set(_ newValue: String?) {
        guard newValue != override else { return }
        override = newValue
        if let newValue {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Bundle to read localized strings from. Falls back to the package
    /// resource bundle when the override doesn't resolve to a known
    /// `.lproj` directory.
    public var bundle: Bundle {
        let base = Self.resourceBundle()
        guard let override else { return base }
        // Try the canonical name first (e.g. "zh-Hans"), then a
        // lowercased variant (SwiftPM rewrites resource bundle
        // directory names to all-lowercase, e.g. "zh-hans.lproj"),
        // then fall back to the base bundle for unknown values so
        // callers don't crash on typos.
        for candidate in Self.resolutionCandidates(for: override) {
            if let path = base.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
        }
        return base
    }

    private static func resolutionCandidates(for override: String) -> [String] {
        var candidates = [override]
        let lower = override.lowercased()
        if lower != override { candidates.append(lower) }
        return candidates
    }

    private static func resourceBundle() -> Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return Bundle(for: BundleToken.self)
        #endif
    }
}

#if !SWIFT_PACKAGE
private final class BundleToken {}
#endif
