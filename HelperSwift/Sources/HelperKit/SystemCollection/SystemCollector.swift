import Foundation

/// Top-level façade for the SystemCollection subsystem. Wires
/// device + sessions + alerts + per-provider quotas into a single
/// `CollectionResult` per tick. Mirrors
/// `helper/system_collector.py::collect_all` 1:1, including its
/// graceful-degrade contract — any component error returns a
/// partial result rather than throwing.
///
/// Phase 4E Slice 2d. This is what the daemon main loop (Slice 4)
/// calls every interval.
public actor SystemCollector {

    /// Bundle of everything one collection cycle produces.
    public struct CollectionResult: Codable, Sendable, Equatable {
        public let device: DeviceSnapshot
        public let sessions: [CollectedSession]
        public let alerts: [CollectedAlert]
        /// Map of provider name → quota snapshot. Provider names
        /// match `SessionDetector.providerPatterns` (`"Claude"`,
        /// `"Codex"`, `"Gemini"`).
        public let providerQuotas: [String: ProviderQuotaSnapshot]
        public let helperVersion: String
        public let collectionErrors: [String]
        public let collectedAt: String

        private enum CodingKeys: String, CodingKey {
            case device
            case sessions
            case alerts
            case providerQuotas = "provider_quotas"
            case helperVersion = "helper_version"
            case collectionErrors = "collection_errors"
            case collectedAt = "collected_at"
        }

        public init(
            device: DeviceSnapshot,
            sessions: [CollectedSession],
            alerts: [CollectedAlert],
            providerQuotas: [String: ProviderQuotaSnapshot],
            helperVersion: String,
            collectionErrors: [String],
            collectedAt: String
        ) {
            self.device = device
            self.sessions = sessions
            self.alerts = alerts
            self.providerQuotas = providerQuotas
            self.helperVersion = helperVersion
            self.collectionErrors = collectionErrors
            self.collectedAt = collectedAt
        }
    }

    private let userSecret: Data
    private let helperVersion: String
    private let deviceCollector: DeviceSnapshotCollector
    private let sessionDetector: SessionDetector
    private let alertGenerator: AlertGenerator
    private let claudeFetcher: ClaudeQuotaFetcher
    private let codexFetcher: CodexQuotaFetcher
    private let geminiFetcher: GeminiQuotaFetcher
    private let snapshotWriter: ClaudeSnapshotWriter
    private let now: @Sendable () -> Date

    public init(
        userSecret: Data,
        // v1.15: bump default to a real semver string so the
        // iOS / macOS picker's version gate accepts heartbeats from
        // the Swift helper. Pre-v1.15 the placeholder
        // "swift-phase4e-slice2d" never parsed as semver and so
        // every Swift-helper-paired Mac failed the multi-CLI gate.
        helperVersion: String = "1.15.0",
        deviceCollector: DeviceSnapshotCollector? = nil,
        sessionDetector: SessionDetector? = nil,
        alertGenerator: AlertGenerator = AlertGenerator(),
        claudeFetcher: ClaudeQuotaFetcher? = nil,
        codexFetcher: CodexQuotaFetcher = CodexQuotaFetcher(),
        geminiFetcher: GeminiQuotaFetcher = GeminiQuotaFetcher(),
        snapshotWriter: ClaudeSnapshotWriter = ClaudeSnapshotWriter(),
        keychain: KeychainReader = KeychainReader(),
        backoff: OAuthBackoff = OAuthBackoff(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.userSecret = userSecret
        self.helperVersion = helperVersion
        self.deviceCollector = deviceCollector ?? DeviceSnapshotCollector()
        self.sessionDetector = sessionDetector ?? SessionDetector(userSecret: userSecret)
        self.alertGenerator = alertGenerator
        self.claudeFetcher = claudeFetcher ?? ClaudeQuotaFetcher(
            keychain: keychain,
            backoff: backoff
        )
        self.codexFetcher = codexFetcher
        self.geminiFetcher = geminiFetcher
        self.snapshotWriter = snapshotWriter
        self.now = now
    }

    // MARK: - Collection

    /// Run one full collection cycle. Per-component error isolation
    /// matches Python: the device snapshot, session list, alerts,
    /// and quotas are all independently optional. Returns a
    /// `CollectionResult` even on widespread failure (with the
    /// `collectionErrors` list populated).
    public func collectAll() async -> CollectionResult {
        let nowDate = now()
        let formatter = SessionDetector.makeISOFormatter()
        let nowISO = formatter.string(from: nowDate)
        var errors: [String] = []

        // Device + sessions in parallel — both touch ps/vm_stat
        // independently; no shared state.
        async let device = deviceCollector.collect()
        async let sessions = sessionDetector.collect()

        let resolvedDevice = await device
        let resolvedSessions = await sessions

        // Alerts depend on sessions+device, so awaited after.
        let resolvedAlerts = alertGenerator.generate(
            sessions: resolvedSessions,
            device: resolvedDevice,
            now: nowDate
        )

        // Provider quotas: kick off only the ones with active
        // sessions (matches Python — fetching quota for a provider
        // the user isn't using wastes a network round trip).
        let activeProviders = Set(resolvedSessions.map { $0.provider })
        var quotas: [String: ProviderQuotaSnapshot] = [:]

        // Each fetcher produces its own snapshot; per-fetcher errors
        // produce `.unavailable(reason:)` provenance, so a network
        // failure on Claude doesn't kill Codex / Gemini.
        if activeProviders.contains("Claude") {
            let snap = await claudeFetcher.fetch()
            quotas["Claude"] = snap
            // Persist Claude snapshot file for the macOS app.
            // Skip if provenance is .unavailable to avoid
            // overwriting good data with empties.
            if case .anthropicOAuth = snap.provenance {
                snapshotWriter.write(snapshot: snap, rateLimitTier: snap.planType)
            }
        }
        if activeProviders.contains("Codex") {
            quotas["Codex"] = await codexFetcher.fetch()
        }
        if activeProviders.contains("Gemini") {
            quotas["Gemini"] = await geminiFetcher.fetch()
        }

        return CollectionResult(
            device: resolvedDevice,
            sessions: resolvedSessions,
            alerts: resolvedAlerts,
            providerQuotas: quotas,
            helperVersion: helperVersion,
            collectionErrors: errors,
            collectedAt: nowISO
        )
    }
}
