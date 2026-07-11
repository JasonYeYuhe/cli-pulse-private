// PetForm — v1.42 "Pulse Cat" M1.
//
// The six v1 cat forms. `rawValue` is the stable asset `form_id` (matches
// ART_ASSET_LIST_v1.42_pulse_cat.md and the PetAssets/ layout) — it is
// persisted in the pet event log and Cattery, so NEVER rename a case's raw
// value (it would orphan owned cats). Display names are localized separately
// via L10n.pet.* (M2); the pun names here are the canonical English identity.
//
// Forms are the product of two axes (see PetRuleset): family dominance
// (anthropic/openai/google/other→Mixed) × tempo (steady/burst). Google and
// Mixed are catch-alls across both tempos in v1; night-owl/efficiency forms join
// the pool in v1.43+ once the hour-of-day sampler exists. Pure/cross-platform.

import Foundation

public enum PetTempo: String, Codable, CaseIterable, Sendable {
    case steady
    case burst
}

public enum PetForm: String, Codable, CaseIterable, Sendable {
    // v1 rule-hatched pool (mapped by PetRuleset family × tempo):
    case loaf     // Marathon Loaf      — Anthropic · Steady
    case polite   // Polite Flat-Smile  — Anthropic · Burst (catch-all)
    case smash    // Keyboard-Smash     — OpenAI · Steady
    case pop      // Pop-Mouth          — OpenAI · Burst (catch-all)
    case long     // Stretched Long     — Google · both tempos (catch-all)
    case huh      // Head-Tilt "Huh?"   — Mixed / no dominant (catch-all)
    // v1.43+ drop pool (owner-directed 2026-07-12, generic archetypes from the
    // owner's moodboard): art ships now, Cattery shows them as "coming soon",
    // rules hatch them in a future ruleset rev (each drop = a retention beat).
    case sulk     // Sulky Pout         — future drop
    case wail     // Headclutch Wail    — future drop
    case chonk    // Deadpan Chonk      — future drop (named in the plan's pool)
    case boss     // Middle Manager     — future drop
    case smug     // Smug Duchess       — future drop

    /// Canonical English pun name (display copy is localized in M2).
    public var punName: String {
        switch self {
        case .loaf: return "Marathon Loaf"
        case .polite: return "Polite Flat-Smile"
        case .smash: return "Keyboard-Smash"
        case .pop: return "Pop-Mouth"
        case .long: return "Stretched Long"
        case .huh: return "Head-Tilt Huh?"
        case .sulk: return "Sulky Pout"
        case .wail: return "Headclutch Wail"
        case .chonk: return "Deadpan Chonk"
        case .boss: return "Middle Manager"
        case .smug: return "Smug Duchess"
        }
    }

    /// The family branch this form belongs to (for the Cattery lineage motif).
    /// Future-drop forms are provider-neutral until a ruleset rev maps them.
    public var family: PetFamily {
        switch self {
        case .loaf, .polite: return .anthropic
        case .smash, .pop: return .openai
        case .long: return .google
        case .huh, .sulk, .wail, .chonk, .boss, .smug: return .other
        }
    }

    /// The forms the CURRENT ruleset can hatch (PetRuleset.resolveForm's range).
    /// Forms outside this set are visible in the Cattery as "coming soon" and
    /// cannot hatch until a future ruleset revision maps them.
    public static let v1HatchPool: Set<PetForm> = [.loaf, .polite, .smash, .pop, .long, .huh]
    public var isInHatchPool: Bool { Self.v1HatchPool.contains(self) }
}
