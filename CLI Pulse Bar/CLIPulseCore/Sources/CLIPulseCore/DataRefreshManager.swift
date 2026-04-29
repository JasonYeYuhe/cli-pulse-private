import Foundation
import UserNotifications
import os
#if canImport(WidgetKit)
import WidgetKit
#endif
// UIApplication.registerForRemoteNotifications lives in UIKit; iOS-only.
#if canImport(UIKit) && os(iOS)
import UIKit
#endif

private let refreshLogger = Logger(subsystem: "com.clipulse", category: "DataRefresh")

@MainActor
internal final class DataRefreshManager {
    struct Context {
        let isAuthenticated: Bool
        let isDemoMode: Bool
        let isPaired: Bool
        let isLoading: Bool
        let notificationsEnabled: Bool
        let providerConfigs: [ProviderConfig]
        /// Snapshot of `state.providers` from the END of the previous refresh
        /// cycle. Used by `activeProviderCount` to compute the plan-limit
        /// warning at the START of THIS refresh — i.e. one cycle stale, but
        /// fine because plan-limit gating doesn't need real-time freshness.
        /// (See `activeProviderCount` doc for the dedup rule.)
        let providers: [ProviderUsage]
        let maxDevices: Int
        let maxProviders: Int
        let currentTierName: String
    }

    struct RefreshPayload {
        let dashboard: DashboardSummary
        let providers: [ProviderUsage]
        let sessions: [SessionRecord]
        let devices: [DeviceRecord]
        let alerts: [AlertRecord]
        let locallySupplementedProviders: Set<String>
        let tierLimitWarning: String?
        let lastRefresh: Date
        let isLocalMode: Bool
        let costUsageScanResult: CostUsageScanResult?
    }

    struct Callbacks {
        let isAuthenticated: () -> Bool
        let setLoading: (Bool) -> Void
        let setLastError: (String?) -> Void
        let setServerOnline: (Bool) -> Void
        let applyPayload: (RefreshPayload) -> Void
        let sendNotification: (AlertRecord) -> Void
        let afterRefresh: () -> Void
        let handleTokenExpired: (String) -> Void
        /// v1.9.3: returns the set of alert IDs the user resolved/snoozed
        /// locally so we don't re-fire them.
        let activeSuppressedAlertIDs: () async -> Set<String>
        /// v1.9.4: signal when the cost scan came up empty because the
        /// sandbox blocked the scanner roots → prompt user via banner.
        let setNeedsFolderAccess: (Bool) async -> Void
    }

    private let api: APIClient
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    /// Alert IDs we've already seen on a previous refresh cycle. New IDs —
    /// those NOT in this set — trigger a user notification at most once per
    /// "first appearance". Must survive cold launch, or every unresolved
    /// alert in the feed would re-fire every time the app is reopened
    /// (Codex v1.10.1 P2 finding). Backed by UserDefaults; bounded because
    /// the set is overwritten each cycle with only the IDs still in the
    /// feed (resolved/aged-out alerts drop off naturally).
    private static let previousAlertIDsKey = "cli_pulse_previous_alert_ids_v1"
    private static let previousSuppressionKeysKey = "cli_pulse_previous_alert_suppression_keys_v1"
    private var previousAlertIDs: Set<String> = {
        guard let arr = UserDefaults.standard.stringArray(forKey: DataRefreshManager.previousAlertIDsKey) else {
            return []
        }
        return Set(arr)
    }()
    /// v1.10.6: track suppression_key across cycles so a group of related
    /// alerts (e.g. repeated budget hits on one project, repeated CPU spikes)
    /// only fires a local notification the FIRST time it lands. Resets when
    /// the group stops appearing for a full refresh.
    private var previousSuppressionKeys: Set<String> = {
        guard let arr = UserDefaults.standard.stringArray(forKey: DataRefreshManager.previousSuppressionKeysKey) else {
            return []
        }
        return Set(arr)
    }()

