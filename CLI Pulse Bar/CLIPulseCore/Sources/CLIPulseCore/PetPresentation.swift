// PetPresentation — v1.42 "Pulse Cat" M2.
//
// Pure view-model helpers the Pet tab renders: the "Usage Diet" bar (exact
// current 7-day family mix — the steering legibility surface, 3.1 Pro F5), the
// Cattery grid model, and a hatch-status summary. No UI, fully testable.

import Foundation

// MARK: - Usage Diet (7-day family mix)

public struct PetDietSlice: Identifiable, Sendable, Equatable {
    public var family: PetFamily
    public var weightedScore: Int64
    public var percent: Double           // 0…100, of the window's weighted total
    public var id: String { family.rawValue }
}

public enum PetUsageDiet {
    /// The exact weight-normalised family mix over the trailing 7-day window,
    /// sorted by share descending (ties by family name). Empty if no usage.
    public static func compute(ledger: PetDailyLedger, todayKey: String) -> [PetDietSlice] {
        let keys = PetRuleset.windowKeys(endingAt: todayKey)
        let fam = ledger.familyRollup(forDays: keys)
        let total = fam.values.reduce(Int64(0)) { PetSaturating.add($0, $1.weightedScore) }
        guard total > 0 else { return [] }
        return fam.map { (family, roll) in
            PetDietSlice(family: family, weightedScore: roll.weightedScore,
                         percent: Double(roll.weightedScore) / Double(total) * 100)
        }
        .filter { $0.weightedScore > 0 }
        .sorted { $0.weightedScore != $1.weightedScore ? $0.weightedScore > $1.weightedScore
                                                       : $0.family.rawValue < $1.family.rawValue }
    }
}

// MARK: - Cattery

public struct PetCatteryEntry: Identifiable, Sendable, Equatable {
    public var form: PetForm
    public var owned: Bool
    public var ownedDayKey: String?      // hatch date, if owned
    public var isActive: Bool
    public var id: String { form.rawValue }
}

public enum PetCattery {
    /// All 6 forms in canonical order, with owned/date/active flags — the
    /// silhouette→color grid (locked forms show as silhouettes in the UI).
    public static func entries(state: PetState) -> [PetCatteryEntry] {
        PetForm.allCases.map { form in
            PetCatteryEntry(form: form,
                            owned: state.owns(form),
                            ownedDayKey: state.ownedDayKeys[form.rawValue],
                            isActive: state.activeForm == form.rawValue)
        }
    }
    public static func ownedCount(state: PetState) -> Int { state.ownedForms.count }
    public static let totalForms = PetForm.allCases.count
}

// MARK: - Hatch status (what the egg is "doing")

public enum PetHatchStatus: Equatable, Sendable {
    case egg(stage: PetEggStage)          // no pet yet / waiting; egg cracking
    case readyToHatch(form: PetForm)      // qualified + un-owned this cycle
    case ownedThisWeek(form: PetForm)     // qualified but already owned (waits)
    case hasCompanion(form: PetForm)      // showing an owned active pet

    public static func from(decision: PetHatchDecision, state: PetState) -> PetHatchStatus {
        if decision.shouldHatch, let f = decision.hatchedForm { return .readyToHatch(form: f) }
        if decision.alreadyOwnedThisWeek { return .ownedThisWeek(form: decision.profile.resolvedForm) }
        if let raw = state.activeForm, let f = PetForm(rawValue: raw) { return .hasCompanion(form: f) }
        return .egg(stage: decision.eggStage)
    }
}
