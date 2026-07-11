// PetSampleData — v1.42 "Pulse Cat" M2.
//
// A DETERMINISTIC, user-visible "Sample Pet" the Pet tab shows when there's no
// real pet yet (signed-out / fresh install) and which App Review can reproduce
// exactly. Unlike DemoDataProvider (randomized per launch — unsuitable, Codex
// F8), this is fixed: same ledger, same collection, same vitals every time.
// It is always LABELED as a sample in the UI — it never masquerades as real data.

import Foundation

public enum PetSampleData {
    /// A stable reference day for the sample (a fixed date, not "now").
    public static let todayKey = "2026-07-11"
    public static let nowUnixMs: Int64 = 1_781_000_000_000   // fixed instant near the sample day

    /// A fixed week: Anthropic-leaning with some OpenAI + Google, so the Usage
    /// Diet bar shows a clear mix and the active pet reads as a "Marathon Loaf".
    public static func ledger() -> PetDailyLedger {
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        let keys = PetRuleset.windowKeys(endingAt: todayKey)   // 7 keys, oldest→newest
        for (i, k) in keys.enumerated() {
            var row: [String: PetFixtureSimulator.Usage] = [
                "Claude": .init(tokens: 42_000 + i * 1_000, messages: 18, costUSD: 0.32),
            ]
            if i % 2 == 0 { row["Codex"] = .init(tokens: 12_000, messages: 0, costUSD: 0.05) }
            if i % 3 == 0 { row["Gemini"] = .init(tokens: 8_000, costUSD: 0.02, confidence: .medium) }
            days[k] = row
        }
        var l = PetFixtureSimulator.makeLedger(days)
        l.lastUpdatedUnixMs = nowUnixMs   // "live" relative to the sample now
        return l
    }

    /// A sample collection: owns Marathon Loaf (active) + Keyboard-Smash.
    public static func state() -> PetState {
        PetState(ownedForms: ["loaf", "smash"],
                 ownedDayKeys: ["loaf": "2026-06-27", "smash": "2026-07-04"],
                 activeForm: "loaf",
                 lastHatchDayKey: "2026-07-04")
    }

    public static func vitals() -> PetVitals {
        PetVitalsEngine.compute(ledger: ledger(), todayKey: todayKey, nowUnixMs: nowUnixMs)
    }
    public static func diet() -> [PetDietSlice] { PetUsageDiet.compute(ledger: ledger(), todayKey: todayKey) }
    public static func cattery() -> [PetCatteryEntry] { PetCattery.entries(state: state()) }
}