    private func updatePreviousAlertIDs(_ ids: Set<String>) {
        previousAlertIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Self.previousAlertIDsKey)
    }

    private func updatePreviousSuppressionKeys(_ keys: Set<String>) {
        previousSuppressionKeys = keys
        UserDefaults.standard.set(Array(keys), forKey: Self.previousSuppressionKeysKey)
    }

    #if os(macOS)
    private var helperSyncObserver: NSObjectProtocol?
    #endif

    init(api: APIClient) {
        self.api = api
    }

    func refreshAll(context: Context, callbacks: Callbacks) async {
        guard context.isAuthenticated, !context.isDemoMode else { return }

        #if os(macOS)
        if !context.isPaired {
            await refreshLocal(context: context, callbacks: callbacks)
            return
        }
        #else
        // iter9 hotfix (2026-04-29): previously gated all iOS cloud
        // fetches on `context.isPaired`. That flag is set ONLY by the
        // external helper-daemon pairing handshake; the Mac menu-bar app
        // (which most users actually run) does not flip `paired = true`,
        // so signed-in iOS users with a working Mac collector saw a
        // permanent "Waiting for data" empty state — the cloud rows the
        // Mac app uploaded to `provider_quotas` / `daily_usage_metrics`
        // were never fetched on iOS. The product direction is
        // same-account auto-sync (no manual device pairing required), so
        // the gate is removed here. `dashboard_summary` and
        // `provider_summary` RPCs are already account-scoped (auth.uid()
        // via JWT bearer), so this is safe — RLS enforces account
        // isolation server-side. `paired` still has meaning for the
        // helper-daemon flow used by Remote Approvals; we just no longer
        // hide the dashboard behind it on iOS.
        #endif

        guard !context.isLoading else { return }
        callbacks.setLoading(true)
        callbacks.setLastError(nil)

        do {
            callbacks.setServerOnline(try await api.health())
        } catch {
            callbacks.setServerOnline(false)
            callbacks.setLastError("Server offline")
            callbacks.setLoading(false)
            return
        }

        guard !Task.isCancelled else {
            callbacks.setLoading(false)
            return
        }

        do {
            async let dashboard = api.dashboard()
            async let providers = api.providers()
            async let sessions = api.sessions()
            async let devices = api.devices()
            async let alerts = api.alerts()

            let (dashboardData, providerData, sessionData, deviceData, alertData) = try await (
                dashboard, providers, sessions, devices, alerts
            )

            #if os(macOS)
            // Sync credentials from bookmarked directories to app group
            // so both main app collectors and helper can use them
            CredentialBridge.syncCredentialsToAppGroup()

            var localResults = await runCollectors(providerConfigs: context.providerConfigs)

            // Supplement with helper's collector results from app group
            let helperResults = Self.readHelperCollectorResults()
            localResults.append(contentsOf: helperResults)

            // NOTE: intentionally do NOT dedup localResults here. The in-order
            // merge inside `mergeCloudWithLocal` preserves metadata via
            // `result.usage.metadata ?? existing.metadata` as successive
            // results for the same provider arrive — so main-app-set metadata
            // (e.g. supports_quota: true) survives even when a later helper
            // result has metadata == nil. A pre-merge dedup that kept only the
            // helper row dropped the metadata and made Codex fall off the
            // "quota provider" display branch (v1.9.4 regression — fixed by
            // removing that pre-merge dedup). Upsert-level dedup still
            // happens inside `APIClient.syncProviderQuotas` to avoid the
            // Postgres 21000 ON CONFLICT error.

            let (resolvedProviders, supplementedProviders) = Self.mergeCloudWithLocal(
                cloud: providerData,
                local: localResults
            )

            // Push locally-collected quotas to Supabase so other devices see fresh data
            if !localResults.isEmpty {
                Task { await api.syncProviderQuotas(localResults) }
            }

            // Scan local JSONL logs for precise token counts and costs.
            // v1.9.4: uses the sandbox-aware entry point so bookmarks are
            // resolved on the main actor before the enumerator runs.
            let costScanData = await CostUsageScanner.scanAsync()
            let scanResult: CostUsageScanResult? = costScanData.entries.isEmpty ? nil : costScanData
            // Surface the "grant folder access" banner when a scan came back
            // empty AND at least one core scan root still lacks a bookmark.
            let needsAccess = Self.needsFolderAccessNudge(scanIsEmpty: scanResult == nil)
            await callbacks.setNeedsFolderAccess(needsAccess)

            // Sync completed days to Supabase (non-blocking, best-effort)
            if let scanResult {
                Task { await self.api.syncDailyUsage(scanResult) }
            }

            #if DEBUG
            Self.dumpMergeDiagnostic(cloud: providerData, local: localResults, merged: resolvedProviders)
            #endif

            // v1.9.3: bridge JSONL scan → per-provider cost/token fields.
            let costAdjustedProviders = Self.applyCostScan(to: resolvedProviders, scan: scanResult)
            #else
            let costAdjustedProviders = providerData
            let supplementedProviders: Set<String> = []
            let scanResult: CostUsageScanResult? = nil
            #endif

            guard callbacks.isAuthenticated() else {
                callbacks.setLoading(false)
                return
            }

            let warning = Self.tierLimitWarning(
                deviceCount: deviceData.count,
                activeProviderCount: Self.activeProviderCount(
                    providers: context.providers,
                    providerConfigs: context.providerConfigs
                ),
                maxDevices: context.maxDevices,
                maxProviders: context.maxProviders,
                currentTierName: context.currentTierName
            )

            // v1.9.3: synthesise local quota-depletion alerts and merge them
            // into the alerts feed alongside cloud-supplied alerts. Stable IDs
            // (quota-<provider>-<tier>-<threshold>) prevent duplicates because
            // `previousAlertIDs` is updated every cycle below. Locally-resolved
            // or snoozed IDs are filtered via `activeSuppressedAlertIDs`.
            //
            // v1.10 P3-4: previously guarded `#if os(macOS)` so iOS never
            // surfaced locally-computed 80%/95% quota depletion alerts —
            // users only saw cloud-supplied alerts, which don't include the
            // threshold-crossing alerts that the client computes from the
            // provider quota/remaining fields. iOS receives `providers`
            // populated by the Supabase sync (same quota/remaining shape as
            // macOS), so `evaluateQuotaAlerts` works identically. Removed
            // the guard; `activeSuppressedAlertIDs` + `AlertThresholdsStore`
            // are both already cross-platform.
            var augmentedAlerts = alertData
            let suppressedIDs = await callbacks.activeSuppressedAlertIDs()
            let quotaAlertDicts = AlertGenerator.evaluateQuotaAlerts(
                providers: costAdjustedProviders,
                thresholds: AlertThresholdsStore.load().asArray
            )
            let existingIDs = Set(alertData.map(\.id))
            for dict in quotaAlertDicts {
                if let rec = AlertGenerator.makeAlertRecord(from: dict),
                   !existingIDs.contains(rec.id),
                   !suppressedIDs.contains(rec.id) {
                    augmentedAlerts.append(rec)
                }
            }

            // v1.10.6: dedupe by BOTH alert.id AND suppression_key. Groups
            // of related alerts sharing a suppression_key (same project,
            // same quota window, repeated CPU spikes) notify only once per
            // group until the group ages out of the feed. This prevents
            // "I know I'm working on this project, stop telling me" spam.
            var seenSuppressionThisCycle: Set<String> = previousSuppressionKeys
            let newAlerts = augmentedAlerts.filter { alert in
                guard !alert.is_resolved, !previousAlertIDs.contains(alert.id) else { return false }
                if let suppKey = alert.suppression_key, !suppKey.isEmpty {
                    if seenSuppressionThisCycle.contains(suppKey) { return false }
                    seenSuppressionThisCycle.insert(suppKey)
                }
                return true
            }
            if context.notificationsEnabled {
                for alert in newAlerts {
                    callbacks.sendNotification(alert)
                }
            }
            updatePreviousAlertIDs(Set(augmentedAlerts.map(\.id)))
            // Persist the suppression keys that are still ACTIVE in this cycle's
            // feed. Intentionally exclude resolved alerts — a resolved row can
            // linger in the feed for weeks (see `alerts` retention), and if we
            // kept its key we'd suppress a fresh alert that happens to share the
            // same suppression_key (e.g. same project re-exceeding budget). Keys
            // drop from the set when a group stops appearing OR all its alerts
            // get resolved, so a legit re-occurrence fires a notification again.
            updatePreviousSuppressionKeys(
                Set(augmentedAlerts
                    .filter { !$0.is_resolved }
                    .compactMap { $0.suppression_key }
                    .filter { !$0.isEmpty })
            )

            // Evaluate budget alerts server-side (non-blocking, best-effort)
            Task {
                _ = try? await api.evaluateBudgetAlerts()
            }

            callbacks.applyPayload(
                RefreshPayload(
                    dashboard: dashboardData,
                    providers: costAdjustedProviders,
                    sessions: sessionData,
                    devices: deviceData,
                    alerts: augmentedAlerts,
                    locallySupplementedProviders: supplementedProviders,
                    tierLimitWarning: warning,
                    lastRefresh: Date(),
                    isLocalMode: false,
                    costUsageScanResult: scanResult
                )
            )
            callbacks.afterRefresh()
        } catch let error as APIError where error == .tokenExpired {
            callbacks.handleTokenExpired(error.localizedDescription)
        } catch {
            callbacks.setLastError(error.localizedDescription)
        }

        callbacks.setLoading(false)
    }

    func startRefreshLoop(interval: Int, onRefreshRequested: @escaping @MainActor () async -> Void) {
        stopRefreshLoop()

        let effectiveInterval = max(TimeInterval(interval), 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: effectiveInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.requestRefresh(using: onRefreshRequested)
            }
        }

        #if os(macOS)
        observeHelperSync(onRefreshRequested: onRefreshRequested)
        #endif
    }

    func stopRefreshLoop() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        #if os(macOS)
        if let helperSyncObserver {
            DistributedNotificationCenter.default().removeObserver(helperSyncObserver)
            self.helperSyncObserver = nil
        }
        #endif
    }

    func cancelInFlightRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func updateRefreshInterval(_ seconds: Int, isAuthenticated: Bool, onRefreshRequested: @escaping @MainActor () async -> Void) {
        guard isAuthenticated else { return }
        startRefreshLoop(interval: seconds, onRefreshRequested: onRefreshRequested)
    }

    #if os(macOS)
    private func refreshLocal(context: Context, callbacks: Callbacks) async {
        guard !context.isLoading else { return }
        callbacks.setLoading(true)
        callbacks.setLastError(nil)
        callbacks.setServerOnline(true)

        let collectorResults = await runCollectors(providerConfigs: context.providerConfigs)
        let scanResult = await Task.detached { LocalScanner.shared.scan() }.value

        // Scan local JSONL logs for precise token counts and costs.
        // v1.9.4: sandbox-aware (resolves bookmarks on main actor first).
        let costScanData = await CostUsageScanner.scanAsync()
        let costScanResult: CostUsageScanResult? = costScanData.entries.isEmpty ? nil : costScanData
        let needsAccess = Self.needsFolderAccessNudge(scanIsEmpty: costScanResult == nil)
        await callbacks.setNeedsFolderAccess(needsAccess)

        // Sync completed days to Supabase (non-blocking, best-effort)
        if let costScanResult {
            Task { await self.api.syncDailyUsage(costScanResult) }
        }

        // Push locally-collected quotas to Supabase (even in unpaired/local mode)
        if !collectorResults.isEmpty {
            Task { await api.syncProviderQuotas(collectorResults) }
        }

        guard callbacks.isAuthenticated() else {
            callbacks.setLoading(false)
            return
        }

        var mergedProviders: [String: ProviderUsage] = [:]
        for provider in scanResult.providers {
            mergedProviders[provider.provider] = provider
        }
        for result in collectorResults {
            mergedProviders[result.usage.provider] = result.usage
        }

        let providersRaw = mergedProviders.values.sorted { $0.today_usage > $1.today_usage }
        // v1.9.3: bridge JSONL scan → per-provider cost/token fields.
        let providers = Self.applyCostScan(to: providersRaw, scan: costScanResult)
        let devices = [DeviceRecord(
            id: "local",
            name: ProcessInfo.processInfo.hostName,
            type: "macOS",
            system: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            status: "online",
            last_sync_at: sharedISO8601Formatter.string(from: Date()),
            helper_version: "local",
            current_session_count: scanResult.activeSessionCount,
            cpu_usage: nil,
            memory_usage: nil
        )]
        // v1.9.3: include local quota-depletion alerts in local-only mode too.
        var alerts: [AlertRecord] = []
        let suppressedIDsLocal = await callbacks.activeSuppressedAlertIDs()
        let quotaAlertDicts = AlertGenerator.evaluateQuotaAlerts(
            providers: providers,
            thresholds: AlertThresholdsStore.load().asArray
        )
        for dict in quotaAlertDicts {
            if let rec = AlertGenerator.makeAlertRecord(from: dict),
               !suppressedIDsLocal.contains(rec.id) {
                alerts.append(rec)
            }
        }

        let dashboard = DashboardSummary(
            total_usage_today: providers.reduce(0) { $0 + $1.today_usage },
            total_estimated_cost_today: providers.reduce(0) { $0 + $1.estimated_cost_today },
            cost_status: "Estimated",
            total_requests_today: scanResult.sessions.reduce(0) { $0 + $1.requests },
            active_sessions: scanResult.activeSessionCount,
            online_devices: 1,
            unresolved_alerts: 0,
            provider_breakdown: providers.map {
                ProviderBreakdown(provider: $0.provider, usage: $0.today_usage,
                                  estimated_cost: $0.estimated_cost_today,
                                  cost_status: $0.cost_status_today, remaining: $0.remaining)
            },
            top_projects: [],
            trend: [],
            recent_activity: [],
            risk_signals: scanResult.isEmpty && collectorResults.isEmpty
                ? ["No AI tools detected. Start a coding session to see data."] : [],
            alert_summary: AlertSummaryDTO(critical: 0, warning: 0, info: 0)
        )

        // v1.10.1 P2 fix (Gemini-caught): persist the IDs of alerts that are
        // actually in this local-mode refresh, NOT an empty set. Previously
        // this reset the dedupe cache, so a brief local-mode detour would
        // wipe UserDefaults and make the NEXT cloud refresh re-fire every
        // unresolved alert on cold launch or mode switch.
        updatePreviousAlertIDs(Set(alerts.map(\.id)))
        callbacks.applyPayload(
            RefreshPayload(
                dashboard: dashboard,
                providers: providers,
                sessions: scanResult.sessions,
                devices: devices,
                alerts: alerts,
                locallySupplementedProviders: [],
                tierLimitWarning: nil,
                lastRefresh: Date(),
                isLocalMode: true,
                costUsageScanResult: costScanResult
            )
        )
        callbacks.afterRefresh()
        callbacks.setLoading(false)
    }

    func runCollectors(providerConfigs: [ProviderConfig]) async -> [CollectorResult] {
        let enabledConfigs = providerConfigs.filter(\.isEnabled)
        var results: [CollectorResult] = []

        await withTaskGroup(of: CollectorResult?.self) { group in
            for config in enabledConfigs {
                guard let collector = CollectorRegistry.collector(for: config.kind, config: config) else { continue }
                group.addTask {
                    do {
                        return try await collector.collect(config: config)
                    } catch {
                        let message = "[Collector] \(config.kind.rawValue) failed: \(error.localizedDescription)"
                        if !Self.shouldSilenceCollectorError(kind: config.kind, error: error) {
                            refreshLogger.warning("\(message)")
                        }

                        let logPath = NSTemporaryDirectory() + "clipulse_collector_errors.log"
                        let entry = "\(sharedISO8601Formatter.string(from: Date())) \(message)\n"
                        if let fileHandle = FileHandle(forWritingAtPath: logPath) {
                            fileHandle.seekToEndOfFile()
                            fileHandle.write(entry.data(using: .utf8) ?? Data())
                            fileHandle.closeFile()
                        } else {
                            try? entry.write(toFile: logPath, atomically: true, encoding: .utf8)
                        }
                        return nil
                    }
                }
            }

            for await result in group {
                if let result {
                    results.append(result)
                }
            }
        }

        return results
    }

    /// Read collector results written by the helper daemon to app group UserDefaults.
    /// These results come from collectors that need real file system access (Codex, Gemini, etc.)
    /// which the sandboxed main app cannot do directly.
    nonisolated static func readHelperCollectorResults() -> [CollectorResult] {
        guard let data = HelperIPC.readCollectorResults(),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Reject stale data older than 5 minutes
        if let timestampStr = json["timestamp"] as? String,
           let timestamp = sharedISO8601Formatter.date(from: timestampStr) {
            if Date().timeIntervalSince(timestamp) > 300 {
                return [] // Data too old, skip
            }
        }

        // New format: { "timestamp": "...", "providers": { ... } }
        // Old format (no wrapper): { "Codex": { ... }, "Gemini": { ... } }
        let providers = (json["providers"] as? [String: Any]) ?? json

        var results: [CollectorResult] = []
        for (providerName, value) in providers {
            guard providerName != "timestamp" else { continue }
            guard let tierData = value as? [String: Any] else { continue }
            let quota = tierData["quota"] as? Int ?? 100
            let remaining = tierData["remaining"] as? Int ?? 100
            let todayUsage = tierData["today_usage"] as? Int ?? 0
            let weekUsage = tierData["week_usage"] as? Int ?? 0
            let statusText = tierData["status_text"] as? String
            let planType = tierData["plan_type"] as? String
            let resetTime = tierData["reset_time"] as? String

            var tiers: [TierDTO] = []
            if let tiersArr = tierData["tiers"] as? [[String: Any]] {
                for t in tiersArr {
                    tiers.append(TierDTO(
                        name: t["name"] as? String ?? "",
                        quota: t["quota"] as? Int ?? 100,
                        remaining: t["remaining"] as? Int ?? 0,
                        reset_time: t["reset_time"] as? String
                    ))
                }
            }

            // v1.9.4: always carry a minimal ProviderMetadata on helper-
            // bridged results. Previously this was nil and a later dedup
            // step could silently drop the main-app-set metadata that the
            // Providers card relies on (`supports_quota` drives the
            // "I/O tokens" display branch). Helper only emits `.quota` kind,
            // so `supports_quota: true` is safe.
            let meta = ProviderMetadata(
                display_name: providerName,
                category: "cloud",
                supports_exact_cost: false,
                supports_quota: true
            )
            let usage = ProviderUsage(
                provider: providerName,
                today_usage: todayUsage, week_usage: weekUsage,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: quota, remaining: remaining,
                plan_type: planType, reset_time: resetTime,
                tiers: tiers,
                status_text: statusText ?? "\(100 - remaining)% used",
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: meta
            )
            results.append(CollectorResult(usage: usage, dataKind: .quota))
        }
        return results
    }

    /// v1.9.4: returns true when the cost scan came back empty AND the
    /// sandbox hasn't been granted access to the scan roots — i.e. the user
    /// should be nudged to click "Grant access" in Settings. Called on the
    /// main actor because `BookmarkManager` is `@MainActor`-isolated.
    #if os(macOS)
    @MainActor
    static func needsFolderAccessNudge(scanIsEmpty: Bool) -> Bool {
        guard scanIsEmpty else { return false }
        // If at least one core scan root is missing a bookmark, surface the
        // banner. We check the two Claude variants and the two Codex roots;
        // nudge the user if ANY key root is unbookmarked (they only need one
        // to start getting data, but the banner drives them to Settings
        // where all four are listed).
        let missing = CostUsageScanner.missingScanRoots()
        return !missing.isEmpty
    }
    #endif

    /// v1.9.4: collapse multiple `CollectorResult`s for the same (provider,
    /// dataKind) into a single row, keeping the LAST occurrence. Used to
    /// normalise the main-app + helper result lists before merging or
    /// uploading — prevents SQLSTATE 21000 on Supabase upserts when the
    /// same provider's quota row appears twice.
    nonisolated static func dedupedByProvider(_ results: [CollectorResult]) -> [CollectorResult] {
        var seen: Set<String> = []
        var out: [CollectorResult] = []
        for r in results.reversed() {
            // Keys by provider name alone — the underlying provider_quotas
            // table is uniqued on (user_id, provider), and we don't want
            // `.quota` vs `.credits` for the same provider both going through.
            let key = r.usage.provider
            if seen.insert(key).inserted { out.append(r) }
        }
        return out.reversed()
    }

    nonisolated static func mergeCloudWithLocal(cloud: [ProviderUsage], local: [CollectorResult]) -> ([ProviderUsage], Set<String>) {
        var merged: [String: ProviderUsage] = [:]
        for provider in cloud {
            merged[provider.provider] = provider
        }

        var supplemented: Set<String> = []

        for result in local {
            guard result.dataKind == .quota || result.dataKind == .credits else { continue }

            let name = result.usage.provider
            if let existing = merged[name] {
                // Collector data is fresher than cloud cache for quota providers.
                // Preserve cloud activity/cost series, but always replace quota/tier state.
                let mergedQuota = result.usage.quota ?? existing.quota
                let mergedRemaining = result.usage.remaining ?? existing.remaining
                let mergedTiers = result.usage.tiers.isEmpty ? existing.tiers : result.usage.tiers

                // Use local/helper usage data when available; fall back to cloud
                let mergedTodayUsage = result.usage.today_usage > 0 ? result.usage.today_usage : existing.today_usage
                let mergedWeekUsage = result.usage.week_usage > 0 ? result.usage.week_usage : existing.week_usage

                merged[name] = ProviderUsage(
                    provider: existing.provider,
                    today_usage: mergedTodayUsage,
                    week_usage: mergedWeekUsage,
                    estimated_cost_today: existing.estimated_cost_today,
                    estimated_cost_week: existing.estimated_cost_week,
                    estimated_cost_30_day: existing.estimated_cost_30_day,
                    cost_status_today: existing.cost_status_today,
                    cost_status_week: existing.cost_status_week,
                    quota: mergedQuota,
                    remaining: mergedRemaining,
                    plan_type: result.usage.plan_type ?? existing.plan_type,
                    reset_time: result.usage.reset_time ?? existing.reset_time,
                    tiers: mergedTiers,
                    status_text: result.usage.status_text.isEmpty ? existing.status_text : result.usage.status_text,
                    trend: existing.trend,
                    recent_sessions: existing.recent_sessions,
                    recent_errors: existing.recent_errors,
                    metadata: result.usage.metadata ?? existing.metadata
                )
                supplemented.insert(name)
            } else {
                merged[name] = result.usage
                supplemented.insert(name)
            }
        }

        // Sort by today_usage desc, then provider name ascending as a stable
        // secondary key so equal usage values don't produce jittery UI order.
        return (
            merged.values.sorted {
                if $0.today_usage != $1.today_usage { return $0.today_usage > $1.today_usage }
                return $0.provider < $1.provider
            },
            supplemented
        )
    }

    /// v1.9.3: project per-provider token / cost from the JSONL scanner back
    /// into each `ProviderUsage` so cards show real numbers instead of the
    /// hardcoded `0 / "Unavailable"`. This is the bridge that codexbar uses.
    ///
    /// Behaviour:
    /// - For each provider in the scan, sum today's USD and week-to-date USD.
    /// - Replace `estimated_cost_today/week` and flip status to `"Estimated"`.
    /// - Token counts are exposed via `today_usage`/`week_usage` ONLY for
    ///   non-quota providers (where these fields are token counters); for quota
    ///   providers (Claude, Codex, Cursor) those fields are utilization %, so
    ///   we leave them alone.
    nonisolated static func applyCostScan(to providers: [ProviderUsage], scan: CostUsageScanResult?) -> [ProviderUsage] {
        applyCostScan(to: providers, scan: scan, now: Date())
    }

    /// Test-visible overload with injectable `now` so characterization tests
    /// aren't subject to midnight-rollover flakiness. Production callers use
    /// the no-argument form above, which defers to `Date()`.
    nonisolated static func applyCostScan(to providers: [ProviderUsage],
                                          scan: CostUsageScanResult?,
                                          now: Date) -> [ProviderUsage] {
        guard let scan, !scan.entries.isEmpty else { return providers }

        // v1.10 P2-6: date-window math centralised in `DateRange`.
        // Rolling week = today + previous 6 days inclusive (= 7 days).
        let todayKey   = DateRange.ymd(now)
        let weekCutoff = DateRange.rollingWeekStartYMD(from: now)

        struct Rollup { var todayCost: Double = 0; var weekCost: Double = 0
                        var todayTokens: Int = 0; var weekTokens: Int = 0 }
        var rollup: [String: Rollup] = [:]

        for entry in scan.entries {
            var r = rollup[entry.provider, default: Rollup()]
            // v1.9.4 second revision: uniform `input + output` for every
            // provider. Cache tokens excluded from the displayed count (cost
            // still uses full per-component pricing — see `AppState.totalTokens`
            // for the rationale).
            let entryTokens = entry.inputTokens + entry.outputTokens
            if entry.date == todayKey {
                r.todayCost += entry.costUSD ?? 0
                r.todayTokens += entryTokens
            }
            if entry.date >= weekCutoff {
                r.weekCost += entry.costUSD ?? 0
                r.weekTokens += entryTokens
            }
            rollup[entry.provider] = r
        }

        return providers.map { provider in
            guard let r = rollup[provider.provider] else { return provider }

            let isQuotaProvider = provider.metadata?.supports_quota ?? true
            let mergedTodayUsage = isQuotaProvider ? provider.today_usage : max(provider.today_usage, r.todayTokens)
            let mergedWeekUsage = isQuotaProvider ? provider.week_usage : max(provider.week_usage, r.weekTokens)

            // Combine local-scan + cloud cost so multi-device usage isn't
            // hidden by a smaller local roll-up. `max` avoids double-counting
            // because both sources represent the same window's total spend
            // (cloud-side aggregation already includes synced local data).
            let mergedCostToday = max(r.todayCost, provider.estimated_cost_today)
            let mergedCostWeek = max(r.weekCost, provider.estimated_cost_week)
            let statusToday = mergedCostToday > 0 ? "Estimated" : provider.cost_status_today
            let statusWeek = mergedCostWeek > 0 ? "Estimated" : provider.cost_status_week

            return ProviderUsage(
                provider: provider.provider,
                today_usage: mergedTodayUsage,
                week_usage: mergedWeekUsage,
                estimated_cost_today: mergedCostToday,
                estimated_cost_week: mergedCostWeek,
                estimated_cost_30_day: provider.estimated_cost_30_day,
                cost_status_today: statusToday,
                cost_status_week: statusWeek,
                quota: provider.quota,
                remaining: provider.remaining,
                plan_type: provider.plan_type,
                reset_time: provider.reset_time,
                tiers: provider.tiers,
                status_text: provider.status_text,
                trend: provider.trend,
                recent_sessions: provider.recent_sessions,
                recent_errors: provider.recent_errors,
                metadata: provider.metadata
            )
        }
    }

    nonisolated static func dumpMergeDiagnostic(cloud: [ProviderUsage], local: [CollectorResult], merged: [ProviderUsage]) {
        func snapshot(_ provider: ProviderUsage) -> [String: Any] {
            [
                "provider": provider.provider,
                "quota": provider.quota as Any,
                "remaining": provider.remaining as Any,
                "tiers_count": provider.tiers.count,
                "tiers": provider.tiers.map {
                    [
                        "name": $0.name,
                        "quota": $0.quota,
                        "remaining": $0.remaining,
                        "reset_time": $0.reset_time as Any,
                    ]
                },
                "plan_type": provider.plan_type as Any,
                "reset_time": provider.reset_time as Any,
                "today_usage": provider.today_usage,
            ]
        }

        let diagnostic: [String: Any] = [
            "timestamp": sharedISO8601Formatter.string(from: Date()),
            "cloud": cloud.map(snapshot),
            "local_collectors": local.map {
                [
                    "provider": $0.usage.provider,
                    "data_kind": String(describing: $0.dataKind),
                    "usage": snapshot($0.usage),
                ]
            },
            "merged": merged.map(snapshot),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys]),
           let string = String(data: data, encoding: .utf8) {
            try? string.write(
                toFile: NSTemporaryDirectory() + "clipulse_merge_diagnostic.json",
                atomically: true,
                encoding: .utf8
            )
        }
    }

    nonisolated private static func shouldSilenceCollectorError(kind: ProviderKind, error: Error) -> Bool {
        guard kind == .ollama else { return false }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain,
           [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost].contains(nsError.code) {
            return true
        }

        return nsError.localizedDescription == "Could not connect to the server."
    }

    private func observeHelperSync(onRefreshRequested: @escaping @MainActor () async -> Void) {
        helperSyncObserver = DistributedNotificationCenter.default().addObserver(
            forName: HelperIPC.didSyncNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.requestRefresh(using: onRefreshRequested)
            }
        }
    }
    #endif

    /// v1.10 P2-7 (+ v1.10.1 overlap audit): cancel any in-flight refresh
    /// stored in `refreshTask` before overwriting the handle — prevents a
    /// stacked queue when the scheduled timer fires during a long fetch
    /// or when a manual user-triggered refresh collides with either.
    ///
    /// Caveat: cooperative cancellation only SIGNALS the previous task;
    /// `onRefreshRequested` checks `Task.isCancelled` once early
    /// (see AppState.refreshAll) but network calls already in flight
    /// complete on their own. That's acceptable — the second launch will
    /// re-apply the payload, which is idempotent.
    ///
    /// Exposed as `internal` (not private) so AppState's public
    /// `requestRefresh()` can route manual refreshes through this same
    /// single-in-flight discipline.
    func requestRefresh(using onRefreshRequested: @escaping @MainActor () async -> Void) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            await onRefreshRequested()
        }
    }

    private static func tierLimitWarning(
        deviceCount: Int,
        activeProviderCount: Int,
        maxDevices: Int,
        maxProviders: Int,
        currentTierName: String
    ) -> String? {
        var warnings: [String] = []
        if maxDevices >= 0, deviceCount > maxDevices {
            warnings.append("Devices: \(deviceCount)/\(maxDevices)")
        }
        if maxProviders >= 0, activeProviderCount > maxProviders {
            warnings.append("Providers: \(activeProviderCount)/\(maxProviders)")
        }
        guard !warnings.isEmpty else { return nil }
        return "Over \(currentTierName) plan limits — \(warnings.joined(separator: ", ")). Upgrade or reduce usage."
    }

    /// "Active providers" for plan-limit gating purposes. Counts distinct
    /// `ProviderKind`s where any of:
    ///   (a) the server-reported `ProviderUsage` row shows non-zero usage
    ///       this period (today_usage / week_usage / cost), OR
    ///   (b) the local `ProviderConfig` is enabled AND has credentials
    ///       configured (apiKey or cookieSource).
    ///
    /// Why this exists: `providerConfigs.filter(\.isEnabled).count` was the
    /// previous gating signal. `ProviderConfig.defaults()` enables ALL 26
    /// known ProviderKinds, so users on the free plan saw "Providers: 26/3"
    /// after a fresh launch even when their actual provider usage was
    /// just Ollama + Claude. The toggles count is also the wrong thing for
    /// the plan-limit warning conceptually — the toggles are a UI grid, the
    /// plan limit caps actual billable provider usage.
    ///
    /// Dedup is keyed on `ProviderKind` (not raw string) so:
    ///   - Ollama with 20 local models → 1 (server collapses sessions to
    ///     one provider="Ollama" row already; we count it as 1 here)
    ///   - "Claude" string from server + Claude config with API key → 1
    ///   - same provider visible via 2 Macs (multi-device) → 1 (server
    ///     `provider_quotas` is keyed on (user_id, provider) UNIQUE, so
    ///     this is already deduped at the data layer)
    /// Server provider rows whose `provider` string doesn't map to any
    /// `ProviderKind` (legacy / typo / unknown future kind) are silently
    /// skipped — we'd rather undercount than over-warn the user.
    ///
    /// Note this is an "active providers" count for the WARNING surface
    /// only. `migrateProviderLimitsIfNeeded` continues to operate on the
    /// raw enabled-toggle count because that controls UI grid pruning,
    /// which is a different concern (Settings → Providers grid behaviour).
    nonisolated static func activeProviderCount(
        providers: [ProviderUsage],
        providerConfigs: [ProviderConfig]
    ) -> Int {
        var active = Set<ProviderKind>()

        // (a) server-side rows with any usage signal in the current period.
        for usage in providers {
            let hasUsage = usage.today_usage > 0
                || usage.week_usage > 0
                || usage.estimated_cost_today > 0
                || usage.estimated_cost_week > 0
            guard hasUsage else { continue }
            // Map raw provider string → canonical ProviderKind via Codable
            // raw-value lookup. Unknown strings drop out.
            if let kind = ProviderKind(rawValue: usage.provider) {
                active.insert(kind)
            }
        }

        // (b) local configs the user actively configured credentials for —
        // a provider that has credentials but no usage YET still counts
        // toward the plan limit (the user is set up to use it).
        for config in providerConfigs where config.isEnabled && config.hasCredentials {
            active.insert(config.kind)
        }

        return active.count
    }
}

