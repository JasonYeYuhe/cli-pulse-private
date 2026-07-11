// PetSettings — v1.42 "Pulse Cat" M2.
//
// UserDefaults-backed pet preferences: the master kill-switch (hide everything),
// the opt-in floating-companion visibility (M2b), the one-time auto-show marker,
// and cosmetic per-form names. Names live here (not in the event log) because
// they are purely cosmetic and never feed evolution.

import Foundation

public enum PetSettings {
    public static let enabledKey = "cli_pulse_pet_enabled"
    public static let companionVisibleKey = "cli_pulse_pet_companion_visible"
    public static let autoShownKey = "cli_pulse_pet_companion_autoshown"
    private static let namesKey = "cli_pulse_pet_names"

    private static var defaults: UserDefaults { .standard }

    /// Master switch. Default ON — the egg quietly appears; the FLOATING
    /// companion is separately opt-in. Turning this off hides everything.
    public static var isEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    /// Floating desktop companion — opt-in (default OFF), §5.
    public static var companionVisible: Bool {
        get { defaults.bool(forKey: companionVisibleKey) }
        set { defaults.set(newValue, forKey: companionVisibleKey) }
    }

    /// Set true after the companion auto-shows once post-hatch (§5).
    public static var didAutoShowCompanion: Bool {
        get { defaults.bool(forKey: autoShownKey) }
        set { defaults.set(newValue, forKey: autoShownKey) }
    }

    // Cosmetic per-form names (form.rawValue → user name).
    public static func names() -> [String: String] {
        guard let data = defaults.data(forKey: namesKey),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return map
    }
    public static func name(for form: PetForm) -> String? {
        let n = names()[form.rawValue]
        return (n?.isEmpty ?? true) ? nil : n
    }
    public static func setName(_ name: String, for form: PetForm) {
        var map = names()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { map.removeValue(forKey: form.rawValue) } else { map[form.rawValue] = trimmed }
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: namesKey) }
    }

    /// Display name: the user's name if set, else the localized form pun-name.
    public static func displayName(for form: PetForm) -> String {
        name(for: form) ?? L10n.pet.formName(form)
    }
}
