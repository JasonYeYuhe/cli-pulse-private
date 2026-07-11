// PetEngine — v1.42 "Pulse Cat" M1 (pure hatch evaluator).
//
// Zero-I/O pure functions: (ledger, state, todayKey) → hatch decision. The
// PetCoordinator actor owns persistence and applies decisions; the engine only
// computes. Injectable "today" (a day key) keeps it deterministic and testable;
// golden vectors pin its behaviour as the cross-platform Rust-port contract.
//
// EMOTIONAL FLOOR (binding): the engine never punishes. An un-qualified or
// already-owned week produces NO state change and NO negative signal — the egg
// simply waits. There is no decay, death, or regression anywhere.

import Foundation

// MARK: - Egg crack progress (visible from day 1)

/// How cracked the egg looks — driven purely by active days in the current
/// window, so progress is visible before a hatch ever happens.
public enum PetEggStage: Int, Codable, Sendable, Comparable {
    case idle = 0
    case crack1 = 1
    case crack2 = 2
    case crack3 = 3       // window qualifies (≥3 active days)

    public static func < (l: PetEggStage, r: PetEggStage) -> Bool { l.rawValue < r.rawValue }
    public static func forActiveDays(_ n: Int) -> PetEggStage {
        PetEggStage(rawValue: min(max(0, n), 3)) ?? .crack3
    }
}

// MARK: - Persisted pet state

/// The durable collection state the coordinator persists. Lenient decode so M2
/// can add fields (names, kill-switch) without resetting the collection.
public struct PetState: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var ownedForms: [String]              // PetForm.rawValue, acquisition order
    public var ownedDayKeys: [String: String]    // form.rawValue → hatch dayKey
    public var activeForm: String?               // currently-shown companion (nil = egg)
    public var lastHatchDayKey: String?

    public init(version: Int = PetState.currentVersion,
                ownedForms: [String] = [],
                ownedDayKeys: [String: String] = [:],
                activeForm: String? = nil,
                lastHatchDayKey: String? = nil) {
        self.version = version
        self.ownedForms = ownedForms
        self.ownedDayKeys = ownedDayKeys
        self.activeForm = activeForm
        self.lastHatchDayKey = lastHatchDayKey
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PetState.currentVersion
        ownedForms = try c.decodeIfPresent([String].self, forKey: .ownedForms) ?? []
        ownedDayKeys = try c.decodeIfPresent([String: String].self, forKey: .ownedDayKeys) ?? [:]
        activeForm = try c.decodeIfPresent(String.self, forKey: .activeForm)
        lastHatchDayKey = try c.decodeIfPresent(String.self, forKey: .lastHatchDayKey)
    }

    public func owns(_ form: PetForm) -> Bool { ownedForms.contains(form.rawValue) }
}

// MARK: - Decision

public struct PetHatchDecision: Sendable, Equatable {
    public var profile: PetWindowProfile
    /// ≥ minDaysBetweenHatches since the last hatch (or never hatched). A clock
    /// rollback / backward travel yields `false` (never hatches on a stale date).
    public var timingAllows: Bool
    /// Qualified + timing + the resolved form is not already owned.
    public var shouldHatch: Bool
    public var hatchedForm: PetForm?
    /// Qualified but the resolved form is already owned — the egg waits (no penalty).
    public var alreadyOwnedThisWeek: Bool
    public var eggStage: PetEggStage
}

public enum PetEngine {

    /// Evaluate the hatch decision for `todayKey` (the local day key of "now").
    public static func evaluate(ledger: PetDailyLedger,
                                state: PetState,
                                todayKey: String) -> PetHatchDecision {
        let profile = PetRuleset.profile(ledger: ledger, todayKey: todayKey)
        let eggStage = PetEggStage.forActiveDays(profile.activeDayKeys.count)

        let timingAllows = Self.timingAllows(lastHatchDayKey: state.lastHatchDayKey, todayKey: todayKey)
        let form = profile.resolvedForm
        let owned = state.owns(form)
        let shouldHatch = profile.qualified && timingAllows && !owned
        let alreadyOwned = profile.qualified && timingAllows && owned

        return PetHatchDecision(
            profile: profile,
            timingAllows: timingAllows,
            shouldHatch: shouldHatch,
            hatchedForm: shouldHatch ? form : nil,
            alreadyOwnedThisWeek: alreadyOwned,
            eggStage: eggStage)
    }

    /// True iff at least `minDaysBetweenHatches` have elapsed since the last
    /// hatch. Computed as `todayKey >= shift(lastHatch, +N)` — DST/travel-safe
    /// (lexical == chronological for ISO keys) and O(1); a rolled-back clock
    /// (todayKey earlier than the earliest-next key) is correctly disallowed.
    public static func timingAllows(lastHatchDayKey: String?, todayKey: String) -> Bool {
        guard let last = lastHatchDayKey else { return true }
        guard let earliestNext = DailyUsageStats.shift(last, byDays: PetRuleset.minDaysBetweenHatches) else {
            return true   // unparseable prior key — don't wedge the feature
        }
        return todayKey >= earliestNext
    }

    /// Applies a hatch to a state copy (used by the coordinator + tests). Adds
    /// the form to the collection, records its date, sets it active if it's the
    /// first pet, and stamps the hatch date. No-op if the form is already owned.
    public static func applyHatch(_ form: PetForm, on state: PetState, dayKey: String) -> PetState {
        var s = state
        guard !s.owns(form) else { return s }
        s.ownedForms.append(form.rawValue)
        s.ownedDayKeys[form.rawValue] = dayKey
        if s.activeForm == nil { s.activeForm = form.rawValue }
        s.lastHatchDayKey = dayKey
        return s
    }
}
