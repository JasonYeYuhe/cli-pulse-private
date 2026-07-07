// DailyUsageArchive — durable, un-pruned local usage history (v1.40 PR-4).
//
// The only pre-existing local history is `CostUsageCache` (Caches dir), which
// `CostUsageScanner` destructively prunes to ~30 days on every refresh tick. A
// year heatmap + lifetime stats cannot be powered by it, and widening it would
// break its pricing-version-invalidation + prune contract. This archive is a
// NEW, additive persistence tier under Application Support (durable, never in
// Caches), holding ≥370 days of per-day detail plus an uncapped monthly rollup
// so lifetime totals survive the daily cap.
//
// Schema mirrors javis603/token-monitor's proven `src/shared/history.js` shape
// (MIT). Data is Claude + Codex local JSONL history only (the two providers with
// on-disk logs) — the dashboard must label that scope so sparse data doesn't
// read as a bug.
//
// Pure + cross-platform (no os gate) so the merge/prune/fold logic is fully
// unit-testable; the macOS-only backfill scan + refresh wiring live in
// DailyUsageArchiveManager.

import Foundation

// MARK: - Rollup value types

/// Per-provider slice of a day (tokens + cost + message count).
public struct ProviderDaySlice: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public init(tokens: Int = 0, cost: Double = 0, messages: Int = 0) {
        self.tokens = tokens; self.cost = cost; self.messages = messages
    }
}

/// Per-model slice of a day (tokens + cost; messages are not model-attributed).
public struct ModelDaySlice: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public init(tokens: Int = 0, cost: Double = 0) { self.tokens = tokens; self.cost = cost }
}

/// One day's complete usage rollup.
public struct DayRollup: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public var perProvider: [String: ProviderDaySlice]
    public var perModel: [String: ModelDaySlice]

    public init(
        tokens: Int = 0, cost: Double = 0, messages: Int = 0,
        perProvider: [String: ProviderDaySlice] = [:],
        perModel: [String: ModelDaySlice] = [:])
    {
        self.tokens = tokens; self.cost = cost; self.messages = messages
        self.perProvider = perProvider; self.perModel = perModel
    }
}

/// One month's uncapped rollup (survives the daily-tier cap).
public struct MonthRollup: Codable, Sendable, Equatable {
    public var tokens: Int
    public var cost: Double
    public var messages: Int
    public init(tokens: Int = 0, cost: Double = 0, messages: Int = 0) {
        self.tokens = tokens; self.cost = cost; self.messages = messages
    }
}

// MARK: - Archive

