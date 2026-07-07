// DailyUsageArchiveManager — macOS glue between the scanner/cloud and the pure
// DailyUsageArchive spine (v1.40 PR-4). Loads/saves the durable archive, folds
// every refresh's scan result into it, runs the one-time 365-day backfill in an
// ISOLATED throwaway cacheRoot (so the live 30-day cache's Today bookkeeping is
// never corrupted), and fills other-device days from the cloud.
//
// An actor: the archive is mutable shared state touched from the refresh path.
// The heavy backfill parse runs on the actor's executor (off the main thread).

#if os(macOS)
import Foundation

public actor DailyUsageArchiveManager {
    public static let shared = DailyUsageArchiveManager()

    private var archive: DailyUsageArchive
    private let root: URL?                 // nil ⇒ default Application Support
    private let defaults: UserDefaults
    private let backfillKey: String
    private var backfillRunning = false

    public static let defaultBackfillKey = "cli_pulse_daily_archive_backfilled_v1"
    static let backfillDays = 365

    public init(
        root: URL? = nil,
        defaults: UserDefaults = .standard,
        backfillKey: String = DailyUsageArchiveManager.defaultBackfillKey)
    {
        self.root = root
        self.defaults = defaults
        self.backfillKey = backfillKey
        self.archive = DailyUsageArchiveIO.load(root: root)
    }

    /// Current archive snapshot (for the dashboard window — PR-5).
    public func snapshot() -> DailyUsageArchive { archive }

    // MARK: - Record a refresh scan (authoritative local, replace-by-day)

    public func record(_ scanResult: CostUsageScanResult) {
        guard !scanResult.entries.isEmpty else { return }
        archive.mergeScanEntries(scanResult.entries.map(Self.scanEntry))
        archive.lastUpdatedUnixMs = Self.nowMs()
        DailyUsageArchiveIO.save(archive, root: root)
    }

    // MARK: - Merge cloud daily usage (fill-only, other devices / pre-history)

    public func mergeCloud(_ rows: [DailyUsage]) {
        let filtered = rows.filter { $0.model != ScanEntry.messageBucketModel }
        guard !filtered.isEmpty else { return }
        archive.mergeCloudDays(filtered.map(Self.cloudEntry))
        archive.lastUpdatedUnixMs = Self.nowMs()
        DailyUsageArchiveIO.save(archive, root: root)
    }

    // MARK: - One-time 365-day backfill (isolated cacheRoot)

    /// Runs once (guarded by `defaults[backfillKey]`). Callers should invoke
    /// this only after a normal scan succeeded, so folder access is confirmed —
    /// then a successful backfill (even one that finds little history) marks the
    /// flag done. Uses a throwaway temp cacheRoot; NEVER the production cache.
    public func runBackfillIfNeeded() async {
        guard !defaults.bool(forKey: backfillKey), !backfillRunning else { return }
        backfillRunning = true
        defer { backfillRunning = false }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-pulse-backfill-\(UUID().uuidString)", isDirectory: true)
        var options = CostUsageScanner.Options(cacheRoot: tmp, daysToScan: Self.backfillDays)
        options.forceRescan = true   // not an init param — set after construction

        let result = await CostUsageScanner.scanAsync(options: options)
        if !result.entries.isEmpty {
            archive.mergeScanEntries(result.entries.map(Self.scanEntry))
            archive.lastUpdatedUnixMs = Self.nowMs()
            DailyUsageArchiveIO.save(archive, root: root)
        }
        try? FileManager.default.removeItem(at: tmp)   // discard the throwaway cache
        defaults.set(true, forKey: backfillKey)        // access was confirmed by caller — done
    }

    // MARK: - Adapters

    static func scanEntry(_ e: CostUsageScanResult.DailyEntry) -> ScanEntry {
        ScanEntry(
            date: e.date, provider: e.provider, model: e.model,
            inputTokens: e.inputTokens, cachedTokens: e.cachedTokens,
            outputTokens: e.outputTokens, cost: e.costUSD ?? 0, messages: e.messageCount)
    }

    static func cloudEntry(_ u: DailyUsage) -> CloudEntry {
        CloudEntry(
            date: u.date, provider: u.provider, model: u.model,
            inputTokens: u.inputTokens, cachedTokens: u.cachedTokens,
            outputTokens: u.outputTokens, cost: u.cost)
    }

    static func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded()) }
}
#endif
