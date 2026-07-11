// PetObservation — v1.42 "Pulse Cat" M0 (data contract).
//
// The versioned input unit producers emit into the pet's `PetDailyLedger`. It
// is intentionally decoupled from `CostUsageScanResult.DailyEntry` / `DailyUsage`
// (the same decoupling `ScanEntry`/`CloudEntry` give the usage archive) so the
// ledger core stays cross-platform and independently testable.
//
// Producers (M0):
//   • CostUsageScanner deltas (Claude/Codex on-disk JSONL) → confidence `.high`
//   • dashboard / get_daily_usage cloud rollups             → confidence `.medium`
//   • ProviderUsage snapshots                               → quota/mood ONLY;
//     they emit NO token observation (no idempotency key, so they must never be
//     folded as token history — Codex F1/F2). `.low` exists for completeness.

import Foundation

// MARK: - Data confidence (source trust — high/medium/low)

/// How much the *historical token record* behind an observation can be trusted.
/// NOTE: this is the SOURCE-confidence of a data point, distinct from the live
/// VITALS freshness (`.live/.stale/.partial/.unavailable`) that M1 surfaces on
/// `PetVitals` — do not conflate them.
public enum PetDataConfidence: String, Codable, Sendable, CaseIterable, Comparable {
    /// Ground-truth local JSONL (CostUsageScanner) — the source the cost UI trusts.
    case high
    /// Cloud daily-usage rollup (may be another device / coarser granularity).
    case medium
    /// Quota-snapshot-derived or otherwise unverifiable — never a token history.
    case low

    private var rank: Int {
        switch self {
        case .high: return 2
        case .medium: return 1
        case .low: return 0
        }
    }

    public static func < (lhs: PetDataConfidence, rhs: PetDataConfidence) -> Bool {
        lhs.rank < rhs.rank
    }
}

// MARK: - Observation semantics

/// Whether an observation is an authoritative per-day total or an increment.
public enum PetObservationSemantics: String, Codable, Sendable {
    /// Authoritative cumulative total for its `dayKey` (like a scan's DailyEntry).
    /// The ledger REPLACES the matching (day, provider) slice — idempotent.
    case cumulativeToday
    /// Increment since a prior observation. Reserved for the live energy vital
    /// (M1); NOT folded into the ledger (no durable idempotency key in M0).
    case delta
}

// MARK: - Observation

public struct PetObservation: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// `ProviderKind.rawValue` (e.g. "Claude"). Carried as a string — never
    /// assume it is a valid case (mirrors every other DTO in the codebase).
    public var providerRaw: String
    /// `PetFamily.rawValue`, precomputed by the producer. The ledger re-derives
    /// family from `providerRaw` on read, so a later mapping fix reinterprets
    /// un-hatched windows; this field is the producer's contract value.
    public var familyKey: String
    /// Billable work tokens = input + output (EXCLUDES cache), matching
    /// `CostUsageScanResult.totalTokens` so the pet agrees with the cost UI.
    public var tokens: Int
    public var messages: Int
    /// Cost in integer **nano-USD** (scale 1e9 — the `CostUsageCache` costNanos
    /// idiom). Integer so ledger aggregation is order-independent and canonical
    /// (no float-sum drift — Codex F7). `costUSD` reads it back as a Double.
    public var costNanoUSD: Int64
    /// Absolute instant the observation was produced (day-granular sources stamp
    /// the scan instant). Used for "last observed" freshness + ordering, never
    /// for day bucketing — that uses the producer's frozen `dayKey`.
    public var sourceTimestampUnixMs: Int64
    /// Local day key ("yyyy-MM-dd") from the producer. The LEDGER never recomputes
    /// it from a timestamp on read, so window arithmetic and read-back are fully
    /// DST/travel-safe (Flash F7; see PetLedgerDSTTravelTests).
    /// KNOWN LIMITATION (inherited from CostUsageScanner, shared verbatim with
    /// DailyUsageArchive): the *scanner* derives this key from an event timestamp
    /// using the timezone in effect at scan time. A user who travels timezones
    /// AND triggers a full/force rescan can have one event re-bucketed to an
    /// adjacent day, counting it on two days until the older day ages out of the
    /// 90-day window. Fixing this needs per-event first-seen identity in the
    /// scanner (out of M0 scope); the aggregated DailyEntry can't recover it.
    public var dayKey: String
    public var confidence: PetDataConfidence
    public var semantics: PetObservationSemantics

    public var providerKind: ProviderKind? { ProviderKind(rawValue: providerRaw) }
    public var family: PetFamily { PetFamily(rawValue: familyKey) ?? .other }
    public var costUSD: Double { Double(costNanoUSD) / 1_000_000_000 }

    /// Rounds a Double USD amount to integer nano-USD (deterministic, once).
    /// Saturates instead of trapping if the scaled value overflows Int64 — a
    /// `Double → Int64` conversion out of range would otherwise crash (Codex F5).
    public static func nanoUSD(_ usd: Double) -> Int64 {
        let scaled = (max(0, usd) * 1_000_000_000).rounded()
        return scaled >= Double(Int64.max) ? Int64.max : Int64(scaled)
    }

    public init(
        schemaVersion: Int = PetObservation.currentSchemaVersion,
        providerRaw: String,
        familyKey: String,
        tokens: Int,
        messages: Int,
        costNanoUSD: Int64,
        sourceTimestampUnixMs: Int64,
        dayKey: String,
        confidence: PetDataConfidence,
        semantics: PetObservationSemantics)
    {
        self.schemaVersion = schemaVersion
        self.providerRaw = providerRaw
        self.familyKey = familyKey
        self.tokens = tokens
        self.messages = messages
        self.costNanoUSD = costNanoUSD
        self.sourceTimestampUnixMs = sourceTimestampUnixMs
        self.dayKey = dayKey
        self.confidence = confidence
        self.semantics = semantics
    }

    /// Convenience: derive `familyKey` from `providerRaw`, take cost in USD.
    public init(
        schemaVersion: Int = PetObservation.currentSchemaVersion,
        providerRaw: String,
        tokens: Int,
        messages: Int,
        costUSD: Double = 0,
        sourceTimestampUnixMs: Int64,
        dayKey: String,
        confidence: PetDataConfidence,
        semantics: PetObservationSemantics)
    {
        self.init(
            schemaVersion: schemaVersion,
            providerRaw: providerRaw,
            familyKey: PetFamily.of(providerRaw: providerRaw).rawValue,
            tokens: tokens,
            messages: messages,
            costNanoUSD: PetObservation.nanoUSD(costUSD),
            sourceTimestampUnixMs: sourceTimestampUnixMs,
            dayKey: dayKey,
            confidence: confidence,
            semantics: semantics)
    }
}
