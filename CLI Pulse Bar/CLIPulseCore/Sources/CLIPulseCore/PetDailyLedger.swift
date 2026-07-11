// PetDailyLedger — v1.42 "Pulse Cat" M0 (data contract).
//
// Durable per-day usage rollup that feeds the pet engine's trailing-7-day hatch
// window. Mirrors the proven `DailyUsageArchive` idiom (v1.40 PR-4): a pure,
// cross-platform, Codable value type + a stateless IO enum, persisted as a
// single atomically-written JSON file under Application Support/CLIPulse.
//
// SHAPE DECISION — persist per (day, provider), derive per-family on read:
// The plan frames the ledger as "per-day per-family weighted rollups", but the
// weighted/family view is a *derived* projection here, not the stored form.
// Storing raw per-provider slices (a) preserves information when local (Claude/
// Codex, high) and cloud (medium) both report different providers of the same
// family on the same day — a family-grained store would clobber one; (b) lets a
// versioned weight-table or family-mapping fix reinterpret un-hatched windows
// without a data migration; (c) mirrors `DayRollup.perProvider` exactly. The
// per-family weighted rollup the engine consumes is computed by `familyRollup`.
//
// MERGE SEMANTICS — confidence-priority replace-by-(day, provider):
// Each cumulative observation REPLACES its (day, provider) slice iff its
// confidence ≥ the existing slice's. So a high-confidence local scan wins over a
// medium cloud row for the same provider; cloud fills providers the local scan
// can't see (e.g. Gemini); re-applying the same scan is idempotent. `.delta`
// observations are never folded (no durable idempotency key in M0).

import Foundation

// MARK: - Slices

/// One provider's slice of one day. `tokens` = input + output (billable work,
/// excludes cache) to match `CostUsageScanResult.totalTokens`; `costNanoUSD` is
/// integer nano-USD so aggregation is canonical (Codex F7).
public struct PetProviderSlice: Codable, Sendable, Equatable {
    public var tokens: Int
    public var messages: Int
    public var costNanoUSD: Int64
    public var confidence: PetDataConfidence
    /// Source timestamp of the observation that wrote this slice — the
    /// deterministic tie-breaker for equal-confidence replacement (Codex F3).
    public var observedAtUnixMs: Int64

    public init(tokens: Int = 0, messages: Int = 0, costNanoUSD: Int64 = 0,
                confidence: PetDataConfidence = .high, observedAtUnixMs: Int64 = 0) {
        self.tokens = tokens
        self.messages = messages
        self.costNanoUSD = costNanoUSD
        self.confidence = confidence
        self.observedAtUnixMs = observedAtUnixMs
    }

    public var costUSD: Double { Double(costNanoUSD) / 1_000_000_000 }

    // Lenient decode: tolerate a slice missing the newer fields
    // (`costNanoUSD`, `observedAtUnixMs`) rather than failing the whole ledger
    // decode and resetting hatch history. Token history (the decision-bearing
    // signal) survives; a missing cost degrades to 0 and a missing timestamp to
    // 0 (= "oldest", so a real observation always supersedes it) (Codex F7/schema).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens) ?? 0
        messages = try c.decodeIfPresent(Int.self, forKey: .messages) ?? 0
        costNanoUSD = try c.decodeIfPresent(Int64.self, forKey: .costNanoUSD) ?? 0
        confidence = try c.decodeIfPresent(PetDataConfidence.self, forKey: .confidence) ?? .high
        observedAtUnixMs = try c.decodeIfPresent(Int64.self, forKey: .observedAtUnixMs) ?? 0
    }
}

/// One day's rollup: provider slices keyed by `ProviderKind.rawValue`.
public struct PetDayRollup: Codable, Sendable, Equatable {
    public var providers: [String: PetProviderSlice]

    public init(providers: [String: PetProviderSlice] = [:]) {
        self.providers = providers
    }

    /// Day total billable tokens (input+output) across all providers.
    public var tokens: Int { providers.values.reduce(0) { PetSaturating.add($0, $1.tokens) } }
    /// Day total messages across all providers.
    public var messages: Int { providers.values.reduce(0) { PetSaturating.add($0, $1.messages) } }
    /// Day total cost in nano-USD across all providers.
    public var costNanoUSD: Int64 { providers.values.reduce(0) { PetSaturating.add($0, $1.costNanoUSD) } }
}

/// Derived (NOT persisted) per-family rollup the engine consumes: raw tokens +
/// weight-normalised score + messages + cost + the best contributing confidence.
public struct PetFamilyRollup: Sendable, Equatable {
    public var tokens: Int
    public var weightedScore: Int64
    public var messages: Int
    public var costNanoUSD: Int64
    public var confidence: PetDataConfidence

