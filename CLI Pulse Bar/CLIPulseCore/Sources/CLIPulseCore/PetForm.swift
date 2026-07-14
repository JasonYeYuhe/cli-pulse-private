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
    // v1.44 drop pool (owner-directed 2026-07-13, generic archetypes): APPENDED
    // for rawValue stability; provider-neutral until a ruleset rev maps them.
    case derp     // Derpy Blep         — future drop
    case zoomies  // Zoomies Dash       — future drop
    case sleepy   // Sleepy Yawn        — future drop
    case skept    // Skeptical Squint   — future drop
    case plead    // Pleading Kitten    — future drop
    case gasp     // Wide-Eyed Gasp     — future drop
    case love     // Heart-Eyes         — future drop
    case mlem     // Mlem Lick          — future drop
    case floof    // Spooked Floof      — future drop
    case nap      // Belly-Up Nap       — future drop
    // v1.45 drop pool (owner-directed 2026-07-13, generic archetypes): APPENDED.
    case wink     // Winky Wink         — future drop
    case shy      // Bashful Blush      — future drop
    case angry    // Hissy Fit          — future drop
    case dizzy    // Dizzy Spiral       — future drop
    case proud    // Proud Puff         — future drop
    case sneeze   // Tiny Sneeze        — future drop
    case nom      // Nom Nom            — future drop
    case star     // Starry Eyes        — future drop
    case sing     // Sing Song          — future drop
    case shush    // Shush Secret       — future drop
    // v1.46 drop pool (owner-directed 2026-07-13, generic archetypes): APPENDED.
    case grin     // Cheeky Grin        — future drop
    case weepy    // Teary Waterworks   — future drop
    case think    // Deep Thinker       — future drop
    case cheer    // Cheer Yay          — future drop
    case kiss     // Blow Kiss          — future drop
    case drool    // Hungry Drool       — future drop
    case flex     // Mighty Flex        — future drop
    case peek     // Sneaky Peek        — future drop
    case melt     // Melty Puddle       — future drop
    case roll     // Rolly Giggle       — future drop
    // v1.47 drop pool (owner-directed 2026-07-13, generic archetypes): APPENDED.
    case wave     // Friendly Wave      — future drop
    case cold     // Chilly Shiver      — future drop
    case hot      // Sweaty Pant        — future drop
    case dance    // Groovy Dance       — future drop
    case fierce   // Fired Up           — future drop
    case bored    // Bored Sigh         — future drop
    case facepalm // Facepaw            — future drop
    case stretch  // Big Stretch        — future drop
    case chill    // Chill Lean         — future drop
    case zen      // Zen Meditate       — future drop
    // v1.48 drop pool (owner-directed 2026-07-14, generic archetypes): APPENDED.
    case salute   // Salute             — future drop
    case shrug    // Shrug Dunno        — future drop
    case pray     // Wishful Pray       — future drop
    case laugh    // Belly Laugh        — future drop
    case nervous  // Nervous Wreck      — future drop
    case tada     // Ta-Da              — future drop
    case queasy   // Queasy Ugh         — future drop
    case whistle  // Innocent Whistle   — future drop
    case clap     // Clap Clap          — future drop
    case peace    // Peace Out          — future drop
    // v1.49 drop pool (owner-directed 2026-07-14, generic archetypes): APPENDED.
    case hug      // Self Hug           — future drop
    case dream    // Daydream           — future drop
    case hiccup   // Hiccup             — future drop
    case oops     // Sheepish Oops      — future drop
    case point    // Point Ahead        — future drop
    case phew     // Phew Relief        — future drop
    case sniff    // Sniff Sniff        — future drop
    case huff     // Hmph Huff          — future drop
    case ouch     // Ouch Wince         — future drop
    case flop     // Dramatic Flop      — future drop

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
        case .derp: return "Derpy Blep"
        case .zoomies: return "Zoomies Dash"
        case .sleepy: return "Sleepy Yawn"
        case .skept: return "Skeptical Squint"
        case .plead: return "Pleading Kitten"
        case .gasp: return "Wide-Eyed Gasp"
        case .love: return "Heart-Eyes"
        case .mlem: return "Mlem Lick"
        case .floof: return "Spooked Floof"
        case .nap: return "Belly-Up Nap"
        case .wink: return "Winky Wink"
        case .shy: return "Bashful Blush"
        case .angry: return "Hissy Fit"
        case .dizzy: return "Dizzy Spiral"
        case .proud: return "Proud Puff"
        case .sneeze: return "Tiny Sneeze"
        case .nom: return "Nom Nom"
        case .star: return "Starry Eyes"
        case .sing: return "Sing Song"
        case .shush: return "Shush Secret"
        case .grin: return "Cheeky Grin"
        case .weepy: return "Teary Waterworks"
        case .think: return "Deep Thinker"
        case .cheer: return "Cheer Yay"
        case .kiss: return "Blow Kiss"
        case .drool: return "Hungry Drool"
        case .flex: return "Mighty Flex"
        case .peek: return "Sneaky Peek"
        case .melt: return "Melty Puddle"
        case .roll: return "Rolly Giggle"
        case .wave: return "Friendly Wave"
        case .cold: return "Chilly Shiver"
        case .hot: return "Sweaty Pant"
        case .dance: return "Groovy Dance"
        case .fierce: return "Fired Up"
        case .bored: return "Bored Sigh"
        case .facepalm: return "Facepaw"
        case .stretch: return "Big Stretch"
        case .chill: return "Chill Lean"
        case .zen: return "Zen Meditate"
        case .salute: return "Salute"
        case .shrug: return "Shrug Dunno"
        case .pray: return "Wishful Pray"
        case .laugh: return "Belly Laugh"
        case .nervous: return "Nervous Wreck"
        case .tada: return "Ta-Da"
        case .queasy: return "Queasy Ugh"
        case .whistle: return "Innocent Whistle"
        case .clap: return "Clap Clap"
        case .peace: return "Peace Out"
        case .hug: return "Self Hug"
        case .dream: return "Daydream"
        case .hiccup: return "Hiccup"
        case .oops: return "Sheepish Oops"
        case .point: return "Point Ahead"
        case .phew: return "Phew Relief"
        case .sniff: return "Sniff Sniff"
        case .huff: return "Hmph Huff"
        case .ouch: return "Ouch Wince"
        case .flop: return "Dramatic Flop"
        }
    }

    /// The family branch this form belongs to (for the Cattery lineage motif).
    /// Future-drop forms are provider-neutral until a ruleset rev maps them.
    public var family: PetFamily {
        switch self {
        case .loaf, .polite: return .anthropic
        case .smash, .pop: return .openai
        case .long: return .google
        case .huh, .sulk, .wail, .chonk, .boss, .smug,
             .derp, .zoomies, .sleepy, .skept, .plead, .gasp, .love, .mlem, .floof, .nap,
             .wink, .shy, .angry, .dizzy, .proud, .sneeze, .nom, .star, .sing, .shush,
             .grin, .weepy, .think, .cheer, .kiss, .drool, .flex, .peek, .melt, .roll,
             .wave, .cold, .hot, .dance, .fierce, .bored, .facepalm, .stretch, .chill, .zen,
             .salute, .shrug, .pray, .laugh, .nervous, .tada, .queasy, .whistle, .clap, .peace,
             .hug, .dream, .hiccup, .oops, .point, .phew, .sniff, .huff, .ouch, .flop:
            return .other
        }
    }

    /// The forms the CURRENT ruleset can hatch (PetRuleset.resolveForm's range).
    /// Forms outside this set are visible in the Cattery as "coming soon" and
    /// cannot hatch until a future ruleset revision maps them.
    public static let v1HatchPool: Set<PetForm> = [.loaf, .polite, .smash, .pop, .long, .huh]
    public var isInHatchPool: Bool { Self.v1HatchPool.contains(self) }
}
