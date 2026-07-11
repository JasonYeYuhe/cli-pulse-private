// PetFixtureSimulator + golden vectors — v1.42 "Pulse Cat" M1.
//
// Deterministic fixture-driven simulation of the pet engine, used by:
//   • the golden-vector test (PetGoldenVectors.json = the cross-platform Rust-
//     port contract; §2.2), and
//   • the DEVID/debug time-travel menu (M2) which injects a fixture ledger and
//     steps "today" forward to preview hatches without waiting real days.
//
// Pure + cross-platform. Building a ledger from a fixture uses the real M0
// producer path (PetObservation → ingest), so fixtures exercise the same code
// the app runs.

import Foundation

// MARK: - Fixture → ledger

public enum PetFixtureSimulator {

    /// Per-provider usage for one fixture day.
    public struct Usage: Sendable, Equatable {
        public var tokens: Int
        public var messages: Int
        public var costUSD: Double
        public var confidence: PetDataConfidence
        public init(tokens: Int, messages: Int = 0, costUSD: Double = 0,
                    confidence: PetDataConfidence = .high) {
            self.tokens = tokens; self.messages = messages
            self.costUSD = costUSD; self.confidence = confidence
        }
    }

    /// Builds a ledger from `[dayKey: [providerRaw: Usage]]`. Each entry becomes a
    /// cumulative observation stamped at `baseTimestampMs` (order-independent).
    public static func makeLedger(_ days: [String: [String: Usage]],
                                  baseTimestampMs: Int64 = 1) -> PetDailyLedger {
        var ledger = PetDailyLedger()
        var obs: [PetObservation] = []
        for (dayKey, providers) in days {
            for (providerRaw, usage) in providers {
                obs.append(PetObservation(
                    providerRaw: providerRaw,
                    tokens: usage.tokens,
                    messages: usage.messages,
                    costUSD: usage.costUSD,
                    sourceTimestampUnixMs: baseTimestampMs,
                    dayKey: dayKey,
                    confidence: usage.confidence,
                    semantics: .cumulativeToday))
            }
        }
        // Use a retain window large enough for any fixture.
        ledger.ingest(obs, retainDays: 4096)
        return ledger
    }
}

// MARK: - Golden vectors (committed contract)

public struct PetGoldenUsage: Codable, Sendable {
    public var tokens: Int
    public var messages: Int?
    public var cost: Double?
    public var confidence: String?   // "high" | "medium" | "low" (default high)
}

public struct PetGoldenExpect: Codable, Sendable, Equatable {
    public var qualified: Bool
    public var timingAllows: Bool
    public var dominantFamily: String?
    public var tempo: String
    public var resolvedForm: String
    public var shouldHatch: Bool
    public var hatchedForm: String?
    public var alreadyOwned: Bool
    public var eggStage: Int
}

public struct PetGoldenCase: Codable, Sendable {
    public var name: String
    public var todayKey: String
    public var ownedForms: [String]
    public var lastHatchDayKey: String?
    public var days: [String: [String: PetGoldenUsage]]
    public var expect: PetGoldenExpect
}

public struct PetGoldenVectorFile: Codable, Sendable {
    public var rulesetVersion: Int
    public var weightTableVersion: Int
    public var cases: [PetGoldenCase]
}

public enum PetGoldenVectors {
    /// Loads the committed golden-vector contract from the module bundle.
    /// (Tries the root then a "Pet" subdirectory — `.process` may flatten or
    /// preserve structure; the TerminalView resource loader hedges the same way.)
    public static func loadBundled() -> PetGoldenVectorFile? {
        let bundle = Bundle.module
        guard let url = bundle.url(forResource: "PetGoldenVectors", withExtension: "json")
                ?? bundle.url(forResource: "PetGoldenVectors", withExtension: "json", subdirectory: "Pet"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(PetGoldenVectorFile.self, from: data)
        else { return nil }
        return file
    }

    /// Builds the ledger for a golden case via the fixture simulator.
    public static func ledger(for c: PetGoldenCase) -> PetDailyLedger {
        var days: [String: [String: PetFixtureSimulator.Usage]] = [:]
        for (dayKey, providers) in c.days {
            var row: [String: PetFixtureSimulator.Usage] = [:]
            for (providerRaw, u) in providers {
                let conf = PetDataConfidence(rawValue: u.confidence ?? "high") ?? .high
                row[providerRaw] = .init(tokens: u.tokens, messages: u.messages ?? 0,
                                         costUSD: u.cost ?? 0, confidence: conf)
            }
            days[dayKey] = row
        }
        return PetFixtureSimulator.makeLedger(days)
    }

    /// Evaluates a golden case and returns the engine decision to compare against
    /// `expect`.
    public static func evaluate(_ c: PetGoldenCase) -> PetHatchDecision {
        let ledger = Self.ledger(for: c)
        let state = PetState(ownedForms: c.ownedForms, lastHatchDayKey: c.lastHatchDayKey)
        return PetEngine.evaluate(ledger: ledger, state: state, todayKey: c.todayKey)
    }
}
