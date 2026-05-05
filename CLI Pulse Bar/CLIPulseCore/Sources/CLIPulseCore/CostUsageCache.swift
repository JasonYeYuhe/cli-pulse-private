#if os(macOS)
import Foundation

// MARK: - Cache Types

/// Bump this every time `CostUsageScanner.Pricing.claudeModels` or
/// `codexModels` changes (entries added / removed / repriced).
///
/// Why: per-event cost is computed inside `parseClaudeFile` /
/// `parseCodexFile` and stored as `costNanos` in the per-day-model
/// bucket. The `entriesFromClaudeCache` reconstruction has a
/// fallback that re-runs `Pricing.claudeCostUSD` when the bucket's
/// summed `costNanos` is exactly zero — but that fallback gives the
/// WRONG answer once even one new event lands in a previously-zero
/// bucket: the bucket then has partial cost, the fallback is
/// skipped, and only the new events' contribution is reported.
///
/// Bumping this constant invalidates every saved cache file on
/// next `load()` (returns an empty cache), forcing the next
/// `scanClaudeProvider` / `scanCodexProvider` to re-parse every
/// JSONL file with the current pricing rules. ~200 files take
/// ~1-2 s on a paired developer machine — a fair price for
/// guaranteed-correct cost on the first refresh after an upgrade.
///
/// History:
///   1 — initial schema (no version field on disk; default Int = 0
///       on legacy files made them count as "stale" against this
///       constant, which is the desired behaviour).
///   2 — May 2026: `claude-opus-4-7` priced + family-fallback added
///       (PR fix-claude-usage-cost-accuracy). Caches written with
///       pricingVersion=0 had `costNanos=0` for every Opus 4.7
///       event; bump invalidates them so a normal refresh — not a
///       manual Force Rescan — produces correct Today/Week cost.
let costUsageCachePricingVersion: Int = 2

struct CostUsageCache: Codable {
    var version: Int = 1
    /// Pricing-rules version this cache was computed against. Loaded
    /// caches whose `pricingVersion` differs from
    /// `costUsageCachePricingVersion` are treated as stale and
    /// returned as empty by `CostUsageCacheIO.load`. Default `0` so
    /// pre-version-bump on-disk files (no `pricingVersion` key) are
    /// invalidated as soon as we ship the first version > 0.
    var pricingVersion: Int = 0
    var lastScanUnixMs: Int64 = 0
    /// filePath -> file usage
    var files: [String: CostUsageFileUsage] = [:]
    /// dayKey -> model -> packed usage [input, cached, output] for Codex, [input, cacheRead, cacheCreate, output, costNanos] for Claude
    var days: [String: [String: [Int]]] = [:]
}

struct CostUsageFileUsage: Codable {
    var mtimeUnixMs: Int64
    var size: Int64
    var days: [String: [String: [Int]]]
    var parsedBytes: Int64?
    var lastModel: String?
    var lastTotals: CostUsageCodexTotals?
    var sessionId: String?
}

struct CostUsageCodexTotals: Codable {
    var input: Int
    var cached: Int
    var output: Int
}

// MARK: - Cache IO

enum CostUsageCacheIO {
    private static func defaultCacheRoot() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("CLIPulse", isDirectory: true)
    }

    static func cacheFileURL(provider: String, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? defaultCacheRoot()
        return root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("\(provider.lowercased())-v2.json", isDirectory: false)
    }

    static func load(provider: String, cacheRoot: URL? = nil) -> CostUsageCache {
        let url = cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(CostUsageCache.self, from: data),
              decoded.version == 1,
              decoded.pricingVersion == costUsageCachePricingVersion else {
            // Either schema-version drift OR pricing-rules drift —
            // both invalidate the cached cost numbers, both heal
            // automatically by returning an empty cache here so the
            // next scan re-parses every JSONL file with current rules.
            return CostUsageCache()
        }
        return decoded
    }

    static func save(provider: String, cache: CostUsageCache, cacheRoot: URL? = nil) {
        let url = cacheFileURL(provider: provider, cacheRoot: cacheRoot)
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Stamp the cache with the current pricing version on every
        // save. Otherwise a freshly-parsed cache could be saved with
        // pricingVersion=0 (the dataclass default) and look stale
        // immediately on the next load.
        var stamped = cache
        stamped.pricingVersion = costUsageCachePricingVersion

        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
        guard let data = try? JSONEncoder().encode(stamped) else { return }
        do {
            try data.write(to: tmp, options: [.atomic])
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    /// v1.9.4: wipe all `cost-usage/*.json` caches. Called by the "Force
    /// Rescan" button after the user grants new bookmarks, because stale
    /// subtractions from prior sandbox-blocked runs (where `scanClaudeRoot`
    /// decided the root didn't exist and applied `sign: -1` to all file days)
    /// can leave the disk cache reporting less than what the JSONLs actually
    /// contain.
    static func wipeAll(cacheRoot: URL? = nil) {
        let root = (cacheRoot ?? defaultCacheRoot()).appendingPathComponent("cost-usage", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try? FileManager.default.removeItem(at: root)
    }
}

#endif