    public init(tokens: Int = 0, weightedScore: Int64 = 0, messages: Int = 0,
                costNanoUSD: Int64 = 0, confidence: PetDataConfidence = .low) {
        self.tokens = tokens
        self.weightedScore = weightedScore
        self.messages = messages
        self.costNanoUSD = costNanoUSD
        self.confidence = confidence
    }

    public var costUSD: Double { Double(costNanoUSD) / 1_000_000_000 }
}

// MARK: - Ledger

public struct PetDailyLedger: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Days of per-day detail retained. The pet needs the trailing 7 days (hatch
    /// window) + up to a 14-day median (hunger baseline, M1); 90 gives generous
    /// slack while bounding the file. Older days are dropped (no month fold — the
    /// pet has no lifetime-total requirement, unlike the usage archive).
    public static let retainDays = 90

    public var version: Int
    public var days: [String: PetDayRollup]   // frozen "yyyy-MM-dd" -> rollup
    public var lastUpdatedUnixMs: Int64

    public init(
        version: Int = PetDailyLedger.currentVersion,
        days: [String: PetDayRollup] = [:],
        lastUpdatedUnixMs: Int64 = 0)
    {
        self.version = version
        self.days = days
        self.lastUpdatedUnixMs = lastUpdatedUnixMs
    }

    // MARK: Ingest

    /// Folds cumulative observations into the ledger. An observation is folded
    /// ONLY when it is durable token history:
    ///   • `semantics == .cumulativeToday` (deltas are the live energy signal);
    ///   • `confidence >= .medium` — `.low` is quota-snapshot-derived and must
    ///     NEVER become token history (Codex F1/F2);
    ///   • `schemaVersion == currentSchemaVersion` — an unknown schema can't be
    ///     safely interpreted, so it is skipped rather than mis-folded.
    /// Replacement is confidence-priority, then STRICTLY-newer source timestamp:
    /// a higher confidence always wins; on equal confidence only a strictly newer
    /// `sourceTimestamp` wins. Strict `>` makes the result independent of actor
    /// arrival order (a stale overlapping refresh whose task lands last cannot
    /// overwrite a fresher one), and re-ingesting the identical batch (same
    /// timestamp) is a no-op = idempotent (Codex F3). Callers MUST stamp the
    /// observation at data-source time, not at ingest time (see PetLedgerManager).
    public mutating func ingest(_ observations: [PetObservation],
                                retainDays: Int = PetDailyLedger.retainDays) {
        for obs in observations {
            guard obs.semantics == .cumulativeToday,
                  obs.confidence >= .medium,
                  obs.schemaVersion == PetObservation.currentSchemaVersion
            else { continue }
            var day = days[obs.dayKey] ?? PetDayRollup()
            if let existing = day.providers[obs.providerRaw] {
                let higherConfidence = obs.confidence > existing.confidence
                let sameConfNewer = obs.confidence == existing.confidence
                    && obs.sourceTimestampUnixMs > existing.observedAtUnixMs
                guard higherConfidence || sameConfNewer else { continue }
            }
            day.providers[obs.providerRaw] = PetProviderSlice(
                tokens: max(0, obs.tokens),
                messages: max(0, obs.messages),
                costNanoUSD: max(0, obs.costNanoUSD),
                confidence: obs.confidence,
                observedAtUnixMs: obs.sourceTimestampUnixMs)
            days[obs.dayKey] = day
        }
        prune(retainDays: retainDays)
    }

    /// Drops the oldest days beyond the retention window. Day keys are compared
    /// LEXICALLY (== chronological for zero-padded ISO keys).
    private mutating func prune(retainDays: Int) {
        guard days.count > retainDays else { return }
        let evict = days.keys.sorted().prefix(days.count - retainDays)
        for key in evict { days.removeValue(forKey: key) }
    }

    // MARK: Derived family / weighted views (engine-facing)

    /// Per-family rollup for one day, applying the current `PetWeightTable`.
    /// Family confidence = the best (max) confidence of any contributing
    /// provider in that family.
    public func familyRollup(forDay dayKey: String) -> [PetFamily: PetFamilyRollup] {
        guard let day = days[dayKey] else { return [:] }
        var out: [PetFamily: PetFamilyRollup] = [:]
        // Iterate providers in canonical (sorted) order so the saturating
        // accumulation is deterministic across platforms / the Rust port.
        for providerRaw in day.providers.keys.sorted() {
            let slice = day.providers[providerRaw]!
            let family = PetFamily.of(providerRaw: providerRaw)
            var roll = out[family] ?? PetFamilyRollup()
            roll.tokens = PetSaturating.add(roll.tokens, slice.tokens)
            roll.weightedScore = PetSaturating.add(roll.weightedScore,
                PetWeightTable.weightedScore(tokens: slice.tokens, providerRaw: providerRaw))
            roll.messages = PetSaturating.add(roll.messages, slice.messages)
            roll.costNanoUSD = PetSaturating.add(roll.costNanoUSD, slice.costNanoUSD)
            roll.confidence = max(roll.confidence, slice.confidence)
            out[family] = roll
        }
        return out
    }

    /// Per-family rollup aggregated over a set of day keys (the hatch window).
    public func familyRollup(forDays dayKeys: [String]) -> [PetFamily: PetFamilyRollup] {
        var out: [PetFamily: PetFamilyRollup] = [:]
        // Dedupe + sort the window so accumulation is order-independent and a
        // repeated key can't double-count a day (deterministic).
        for dayKey in Set(dayKeys).sorted() {
            let dayFamilies = familyRollup(forDay: dayKey)
            for family in dayFamilies.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let roll = dayFamilies[family]!
                var acc = out[family] ?? PetFamilyRollup()
                acc.tokens = PetSaturating.add(acc.tokens, roll.tokens)
                acc.weightedScore = PetSaturating.add(acc.weightedScore, roll.weightedScore)
                acc.messages = PetSaturating.add(acc.messages, roll.messages)
                acc.costNanoUSD = PetSaturating.add(acc.costNanoUSD, roll.costNanoUSD)
                acc.confidence = max(acc.confidence, roll.confidence)
                out[family] = acc
            }
        }
        return out
    }

    /// Day totals used by the engine's active-day gate (M1). The active-day
    /// threshold (≥20k) is unaffected by a saturated platform-Int on 32-bit
    /// watchOS (a saturated total is still ≥20k), so `Int` is fine here.
    public func dayTotals(_ dayKey: String) -> (tokens: Int, messages: Int) {
        guard let day = days[dayKey] else { return (0, 0) }
        return (day.tokens, day.messages)
    }

    /// Day total billable tokens as `Int64` — used by the tempo ratio, which
    /// must be exact/deterministic across 32-bit watchOS (where a multi-provider
    /// `Int` day-sum would saturate and change the burst verdict — Codex F6).
    public func dayTokensInt64(_ dayKey: String) -> Int64 {
        guard let day = days[dayKey] else { return 0 }
        return day.providers.values.reduce(Int64(0)) { PetSaturating.add($0, Int64(max(0, $1.tokens))) }
    }
}