/// Durable per-day (≥370) + per-month (uncapped) usage rollup.
///
/// Invariant: a day is in EITHER `days` OR folded into `months` (never both),
/// so lifetime totals = sum(days) + sum(months) with no double count.
/// `foldedThroughDay` is the newest day key already evicted into `months`.
public struct DailyUsageArchive: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    /// Days of per-day detail to retain (> the 370 the year-heatmap needs).
    public static let retainDays = 400

    public var version: Int
    public var days: [String: DayRollup]        // "yyyy-MM-dd" -> rollup
    public var months: [String: MonthRollup]    // "yyyy-MM" -> uncapped rollup
    public var foldedThroughDay: String?        // days <= this are in `months`, not `days`
    public var lastUpdatedUnixMs: Int64

    public init(
        version: Int = DailyUsageArchive.currentVersion,
        days: [String: DayRollup] = [:],
        months: [String: MonthRollup] = [:],
        foldedThroughDay: String? = nil,
        lastUpdatedUnixMs: Int64 = 0)
    {
        self.version = version
        self.days = days
        self.months = months
        self.foldedThroughDay = foldedThroughDay
        self.lastUpdatedUnixMs = lastUpdatedUnixMs
    }

    // MARK: Merge — local scan (authoritative, replace-by-day)

    /// Folds a scan result's entries into the archive. Each scan carries the
    /// authoritative cumulative totals for every day it covers, so days are
    /// REPLACED (not added) — re-merging the same 30-day window is idempotent.
    /// Days already evicted into `months` are skipped (never reintroduced).
    public mutating func mergeScanEntries(_ entries: [ScanEntry], retainDays: Int = DailyUsageArchive.retainDays) {
        // Rebuild each covered day from its entries.
        var rebuilt: [String: DayRollup] = [:]
        for e in entries {
            let tokens = max(0, e.inputTokens) + max(0, e.cachedTokens) + max(0, e.outputTokens)
            let cost = max(0, e.cost)
            let messages = max(0, e.messages)
            var day = rebuilt[e.date] ?? DayRollup()
            day.tokens += tokens
            day.cost += cost
            day.messages += messages
            var prov = day.perProvider[e.provider] ?? ProviderDaySlice()
            prov.tokens += tokens; prov.cost += cost; prov.messages += messages
            day.perProvider[e.provider] = prov
            // Skip the synthetic message bucket from the per-model breakdown —
            // it carries message counts, not real model usage (0 tokens/cost).
            if !e.isMessageBucket {
                var model = day.perModel[e.model] ?? ModelDaySlice()
                model.tokens += tokens; model.cost += cost
                day.perModel[e.model] = model
            }
            rebuilt[e.date] = day
        }
        for (dayKey, rollup) in rebuilt {
            if let folded = foldedThroughDay, dayKey <= folded { continue }  // already in months
            days[dayKey] = rollup
        }
        pruneAndFold(retainDays: retainDays)
    }

    // MARK: Merge — cloud (fill-only, non-destructive)

    /// Fills days that the local scan has NEVER recorded (other devices /
    /// pre-history) from cloud daily-usage rows. Non-destructive: only writes a
    /// day absent from `days` — a locally-known day is left untouched even if it
    /// has 0 tokens, because it may still carry local message counts (near a
    /// UTC boundary) that cloud rows lack. Folded days are never reintroduced.
    public mutating func mergeCloudDays(_ rows: [CloudEntry], retainDays: Int = DailyUsageArchive.retainDays) {
        var byDay: [String: DayRollup] = [:]
        for r in rows {
            let tokens = max(0, r.inputTokens) + max(0, r.cachedTokens) + max(0, r.outputTokens)
            let cost = max(0, r.cost)
            var day = byDay[r.date] ?? DayRollup()
            day.tokens += tokens; day.cost += cost
            var prov = day.perProvider[r.provider] ?? ProviderDaySlice()
            prov.tokens += tokens; prov.cost += cost
            day.perProvider[r.provider] = prov
            var model = day.perModel[r.model] ?? ModelDaySlice()
            model.tokens += tokens; model.cost += cost
            day.perModel[r.model] = model
            byDay[r.date] = day
        }
        for (dayKey, rollup) in byDay {
            if let folded = foldedThroughDay, dayKey <= folded { continue }
            if days[dayKey] == nil { days[dayKey] = rollup }   // fill absent days only
        }
        pruneAndFold(retainDays: retainDays)
    }

    /// Evicts days older than the retention window into their month rollup.
    private mutating func pruneAndFold(retainDays: Int) {
        guard days.count > retainDays else { return }
        let sorted = days.keys.sorted()
        let evictCount = days.count - retainDays
        for dayKey in sorted.prefix(evictCount) {
            guard let rollup = days.removeValue(forKey: dayKey) else { continue }
            let monthKey = String(dayKey.prefix(7))   // "yyyy-MM"
            var month = months[monthKey] ?? MonthRollup()
            month.tokens += rollup.tokens
            month.cost += rollup.cost
            month.messages += rollup.messages
            months[monthKey] = month
            if foldedThroughDay == nil || dayKey > foldedThroughDay! { foldedThroughDay = dayKey }
        }
    }
}

// MARK: - Merge input adapters (decoupled from CostUsageScanResult / DailyUsage)

/// A single scan entry, decoupled from `CostUsageScanResult.DailyEntry` so the
/// archive core stays cross-platform + independently testable.
public struct ScanEntry: Sendable, Equatable {
    public let date: String
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public let messages: Int
    /// The synthetic `__claude_msg__` bucket (messages only, no real model usage).
    public var isMessageBucket: Bool { model == ScanEntry.messageBucketModel }
    public static let messageBucketModel = "__claude_msg__"

    public init(
        date: String, provider: String, model: String,
        inputTokens: Int, cachedTokens: Int, outputTokens: Int,
        cost: Double, messages: Int)
    {
        self.date = date; self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens; self.cost = cost; self.messages = messages
    }
}

/// A cloud daily-usage row (get_daily_usage) — tokens + cost, no messages.
public struct CloudEntry: Sendable, Equatable {
    public let date: String
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let cachedTokens: Int
    public let outputTokens: Int
    public let cost: Double
    public init(
        date: String, provider: String, model: String,
        inputTokens: Int, cachedTokens: Int, outputTokens: Int, cost: Double)
    {
        self.date = date; self.provider = provider; self.model = model
        self.inputTokens = inputTokens; self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens; self.cost = cost
    }
}

// MARK: - Persistence (Application Support/CLIPulse/usage-history-v1.json)

public enum DailyUsageArchiveIO {
    static let fileName = "usage-history-v1.json"

    /// `~/Library/Application Support/CLIPulse` (or the sandbox container's
    /// equivalent) — the app's OWN writable dir; needs no security-scoped
    /// bookmark (unlike the JSONL scan roots).
    public static func defaultRoot() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("CLIPulse", isDirectory: true)
    }

    public static func fileURL(root: URL? = nil) -> URL {
        (root ?? defaultRoot()).appendingPathComponent(fileName, isDirectory: false)
    }

    public static func load(root: URL? = nil) -> DailyUsageArchive {
        let url = fileURL(root: root)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(DailyUsageArchive.self, from: data),
              decoded.version == DailyUsageArchive.currentVersion
        else {
            return DailyUsageArchive()
        }
        return decoded
    }

    @discardableResult
    public static func save(_ archive: DailyUsageArchive, root: URL? = nil) -> Bool {
        let url = fileURL(root: root)
        let dir = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(archive)
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
