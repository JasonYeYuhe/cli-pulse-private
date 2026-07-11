// PetVitals — v1.42 "Pulse Cat" M2 (the live layer, honesty-first).
//
// Pure computation of the pet's vitals from the ledger + a freshness timestamp.
// Binding honesty rule (Codex F2): the cat NEVER fakes liveness. Every vitals
// snapshot carries a `DataConfidence`; a stale snapshot says "last observed Xm
// ago" rather than presenting a sleeping cat as real inactivity. No "live burn"
// claim — the cadence is refresh-tick, so energy is a coarse recent-activity
// bucket, not a per-second rate (the event-driven watcher is post-v1).
//
// Never punishes: hunger fills toward a capped baseline and STOPS (burning more
// changes nothing — anti-dark-pattern); a quiet day just lowers energy, never a
// negative signal.

import Foundation

// MARK: - Confidence (vitals freshness — distinct from PetDataConfidence source trust)

public enum PetVitalsConfidence: Equatable, Sendable {
    case live                 // observed within the freshness window
    case stale(ageSeconds: Int)  // last observed a while ago — shown explicitly
    case partial              // some sources fresh, some missing
    case unavailable          // can't see activity at all (check access)
}

public enum PetMood: String, Codable, Sendable, CaseIterable {
    case content              // calm weather
    case watchful             // a provider is degraded
    case windy                // a provider outage
}

// MARK: - Vitals

public struct PetVitals: Sendable, Equatable {
    public var energy: PetAnimationBucket
    public var hunger: Double              // 0…1 belly fullness (caps at 1)
    public var mood: PetMood
    public var awake: Bool
    public var confidence: PetVitalsConfidence
    public var lastObservedUnixMs: Int64?
    public var todayTokens: Int
    public var hungerBaseline: Int

    public init(energy: PetAnimationBucket = .sleeping, hunger: Double = 0,
                mood: PetMood = .content, awake: Bool = false,
                confidence: PetVitalsConfidence = .unavailable,
                lastObservedUnixMs: Int64? = nil, todayTokens: Int = 0, hungerBaseline: Int = 0) {
        self.energy = energy; self.hunger = hunger; self.mood = mood; self.awake = awake
        self.confidence = confidence; self.lastObservedUnixMs = lastObservedUnixMs
        self.todayTokens = todayTokens; self.hungerBaseline = hungerBaseline
    }
}

public enum PetVitalsEngine {
    /// Freshness window: a cat is "awake" only if data was observed this recently.
    public static let freshnessWindowSec = 300
    public static let hungerBaselineFloor = 10_000
    public static let hungerBaselineCap = 50_000    // anti-dark-pattern ceiling (§1.1)
    public static let energyWorkingTokens = 20_000  // today's tokens → working bucket
    public static let energySprintTokens = 200_000  // → sprint bucket

    /// 14-day median daily tokens → clamped hunger baseline.
    public static func hungerBaseline(ledger: PetDailyLedger, todayKey: String) -> Int {
        var totals: [Int] = []
        var key: String? = todayKey
        for _ in 0..<14 {
            guard let k = key else { break }
            totals.append(ledger.dayTotals(k).tokens)
            key = DailyUsageStats.previousDay(k)
        }
        let sorted = totals.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        return min(max(median, hungerBaselineFloor), hungerBaselineCap)
    }

    /// Compute vitals. `mood` defaults to `.content`; callers pass a
    /// providerMood override from live ServiceStatus/quota (guarded so a
    /// nil-remaining quota can't masquerade as 100% — Codex F2).
    public static func compute(ledger: PetDailyLedger, todayKey: String, nowUnixMs: Int64,
                               mood: PetMood = .content) -> PetVitals {
        let last = ledger.lastUpdatedUnixMs
        let ageSec = last > 0 ? Int(max(0, (nowUnixMs - last) / 1000)) : Int.max
        let hasData = !ledger.days.isEmpty && last > 0
        let confidence: PetVitalsConfidence = !hasData ? .unavailable
            : (ageSec <= freshnessWindowSec ? .live : .stale(ageSeconds: ageSec))

        let today = ledger.dayTotals(todayKey).tokens
        let baseline = hungerBaseline(ledger: ledger, todayKey: todayKey)
        let hunger = baseline > 0 ? min(1.0, Double(today) / Double(baseline)) : 0

        let awake = (confidence == .live) && today > 0
        let energy: PetAnimationBucket
        if !awake {
            energy = .sleeping
        } else if today >= energySprintTokens {
            energy = .sprint
        } else if today >= energyWorkingTokens {
            energy = .working
        } else {
            energy = .idle
        }

        return PetVitals(energy: energy, hunger: hunger, mood: mood, awake: awake,
                         confidence: confidence, lastObservedUnixMs: last > 0 ? last : nil,
                         todayTokens: today, hungerBaseline: baseline)
    }
}