extension AppState {
    public func refreshAll() async {
        await dataRefreshManager.refreshAll(context: refreshContext(), callbacks: refreshCallbacks())
        // Let platform bridges (notably iOS's PhoneSessionManager) forward the
        // freshly-loaded snapshot to the Apple Watch via WCSession. No userInfo
        // — observers pull the current @Published values from AppState.
        NotificationCenter.default.post(name: .cliPulseDidRefresh, object: self)
    }

    /// v1.10.1 manual-refresh overlap fix: user-triggered refreshes (toolbar
    /// buttons, menu command) should share the same single-in-flight
    /// discipline as the timer-driven refreshRequest path. Routing through
    /// `dataRefreshManager.requestRefresh` cancels any prior refreshTask
    /// before launching the new one, preventing stacked overlapping fetches
    /// when the user taps refresh while a timer-scheduled refresh is still
    /// in flight (or vice versa).
    ///
    /// Fire-and-forget by design — the Task is owned by DataRefreshManager.
    /// Do not `await` this; the Button is already disabled via `isLoading`.
    @MainActor
    public func requestRefresh() {
        dataRefreshManager.requestRefresh(using: refreshRequest())
    }

    #if os(macOS)
    /// v1.9.4: wipe the scanner cache and rebuild it from scratch. Use when
    /// the user has just granted a new bookmark, since prior sandbox-blocked
    /// runs may have recorded negative deltas that incremental scanning
    /// wouldn't undo.
    public func forceRescanTokenCache() async {
        let fresh = await CostUsageScanner.forceRescanAsync()
        costUsageScanResult = fresh.entries.isEmpty ? nil : fresh
        // Kick a full refresh so provider cards pick up the new data.
        await refreshAll()
    }
    #endif