// MARK: - Persistence (Application Support/CLIPulse/pet-ledger-v1.json)

public enum PetDailyLedgerIO {
    static let fileName = "pet-ledger-v1.json"

    /// Shares the `DailyUsageArchive` container (`~/Library/Application Support/
    /// CLIPulse`) — the app's own writable dir, no security-scoped bookmark and
    /// deliberately NOT a synced/app-group container.
    ///
    /// DELIBERATE deviation from the plan §2.1 "app-group" phrasing (both
    /// reviewers flagged it): the idiom §2.1 actually cites — `DailyUsageArchiveIO`
    /// — uses Application Support, not an app-group container, and the v1 pet has
    /// a single writer (the main app process; the M2 floating companion lives in
    /// the SAME process). Application Support avoids the iCloud " 2"/" 3" dup
    /// hazard and needs no new entitlement. IF a future out-of-process app-group
    /// peer (widget / separate helper) must read the ledger, switch this to
    /// `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` and add
    /// a single-writer coordination policy (Codex F6 / 3.1 Pro nit).
    public static func defaultRoot() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("CLIPulse", isDirectory: true)
    }

    public static func fileURL(root: URL? = nil) -> URL {
        (root ?? defaultRoot()).appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(root: URL? = nil) -> PetDailyLedger {
        let url = fileURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PetDailyLedger.self, from: data),
              decoded.version == PetDailyLedger.currentVersion
        else {
            return PetDailyLedger()
        }
        return decoded
    }

    @discardableResult
    public static func save(_ ledger: PetDailyLedger, root: URL? = nil) -> Bool {
        let url = fileURL(root: root)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]   // canonical, diffable output
            let data = try encoder.encode(ledger)
            // Atomic write via tmp + replace (CostUsageCacheIO idiom).
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            return true
        } catch {
            return false
        }
    }
}
