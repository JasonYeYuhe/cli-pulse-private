// PetRuleset — v1.42 "Pulse Cat" M1 (versioned hatch profiling).
//
// Pure, deterministic profiling of a trailing 7-day window into a cat form. The
// ruleset is VERSIONED (Codex F4): the matched rule + window snapshot is frozen
// at hatch, so a later ruleset update never reinterprets an owned cat.
//
// Two axes (plan §1.2):
//   1. Family dominance over WEIGHT-NORMALISED tokens — dominant = the family
//      with ≥55% of the window's weighted score; else Mixed. "Other" (model-
//      agnostic tools) counts toward the total but has no dedicated form, so a
//      window it dominates resolves to Mixed (honest — no false vendor verdict).
//   2. Tempo — burst if the top-3 days hold ≥60% of the window's raw tokens.
//
// All qualify/dominance/tempo DECISIONS use integer cross-multiplication (no
// float compare at the threshold) so they are bit-reproducible across platforms
// and the future Rust port (§2.2). Double shares are computed for DISPLAY only.

import Foundation

/// The frozen interpretation of a trailing window — persisted verbatim in the
/// hatch event so "Why did this egg hatch into X?" is answerable forever.
public struct PetWindowProfile: Codable, Sendable, Equatable {
    public var rulesetVersion: Int
    public var weightTableVersion: Int
    public var todayKey: String
    public var windowDayKeys: [String]          // oldest→newest (≤ windowDays)
    public var activeDayKeys: [String]
    public var qualified: Bool                   // ≥ minActiveDaysToQualify active days
    public var familyWeightedScores: [String: Int64]   // PetFamily.rawValue → score
    public var familyShares: [String: Double]          // display fraction 0…1
    public var totalWeightedScore: Int64
    public var dominantFamily: String?           // PetFamily.rawValue, nil if none ≥55%
    public var tempo: PetTempo
    public var topDaysTokenShare: Double         // display fraction 0…1
    public var resolvedForm: PetForm

    public var dominant: PetFamily? { dominantFamily.flatMap(PetFamily.init(rawValue:)) }
}

public enum PetRuleset {
    /// Bump when any threshold/axis/table changes — frozen into each hatch.
    public static let version = 1

    public static let windowDays = 7
    public static let minActiveDaysToQualify = 3
    public static let activeDayMinTokens = 20_000
    public static let activeDayMinMessages = 5
    public static let dominancePercent = 55       // ≥55% weighted → dominant
    public static let burstTopDays = 3
    public static let burstPercent = 60           // top-3 days ≥60% tokens → burst
    public static let minDaysBetweenHatches = 7   // one hatch / week max

    /// The trailing window keys ending at `todayKey`, oldest→newest, via the
    /// DST/travel-safe UTC-fixed shift (reuses the M0 day-key math).
    public static func windowKeys(endingAt todayKey: String, days: Int = windowDays) -> [String] {
        var keys: [String] = []
        var k: String? = todayKey
        for _ in 0..<max(0, days) {
            guard let key = k else { break }
            keys.append(key)
            k = DailyUsageStats.previousDay(key)
        }
        return keys.reversed()
    }

    public static func isActiveDay(tokens: Int, messages: Int) -> Bool {
        tokens >= activeDayMinTokens || messages >= activeDayMinMessages
    }

    /// The v1 6-form table (plan §1.2). Google + Mixed are catch-alls across
    /// both tempos.
    public static func resolveForm(dominant: PetFamily?, tempo: PetTempo) -> PetForm {
        switch dominant {
        case .anthropic: return tempo == .steady ? .loaf : .polite
        case .openai:    return tempo == .steady ? .smash : .pop
        case .google:    return .long           // catch-all both tempos
        case .other, nil: return .huh           // Mixed / no dominant
        }
    }

    /// Profiles the trailing window ending at `todayKey`.
    public static func profile(ledger: PetDailyLedger, todayKey: String) -> PetWindowProfile {
        let keys = windowKeys(endingAt: todayKey)

        // Active days (Int gate) + per-day token totals in Int64 (for the exact
        // tempo ratio — 32-bit-watch deterministic).
        var activeKeys: [String] = []
        var dayTokens: [Int64] = []
        for key in keys {
            let t = ledger.dayTotals(key)
            if isActiveDay(tokens: t.tokens, messages: t.messages) { activeKeys.append(key) }
            dayTokens.append(ledger.dayTokensInt64(key))
        }

        // Family weighted scores over the whole window.
        let fam = ledger.familyRollup(forDays: keys)
        var scores: [String: Int64] = [:]
        var total: Int64 = 0
        for (family, roll) in fam {
            scores[family.rawValue] = roll.weightedScore
            total = PetSaturating.add(total, roll.weightedScore)
        }

        // Qualifies on ≥N active days AND a non-zero weighted-token signal — a
        // messages-only week (0 weighted tokens) has no family verdict to hatch,
        // so the egg keeps waiting (plan §1.2).
        let qualified = activeKeys.count >= minActiveDaysToQualify && total > 0

        // Dominant family: the max-weighted family whose share ≥ dominancePercent,
        // decided by EXACT 128-bit ratio comparison (never saturates a decision
        // operand — Codex F1). A window dominated by `.other` (model-agnostic
        // tools) has NO named vendor verdict → Mixed, so `dominant` stays nil and
        // the frozen why-snapshot records no dominant (Codex F2 / §1.2).
        var dominant: PetFamily? = nil
        if total > 0 {
            // Deterministic max: highest score, ties → smallest family rawValue.
            let top = fam.max { a, b in
                a.value.weightedScore != b.value.weightedScore
                    ? a.value.weightedScore < b.value.weightedScore
                    : a.key.rawValue > b.key.rawValue
            }
            if let top, top.key != .other,
               PetSaturating.productGE(top.value.weightedScore, 100, total, Int64(dominancePercent)) {
                dominant = top.key
            }
        }

        // Tempo: top-3 daily token totals ≥ burstPercent of the window tokens,
        // via the same exact ratio comparison over Int64 day totals.
        let sortedTokens = dayTokens.sorted(by: >)
        let top3 = sortedTokens.prefix(burstTopDays).reduce(Int64(0)) { PetSaturating.add($0, $1) }
        let totalTokens = sortedTokens.reduce(Int64(0)) { PetSaturating.add($0, $1) }
        let isBurst = totalTokens > 0
            && PetSaturating.productGE(top3, 100, totalTokens, Int64(burstPercent))
        let tempo: PetTempo = isBurst ? .burst : .steady

        // Display shares (never used for decisions).
        var shares: [String: Double] = [:]
        if total > 0 { for (k, v) in scores { shares[k] = Double(v) / Double(total) } }
        let topShare = totalTokens > 0 ? Double(top3) / Double(totalTokens) : 0

        return PetWindowProfile(
            rulesetVersion: version,
            weightTableVersion: PetWeightTable.version,
            todayKey: todayKey,
            windowDayKeys: keys,
            activeDayKeys: activeKeys,
            qualified: qualified,
            familyWeightedScores: scores,
            familyShares: shares,
            totalWeightedScore: total,
            dominantFamily: dominant?.rawValue,
            tempo: tempo,
            topDaysTokenShare: topShare,
            resolvedForm: resolveForm(dominant: dominant, tempo: tempo))
    }
}