    public func acknowledgeAlert(_ alert: AlertRecord) async {
        if isDemoMode {
            if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
                alerts[idx] = demoUpdateAlert(
                    alerts[idx],
                    isRead: true,
                    acknowledgedAt: sharedISO8601Formatter.string(from: Date())
                )
            }
            return
        }
        do {
            _ = try await api.acknowledgeAlert(id: alert.id)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func resolveAlert(_ alert: AlertRecord) async {
        await resolveAlert(alert, skipRefresh: false)
    }

    /// v1.10.6: internal variant that skips the full `refreshAll()` at the end.
    /// Used by `resolveAlerts(_:)` to batch N resolves into a single refresh —
    /// otherwise "Resolve All" would issue N back-to-back network fetches.
    private func resolveAlert(_ alert: AlertRecord, skipRefresh: Bool) async {
        // Locally-generated alerts (id prefix `quota-`) don't exist server-side,
        // so `api.resolveAlert` would no-op and the alert would re-fire on the
        // next quota evaluation. Persist a permanent local suppression instead.
        if alert.id.hasPrefix("quota-") {
            suppressAlert(id: alert.id, until: .distantFuture)
            if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
                alerts.remove(at: idx)
            }
            return
        }
        if isDemoMode {
            if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
                alerts[idx] = demoUpdateAlert(alerts[idx], isRead: true, isResolved: true)
            }
            return
        }
        do {
            _ = try await api.resolveAlert(id: alert.id)
            if !skipRefresh {
                await refreshAll()
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// v1.10.6: resolve a batch of alerts with a single terminal refresh.
    /// "Resolve All" on both macOS and iOS calls this. The per-alert network
    /// writes run concurrently; the UI refreshes exactly once at the end.
    public func resolveAlerts(_ alertsToResolve: [AlertRecord]) async {
        guard !alertsToResolve.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for alert in alertsToResolve {
                group.addTask { [weak self] in
                    await self?.resolveAlert(alert, skipRefresh: true)
                }
            }
        }
        // Skip the final refresh for demo mode (no network) and when the batch
        // was entirely local `quota-*` suppressions (handled in-memory above).
        let needsRefresh = !isDemoMode && alertsToResolve.contains { !$0.id.hasPrefix("quota-") }
        if needsRefresh {
            await refreshAll()
        }
    }

    public func snoozeAlert(_ alert: AlertRecord, minutes: Int) async {
        if alert.id.hasPrefix("quota-") {
            suppressAlert(id: alert.id, until: Date().addingTimeInterval(Double(minutes) * 60))
            if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
                alerts.remove(at: idx)
            }
            return
        }
        if isDemoMode {
            if let idx = alerts.firstIndex(where: { $0.id == alert.id }) {
                let until = sharedISO8601Formatter.string(from: Date().addingTimeInterval(Double(minutes) * 60))
                alerts[idx] = demoUpdateAlert(alerts[idx], isRead: true, snoozedUntil: until)
            }
            return
        }
        do {
            _ = try await api.snoozeAlert(id: alert.id, minutes: minutes)
            await refreshAll()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Local alert suppression helpers (v1.9.3, extended v1.9.7 P1-3)

    /// Persist a local-only suppression for an alert ID. `Date.distantFuture`
    /// means "never reappear" (until threshold ratchets up, which makes a new ID).
    /// v1.9.7 P1-3: records `dismissedAt = now` so distantFuture entries can
    /// be recycled after `permanentSuppressionRetentionDays`.
    public func suppressAlert(id: String, until: Date, now: Date = Date()) {
        suppressedAlertIDs[id] = SuppressionEntry(until: until, dismissedAt: now)
        saveSuppressedAlertIDs()
    }

    /// Currently-active local suppressions (i.e. not expired). Side-effect:
    /// expired entries are pruned from `suppressedAlertIDs`.
    ///
    /// Two separate TTL rules:
    ///   - **Time-boxed** entries (e.g. "snooze for 60 minutes") expire when
    ///     `now >= until`.
    ///   - **Permanent** entries (`until == .distantFuture`) expire when
    ///     `now >= dismissedAt + permanentSuppressionRetentionDays`, so stale
    ///     IDs don't accumulate in UserDefaults forever.
    public func activeSuppressedAlertIDs(now: Date = Date()) -> Set<String> {
        let before = suppressedAlertIDs.count
        let result = Self.prunedSuppressions(suppressedAlertIDs, now: now)
        suppressedAlertIDs = result.kept
        if suppressedAlertIDs.count != before { saveSuppressedAlertIDs() }
        return result.active
    }

    public func saveSuppressedAlertIDs() {
        // v2 schema: [id: [until_ts, dismissedAt_ts]].
        let payload = suppressedAlertIDs.mapValues { entry in
            [entry.until.timeIntervalSince1970, entry.dismissedAt.timeIntervalSince1970]
        }
        UserDefaults.standard.set(payload, forKey: Self.suppressedAlertsV2Key)
        // Clear the old v1 key so it stops re-seeding stale data on downgrade+upgrade.
        UserDefaults.standard.removeObject(forKey: Self.suppressedAlertsKey)
    }

    public func loadSuppressedAlertIDs() {
        // Prefer v2. Each value is [until_ts, dismissedAt_ts].
        if let dict = UserDefaults.standard.dictionary(forKey: Self.suppressedAlertsV2Key) as? [String: [Double]] {
            suppressedAlertIDs = dict.compactMapValues { pair in
                guard pair.count == 2 else { return nil }
                return SuppressionEntry(
                    until: Date(timeIntervalSince1970: pair[0]),
                    dismissedAt: Date(timeIntervalSince1970: pair[1])
                )
            }
            return
        }
        // v1 fallback: [id: until_ts]. No dismissedAt on disk, so stamp it
        // as "now" — worst case, distantFuture entries get the full 180-day
        // grace period starting now, which is acceptable for migration.
        guard let v1Dict = UserDefaults.standard.dictionary(forKey: Self.suppressedAlertsKey) as? [String: Double] else { return }
        let migratedAt = Date()
        suppressedAlertIDs = v1Dict.mapValues { ts in
            SuppressionEntry(
                until: Date(timeIntervalSince1970: ts),
                dismissedAt: migratedAt
            )
        }
        saveSuppressedAlertIDs()  // writes v2 + removes v1
    }

    public func startRefreshLoop() {
        dataRefreshManager.startRefreshLoop(interval: refreshInterval, onRefreshRequested: refreshRequest())
    }

    public func stopRefreshLoop() {
        dataRefreshManager.stopRefreshLoop()
    }

    public func updateRefreshInterval(_ seconds: Int) {
        refreshInterval = seconds
        dataRefreshManager.updateRefreshInterval(
            seconds,
            isAuthenticated: isAuthenticated,
            onRefreshRequested: refreshRequest()
        )
    }

    /// Ask the user for local notification permission and (on iOS) trigger
    /// APNs registration on grant.
    ///
    /// Auth contract (iter8 hotfix): pre-auth callers used to surface a
    /// "Session expired" error on the login screen because the APNs
    /// registration that follows here would race the JWT and fail.
    /// We now refuse to even prompt unless the user is signed in, so
    /// the system permission alert never appears for unauthenticated
    /// launches. Callers (toggling Remote Control on, post-auth replay
    /// from `applyAuthenticatedState`) gate on the right product moment.
    public func requestNotificationPermission() {
        guard isAuthenticated else {
            // Don't prompt unauthenticated users — they have no use for
            // remote approvals yet, and the downstream
            // registerForRemoteNotifications → syncPushToken chain would
            // otherwise hit the server without a JWT. The
            // pendingPushTokenRegistration cache covers users who DID
            // somehow get a token delivered (e.g. permission was granted
            // on a previous install) — `flushPendingPushTokenIfAvailable`
            // replays after auth.
            return
        }
        // xctest defense: UNUserNotificationCenter.requestAuthorization
        // depends on a usernotificationsd connection that doesn't exist
        // (or hangs) inside a headless xctest binary, so any test that
        // sets up an authenticated AppState and triggers this path would
        // hang the suite. Detect xctest via the standard env var Apple
        // sets and short-circuit there.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return
        }
        // iter10 hotfix (2026-04-29): only call `requestAuthorization`
        // when the system status is `.notDetermined`. After the user has
        // granted or denied once, iOS will never re-show the system
        // dialog regardless of how many times we call it — but going
        // through the full request path on every Remote-Control toggle
        // is wasteful and (more importantly) closes the door on any
        // future regression where a callsite mistakenly fires this in
        // a loop (e.g. a tier-change observer or a refresh-cycle
        // callback). On `.authorized` we skip straight to APNs
        // registration; on `.denied` we no-op so we don't keep nagging
        // the platform; on `.notDetermined` we run the original prompt.
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    // v0.32: also register for APNs so Remote Approvals can push.
                    // Only meaningful on iOS (UIApplication is iOS-only); macOS
                    // uses local notifications only for now. We register
                    // unconditionally on permission grant — the registered token
                    // is only USED server-side when remoteControlEnabled=true,
                    // and the registration cost is essentially free if Remote
                    // Control is off (token sits in app_push_tokens but no push
                    // ever fires).
                    #if os(iOS)
                    guard granted else { return }
                    DispatchQueue.main.async {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                    #else
                    _ = granted
                    #endif
                }
            case .authorized, .provisional, .ephemeral:
                // Already-granted state: skip the request (which would be
                // a no-op anyway) and go directly to APNs registration so
                // a fresh install/reinstall picks up the existing grant.
                #if os(iOS)
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
                #endif
            case .denied:
                // User has explicitly denied. Never re-ask.
                break
            @unknown default:
                break
            }
        }
    }

    func updateCostSummary() {
        // Calculate subscription costs from enabled providers' plan_type
        let subscriptions = calculateSubscriptions()
        let subTotal = subscriptions.reduce(0) { $0 + $1.monthlyCost }

        if let scan = costUsageScanResult, !scan.entries.isEmpty {
            // Use precise data from local JSONL log scanning
            let cal = Calendar.current
            let now = Date()
            let todayComps = cal.dateComponents([.year, .month, .day], from: now)
            let todayKey = String(format: "%04d-%02d-%02d", todayComps.year ?? 1970, todayComps.month ?? 1, todayComps.day ?? 1)
            let todayEntries = scan.entries.filter { $0.date == todayKey }
            var todayByProv: [String: Double] = [:]
            for entry in todayEntries {
                todayByProv[entry.provider, default: 0] += entry.costUSD ?? 0
            }
            for provider in providers where todayByProv[provider.provider] == nil && provider.estimated_cost_today > 0 {
                todayByProv[provider.provider] = provider.estimated_cost_today
            }
            let todayByProvider = todayByProv.map { ($0.key, $0.value) }
            let todayTotal = todayByProv.values.reduce(0, +)

            var thirtyDayByProv: [String: Double] = [:]
            for entry in scan.entries {
                thirtyDayByProv[entry.provider, default: 0] += entry.costUSD ?? 0
            }
            // v1.10.6: prefer the real 30-day cost from the server (sourced
            // from `daily_usage_metrics`) over the old week*4.3 extrapolation.
            // Fall back to week*4.3 only for older clients / providers whose
            // server-side 30-day sum is missing.
            for provider in providers where thirtyDayByProv[provider.provider] == nil {
                if provider.estimated_cost_30_day > 0 {
                    thirtyDayByProv[provider.provider] = provider.estimated_cost_30_day
                } else if provider.estimated_cost_week > 0 {
                    thirtyDayByProv[provider.provider] = provider.estimated_cost_week * 4.3
                }
            }
            let thirtyDayByProvider = thirtyDayByProv.map { ($0.key, $0.value) }
            let thirtyDayTotal = thirtyDayByProv.values.reduce(0, +)

            // Token totals
            let todayTokens = scan.totalTokens(for: todayKey)
            let thirtyDayTokens = scan.totalTokens

            // Subscription utilization (API equiv cost vs subscription price)
            let utilization: [SubscriptionUtilization] = subscriptions.compactMap { sub in
                let apiCost = scan.totalCostForProvider(sub.provider)
                guard sub.monthlyCost > 0 else { return nil }
                return SubscriptionUtilization(
                    provider: sub.provider, plan: sub.plan,
                    apiEquivCost: apiCost, subscriptionCost: sub.monthlyCost)
            }.sorted { $0.utilizationPercent > $1.utilizationPercent }

            // Per-model cost breakdown. v1.9.4 (second revision): skip the
            // synthetic `__claude_msg__` bucket — it's a raw-event counter,
            // not a real model, and would render as a literal "__claude_msg__"
            // row in the By Model section.
            var modelAgg: [String: (cost: Double, input: Int, output: Int, cached: Int)] = [:]
            for entry in scan.entries {
                // Use the string literal so this compiles on iOS (where
                // CostUsageScanner is macOS-only). Kept in sync with the
                // scanner constant; if it changes, update both places.
                if entry.model == "__claude_msg__" { continue }
                let key = entry.model.isEmpty ? entry.provider : entry.model
                var agg = modelAgg[key, default: (0, 0, 0, 0)]
                agg.cost += entry.costUSD ?? 0
                agg.input += entry.inputTokens
                agg.output += entry.outputTokens
                agg.cached += entry.cachedTokens
                modelAgg[key] = agg
            }
            let costByModel = modelAgg.map { ModelCostDetail(
                model: $0.key, cost: $0.value.cost,
                inputTokens: $0.value.input, outputTokens: $0.value.output,
                cachedTokens: $0.value.cached
            )}.sorted { $0.cost > $1.cost }

            costSummary = CostSummary(
                todayTotal: todayTotal,
                todayByProvider: todayByProvider,
                thirtyDayTotal: thirtyDayTotal,
                thirtyDayByProvider: thirtyDayByProvider,
                isPrecise: true,
                subscriptionTotal: subTotal,
                subscriptionByProvider: subscriptions,
                grandTotal: subTotal + thirtyDayTotal,
                todayTokens: todayTokens,
                thirtyDayTokens: thirtyDayTokens,
                utilization: utilization,
                costByModel: costByModel
            )
            return
        }

        // Fallback: use API-provided estimates.
        // v1.10.6: use the server's real 30-day cost from daily_usage_metrics
        // when available; fall back to `week * 4.3` for older servers.
        let todayByProvider = providers.map { ($0.provider, $0.estimated_cost_today) }
        let todayTotal = todayByProvider.reduce(0) { $0 + $1.1 }
        let thirtyDayByProvider = providers.map { provider -> (String, Double) in
            if provider.estimated_cost_30_day > 0 {
                return (provider.provider, provider.estimated_cost_30_day)
            }
            return (provider.provider, provider.estimated_cost_week * 4.3)
        }
        let thirtyDayTotal = thirtyDayByProvider.reduce(0) { $0 + $1.1 }

        // v1.10.7: derive Subscription Utilization from the 30-day fallback
        // totals so iPhone (cloud-only) and any other client without a local
        // JSONL scan can still render the Utilization section of the Cost
        // Summary card. The local-scan branch above already populates this
        // precisely; this is the estimate path.
        let thirtyDayLookup = thirtyDayByProvider.reduce(into: [String: Double]()) {
            $0[$1.0, default: 0] += $1.1
        }
        let utilization: [SubscriptionUtilization] = subscriptions.compactMap { sub in
            guard sub.monthlyCost > 0 else { return nil }
            let apiCost = thirtyDayLookup[sub.provider] ?? 0
            return SubscriptionUtilization(
                provider: sub.provider,
                plan: sub.plan,
                apiEquivCost: apiCost,
                subscriptionCost: sub.monthlyCost
            )
        }.sorted { $0.utilizationPercent > $1.utilizationPercent }

        costSummary = CostSummary(
            todayTotal: todayTotal,
            todayByProvider: todayByProvider,
            thirtyDayTotal: thirtyDayTotal,
            thirtyDayByProvider: thirtyDayByProvider,
            isPrecise: false,
            subscriptionTotal: subTotal,
            subscriptionByProvider: subscriptions,
            grandTotal: subTotal + thirtyDayTotal,
            utilization: utilization
        )
    }

    private func calculateSubscriptions() -> [(provider: String, plan: String, monthlyCost: Double)] {
        let enabledNames = Set(providerConfigs.filter(\.isEnabled).map(\.kind.rawValue))
        var result: [(provider: String, plan: String, monthlyCost: Double)] = []
        for provider in providers where enabledNames.contains(provider.provider) {
            if let plan = provider.plan_type,
               let cost = SubscriptionPricing.monthlyCost(provider: provider.provider, plan: plan),
               cost > 0 {
                result.append((provider: provider.provider, plan: plan, monthlyCost: cost))
            }
        }
        return result.sorted { $0.monthlyCost > $1.monthlyCost }
    }

    func publishWidgetData() {
        guard let defaults = UserDefaults(suiteName: "group.yyh.CLI-Pulse") else { return }

        struct WidgetProviderData: Codable {
            let name: String
            let usage: Int
            let quota: Int?
            let costToday: Double
            let iconName: String
        }

        struct WidgetData: Codable {
            let totalUsageToday: Int
            let totalCostToday: Double
            let activeSessions: Int
            let unresolvedAlerts: Int
            let providers: [WidgetProviderData]
            let lastUpdated: Date
        }

        let widgetProviders = providers.prefix(10).map { provider in
            WidgetProviderData(
                name: provider.provider,
                usage: provider.today_usage,
                quota: provider.quota,
                costToday: provider.estimated_cost_today,
                iconName: provider.providerKind?.iconName ?? "cpu"
            )
        }

        let data = WidgetData(
            totalUsageToday: dashboard?.total_usage_today ?? 0,
            totalCostToday: dashboard?.total_estimated_cost_today ?? 0,
            activeSessions: dashboard?.active_sessions ?? 0,
            unresolvedAlerts: alerts.filter { !$0.is_resolved }.count,
            providers: Array(widgetProviders),
            lastUpdated: Date()
        )

        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: "widgetData")
        }

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    func sendNotification(for alert: AlertRecord) {
        let content = UNMutableNotificationContent()
        content.title = "CLI Pulse: \(alert.severity)"
        content.body = alert.title
        content.sound = alert.alertSeverity == .critical ? .defaultCritical : .default

        let request = UNNotificationRequest(identifier: alert.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)

        // Iter2: webhook fan-out moved server-side (alerts INSERT trigger →
        // webhook_jobs → cron → edge). Inline call here is retained behind
        // a kill-switch only so we can disable the trigger and re-enable
        // client delivery without a rebuild. Default `true` means: trust
        // the server. Migration v0.25 needs to be live before flipping
        // this to false for any user.
        if !serverSideWebhookEnabled, webhookEnabled, !webhookURL.isEmpty {
            Task {
                try? await api.sendWebhook(alert: alert)
            }
        }
    }

    /// Push webhook settings to the server.
    public func pushSettingsToServer() {
        Task {
            do {
                let filter = webhookEventFilter.isEmpty ? nil : webhookEventFilter
                try await api.updateSettings(APIClient.SettingsPatch(
                    webhook_url: webhookURL.isEmpty ? nil : webhookURL,
                    webhook_enabled: webhookEnabled,
                    webhook_event_filter: filter
                ))
            } catch {
                lastError = "Failed to save webhook settings: \(error.localizedDescription)"
            }
        }
    }

    /// Send a test webhook to verify the user's URL works.
    public func testWebhook() async {
        do {
            let testAlert = AlertRecord(
                id: "test-\(UUID().uuidString.prefix(8))",
                type: "Test", severity: "Info",
                title: "CLI Pulse webhook test",
                message: "If you see this, your webhook integration is working correctly.",
                created_at: sharedISO8601Formatter.string(from: Date()),
                is_read: false, is_resolved: false,
                acknowledged_at: nil, snoozed_until: nil,
                related_project_id: nil, related_project_name: nil,
                related_session_id: nil, related_session_name: nil,
                related_provider: nil, related_device_name: nil
            )
            try await api.sendWebhook(alert: testAlert)
        } catch {
            lastError = "Webhook test failed: \(error.localizedDescription)"
        }
    }

    func applyRefreshPayload(_ payload: DataRefreshManager.RefreshPayload) {
        dashboard = payload.dashboard
        providers = payload.providers
        sessions = payload.sessions
        devices = payload.devices
        alerts = payload.alerts
        locallySupplementedProviders = payload.locallySupplementedProviders
        tierLimitWarning = payload.tierLimitWarning
        lastRefresh = payload.lastRefresh
        isLocalMode = payload.isLocalMode
        costUsageScanResult = payload.costUsageScanResult
    }

    func completeRefresh() {
        buildProviderDetails()
        updateCostSummary()
        // v1.9.4: overwrite server-side dashboard fields that the server
        // can't know about yet (today's data isn't uploaded via
        // `syncDailyUsage` until the day rolls over). The local scan IS
        // today-accurate, so prefer it for the Overview top cards so they
        // stop disagreeing with the Cost Summary card below.
        if let dash = dashboard {
            let localTodayCost = costSummary.todayTotal
            let localTodayTokens = costSummary.todayTokens
            // v1.10.7: when the cloud dashboard ships an empty
            // `provider_breakdown` (today's Supabase `dashboard_summary` RPC
            // does not populate it), synthesise it from the per-provider
            // `providers` array so iOS/cloud-only clients can render the
            // Overview "Provider Usage" card. Runs independently of the
            // local-today rebuild below; both paths share `rebuiltBreakdown`.
            let rebuiltBreakdown: [ProviderBreakdown] = {
                if !dash.provider_breakdown.isEmpty { return dash.provider_breakdown }
                if providers.isEmpty { return dash.provider_breakdown }
                return providers.map {
                    ProviderBreakdown(
                        provider: $0.provider,
                        usage: $0.today_usage,
                        estimated_cost: $0.estimated_cost_today,
                        cost_status: $0.cost_status_today,
                        remaining: $0.remaining
                    )
                }
            }()
            let breakdownChanged = rebuiltBreakdown.count != dash.provider_breakdown.count
            if localTodayCost > 0 || localTodayTokens > 0 || breakdownChanged {
                dashboard = DashboardSummary(
                    total_usage_today: localTodayTokens > 0 ? localTodayTokens : dash.total_usage_today,
                    total_estimated_cost_today: localTodayCost > 0 ? localTodayCost : dash.total_estimated_cost_today,
                    cost_status: localTodayCost > 0 ? "Estimated" : dash.cost_status,
                    total_requests_today: dash.total_requests_today,
                    active_sessions: dash.active_sessions,
                    online_devices: dash.online_devices,
                    unresolved_alerts: dash.unresolved_alerts,
                    provider_breakdown: rebuiltBreakdown,
                    top_projects: dash.top_projects,
                    trend: dash.trend,
                    recent_activity: dash.recent_activity,
                    risk_signals: dash.risk_signals,
                    alert_summary: dash.alert_summary
                )
            }
        }
        publishWidgetData()
        Task { await refreshCostForecast() }
        Task { await refreshYieldScore() }
        // v0.26 Phase 1: only fetch pending approvals when the feature is on.
        // refreshYieldScore() above re-syncs `remoteControlEnabled` from
        // user_settings on every cycle, so a remote toggle eventually reaches
        // the UI within one refresh interval (~120s).
        Task { await refreshRemoteApprovals() }
    }

    private func refreshCostForecast() async {
        let usage = await api.fetchDailyUsage(days: 30)
        dailyUsage = usage
        costForecast = CostForecastEngine.forecast(from: usage)
    }

    /// Pull last 90 days of daily yield rollups so the UI can re-aggregate
    /// over any of the supported windows (7/30/90) without an extra round trip.
    /// Also re-syncs the user's track_git_activity opt-in from the server.
    private func refreshYieldScore() async {
        let rows = await api.fetchYieldScoreDaily(days: 90)
        yieldScoreDailyRows = rows
        if let snapshot = try? await api.settings() {
            gitTrackingEnabled = snapshot.track_git_activity
            // Skip overwriting remoteControlEnabled while a toggle PATCH is
            // mid-flight — the snapshot may have been read before the user's
            // latest intent reached the server, and writing it back here
            // would silently undo the toggle (Codex review iter5 P1
            // latest-intent-wins). Once setRemoteControlEnabled clears
            // `remoteControlSaving`, the next refresh cycle will pick up the
            // canonical server value.
            //
            // iter8: deliberately NO requestNotificationPermission() side-
            // effect from this branch. The permission prompt only fires from
            // explicit user action (setRemoteControlEnabled(true) on
            // toggle ON). Returning users with RC pre-enabled who haven't
            // yet granted notification permission re-toggle in Settings to
            // trigger it — the slightly-staler UX is intentional, both for
            // testability (UNUserNotificationCenter blocks in xctest
            // environments without a UI) and for explicit-consent posture.
            if !remoteControlSaving {
                remoteControlEnabled = snapshot.remote_control_enabled
            }
        }
    }

    /// Push the user's git tracking opt-in to the server. Caller is responsible
    /// for showing a privacy disclosure dialog on first enable.
    public func pushGitTrackingSettingToServer() {
        Task {
            do {
                try await api.updateSettings(APIClient.SettingsPatch(
                    track_git_activity: gitTrackingEnabled
                ))
            } catch {
                lastError = "Failed to save git tracking setting: \(error.localizedDescription)"
            }
        }
    }

    /// Register an APNs push token to this user on the server. Idempotent.
    /// Called by the iOS AppDelegate from
    /// `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`.
    ///
    /// Auth contract (iter8 hotfix):
    ///   * If NOT authenticated, cache the (token, platform, bundleId) tuple
    ///     in `pendingPushTokenRegistration` and return silently. Never
    ///     surface "Session expired" on the login screen — that error chain
    ///     was the previous behaviour and it shadowed the real sign-in flow.
    ///   * After auth (`applyAuthenticatedState` → `flushPendingPushTokenIfAvailable`)
    ///     we replay the cached tuple so the token reaches the server without
    ///     requiring an app relaunch.
    ///
    /// Remote Control posture (unchanged from iter7):
    ///   * We register the token regardless of `remoteControlEnabled`.
    ///     Server-side gate (trigger + edge function) decides whether
    ///     APNs traffic actually fires. The token sitting in
    ///     `app_push_tokens` is inert metadata while the gate is off.
    ///
    /// APNs token lifetime (why we cache):
    ///   APNs delivers the device token once per launch via the didRegister
    ///   callback. If we silently drop it before auth, the user would have
    ///   to relaunch the app post-login to get push working.
    public func syncPushToken(token: String, platform: String, bundleId: String) {
        guard PushTokenSync.isValidTokenLength(token),
              PushTokenSync.isValidBundleId(bundleId) else {
            return
        }
        // Auth guard. Cache the token so a post-auth replay can register it
        // without needing iOS to redeliver. NEVER set lastError here — the
        // login screen displays state.lastError and we'd shadow the real
        // sign-in flow with a confusing "Session expired" message.
        guard isAuthenticated else {
            pendingPushTokenRegistration = PendingPushTokenRegistration(
                token: token, platform: platform, bundleId: bundleId
            )
            return
        }
        // Skip the round-trip if the server already has this exact token
        // for this user (the typical re-launch path).
        if registeredPushToken == token {
            pendingPushTokenRegistration = nil
            return
        }
        Task {
            do {
                try await api.registerAppPushToken(
                    token: token, platform: platform, bundleId: bundleId
                )
                registeredPushToken = token
                pendingPushTokenRegistration = nil
            } catch {
                lastError = "Failed to register for push notifications: \(error.localizedDescription)"
            }
        }
    }

    /// Replay a cached APNs token through `syncPushToken` after auth has
    /// flipped to true. Called from `applyAuthenticatedState` so all
    /// sign-in paths (Apple, Google, password, restoreSession,
    /// exchangeOAuthCode) trigger it. No-op when there's no cached token.
    /// Idempotent: if `registeredPushToken` already equals the cached value,
    /// the inner syncPushToken short-circuits.
    public func flushPendingPushTokenIfAvailable() {
        guard let pending = pendingPushTokenRegistration else { return }
        guard isAuthenticated else { return }   // belt-and-braces
        syncPushToken(
            token: pending.token,
            platform: pending.platform,
            bundleId: pending.bundleId
        )
    }

    /// Drop the user's registered APNs token on the server. Called on
    /// logout. The server-side RPC only deletes rows owned by the calling
    /// user, so this can never delete someone else's token.
    public func unregisterPushTokenOnLogout() {
        guard let token = registeredPushToken else { return }
        Task {
            do {
                try await api.unregisterAppPushToken(token: token)
            } catch {
                // Logout is racy by nature; don't surface as an error to
                // the user. Server's own ON CONFLICT(token) DO UPDATE on
                // the next user login will transfer ownership anyway.
            }
            registeredPushToken = nil
        }
    }

    /// Atomic entry point for flipping Remote Control on or off.
    ///
    /// Single source of truth: every Mac/iOS surface that toggles the flag
    /// MUST go through this method (Codex review iter4 P1). The previous
    /// pattern — direct mutation of `remoteControlEnabled` followed by a
    /// separate push call — could leave the UI desynced from the server
    /// when the PATCH failed (e.g. the user thinks they turned Remote
    /// Control off but the helper-side gate is still open).
    ///
    /// **iter5 P1 hardening — latest-intent-wins under overlapping requests:**
    /// the synchronous prologue (`saving` flag + early-return guards) runs
    /// BEFORE the Task launches so there is no window in which a second
    /// caller could race past a still-fire-and-forget first call. UI also
    /// binds `.disabled(state.remoteControlSaving)` on the Toggle so a
    /// double-tap can't even reach this method while a PATCH is in flight,
    /// and `refreshYieldScore` skips overwriting `remoteControlEnabled`
    /// while saving is true so a stale `settings()` response can't undo
    /// the user's latest intent.
    ///
    /// Behaviour:
    ///   1. Synchronous guards: drop if already saving, drop if equal.
    ///   2. Synchronous flip: set `saving=true`, snapshot previous value,
    ///      optimistically set new value. (Visible to UI immediately.)
    ///   3. Async: PATCH `user_settings` with `remote_control_enabled`.
    ///   4. On success: if disabling, clear cached pending approvals so the
    ///      UI doesn't briefly show stale rows after the gate trips.
    ///   5. On failure: revert to `previousValue`, leave pending approvals
    ///      untouched, and surface a `lastError` so the user is aware.
    ///   6. Always (success or failure): clear `saving=false`.
    public func setRemoteControlEnabled(_ desired: Bool) {
        // ── Synchronous prologue. Runs on the caller's thread (UI), before
        //    the Task is enqueued, so a re-entrant call cannot slip past
        //    these guards.
        if remoteControlSaving {
            // A previous PATCH is still in flight. The UI Toggle is bound to
            // `.disabled(remoteControlSaving)` so this branch should be
            // unreachable in practice; defending anyway in case a non-UI
            // caller (programmatic test, future code path) sneaks past.
            return
        }
        if remoteControlEnabled == desired {
            // No-op set (e.g. repeated identical toggle, or refresh that
            // already wrote the same value). Avoid the round-trip.
            return
        }
        // Mark saving first so a refreshYieldScore that runs concurrently
        // sees `saving=true` and skips its overwrite branch.
        remoteControlSaving = true
        let previousValue = remoteControlEnabled
        remoteControlEnabled = desired

        // ── Async epilogue. The PATCH and any follow-on state changes are
        //    fine to perform from a Task; the synchronous prologue above has
        //    already published the user's intent to SwiftUI.
        Task {
            do {
                try await api.updateSettings(APIClient.SettingsPatch(
                    remote_control_enabled: desired
                ))
                if desired {
                    // First-time enable: now is the right product moment to
                    // ask for notification permission. If the user has
                    // already granted (e.g. previous install), this is a
                    // no-op; the permission grant chain triggers
                    // registerForRemoteNotifications which delivers the
                    // APNs token via didRegister → syncPushToken. iter8
                    // hotfix: this replaces the previous behaviour where
                    // iOSMainView prompted unconditionally on launch.
                    requestNotificationPermission()
                } else {
                    // Successful toggle off — clear cached pending requests
                    // so the UI doesn't briefly show stale rows after the
                    // gate trips. Only on confirmed success; revert-after-
                    // failure must not destroy that state.
                    remotePendingApprovals = []
                    remoteApprovalsLastRefresh = nil
                }
            } catch {
                // PATCH failed — revert to keep the UI honest about server
                // state. Do NOT touch remotePendingApprovals; if the user
                // was disabling and the disable failed, the existing pending
                // list is still the truth from the server's perspective.
                remoteControlEnabled = previousValue
                let action = desired ? "enable" : "disable"
                lastError = "Couldn't \(action) Remote Control: \(error.localizedDescription)"
                remoteApprovalsError = lastError
            }
            // Always clear saving so a follow-up toggle (or a deferred
            // settings refresh) can proceed.
            remoteControlSaving = false
        }
    }

    // `pushRemoteControlSettingToServer` was the v0.27 helper. It was dropped
    // in iter4: combining `state.remoteControlEnabled = newValue` followed by
    // a separate push call meant a failed PATCH left the UI showing the new
    // value while the server-side gate still reflected the old one. Use
    // `setRemoteControlEnabled(_:)` instead, which snapshots, optimistically
    // sets, PATCHes, and reverts on failure as a single transaction.

    /// Refresh the pending-approvals list. No-op (and clears the local cache)
    /// when Remote Control is disabled, so the UI stops looking like the
    /// feature is live after the user has opted out.
    public func refreshRemoteApprovals() async {
        guard remoteControlEnabled else {
            remotePendingApprovals = []
            remoteApprovalsLastRefresh = Date()
            return
        }
        do {
            let pending = try await api.remoteListPendingApprovals()
            // Re-check the gate AFTER the await: if the user toggled Remote
            // Control off while the network call was in flight, the response
            // would otherwise repopulate the UI with rows the user just
            // disabled (Gemini review P2 #8). v0.29 also gates the server
            // RPC, but the client check is the immediate fix and works
            // against older server versions during rollout.
            guard remoteControlEnabled else {
                remotePendingApprovals = []
                remoteApprovalsLastRefresh = Date()
                return
            }
            remotePendingApprovals = pending
            remoteApprovalsLastRefresh = Date()
            remoteApprovalsError = nil
        } catch {
            // If the user toggled Remote Control off while the network call
            // was in flight, swallow the error — the failed list call is
            // irrelevant once the feature is disabled, and surfacing a stale
            // error banner would just confuse them (Codex review iter4 P2).
            guard remoteControlEnabled else {
                return
            }
            remoteApprovalsError = error.localizedDescription
        }
    }

    /// Approve or deny a pending request. Optimistically removes the row
    /// locally so the UI feels snappy; refreshes from the server on completion
    /// to stay consistent with any server-side state changes.
    public func decideRemoteApproval(
        requestId: String,
        decision: RemotePermissionDecisionAction
    ) async {
        guard remoteControlEnabled else { return }
        // Snapshot the failed row only — NOT the whole list. Restoring the
        // entire list on failure would silently wipe new pending requests
        // that arrived during the in-flight decide call (Gemini review P1 #3).
        let originalRow = remotePendingApprovals.first(where: { $0.id == requestId })
        remotePendingApprovals.removeAll { $0.id == requestId }
        do {
            try await api.remoteDecidePermission(
                requestId: requestId,
                decision: decision,
                scope: .once
            )
            await refreshRemoteApprovals()
        } catch {
            // Re-insert only the failed row, preserving any new rows that
            // arrived during the await. Sort by created_at desc to match the
            // server-side `order by created_at desc` in list_pending_approvals.
            if let row = originalRow,
               !remotePendingApprovals.contains(where: { $0.id == row.id }) {
                remotePendingApprovals.append(row)
                remotePendingApprovals.sort { $0.created_at > $1.created_at }
            }
            remoteApprovalsError = "Decision failed: \(error.localizedDescription)"
        }
    }

    func refreshContext() -> DataRefreshManager.Context {
        DataRefreshManager.Context(
            isAuthenticated: isAuthenticated,
            isDemoMode: isDemoMode,
            isPaired: isPaired,
            isLoading: isLoading,
            notificationsEnabled: notificationsEnabled,
            providerConfigs: providerConfigs,
            providers: providers,
            maxDevices: subscriptionManager.maxDevices,
            maxProviders: subscriptionManager.maxProviders,
            currentTierName: subscriptionManager.currentTier.rawValue
        )
    }

    func refreshCallbacks() -> DataRefreshManager.Callbacks {
        DataRefreshManager.Callbacks(
            isAuthenticated: { [weak self] in self?.isAuthenticated ?? false },
            setLoading: { [weak self] in self?.isLoading = $0 },
            setLastError: { [weak self] in self?.lastError = $0 },
            setServerOnline: { [weak self] in self?.serverOnline = $0 },
            applyPayload: { [weak self] in self?.applyRefreshPayload($0) },
            sendNotification: { [weak self] in self?.sendNotification(for: $0) },
            afterRefresh: { [weak self] in self?.completeRefresh() },
            handleTokenExpired: { [weak self] message in
                self?.signOut()
                self?.lastError = message
            },
            activeSuppressedAlertIDs: { @MainActor [weak self] in
                self?.activeSuppressedAlertIDs() ?? []
            },
            setNeedsFolderAccess: { @MainActor [weak self] value in
                self?.needsScannerFolderAccess = value
            }
        )
    }

    func refreshRequest() -> @MainActor () async -> Void {
        { [weak self] in
            guard let self else { return }
            await self.refreshAll()
        }
    }

    func demoUpdateAlert(
        _ alert: AlertRecord,
        isRead: Bool? = nil,
        isResolved: Bool? = nil,
        acknowledgedAt: String? = nil,
        snoozedUntil: String? = nil
    ) -> AlertRecord {
        AlertRecord(
            id: alert.id,
            type: alert.type,
            severity: alert.severity,
            title: alert.title,
            message: alert.message,
            created_at: alert.created_at,
            is_read: isRead ?? alert.is_read,
            is_resolved: isResolved ?? alert.is_resolved,
            acknowledged_at: acknowledgedAt ?? alert.acknowledged_at,
            snoozed_until: snoozedUntil ?? alert.snoozed_until,
            related_project_id: alert.related_project_id,
            related_project_name: alert.related_project_name,
            related_session_id: alert.related_session_id,
            related_session_name: alert.related_session_name,
            related_provider: alert.related_provider,
            related_device_name: alert.related_device_name,
            source_kind: alert.source_kind,
            source_id: alert.source_id,
            grouping_key: alert.grouping_key,
            suppression_key: alert.suppression_key
        )
    }
}
