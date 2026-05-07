import Foundation

/// Writes the `claude_snapshot.json` file the macOS app reads as a
/// fallback when its own OAuth strategy hasn't produced fresh data.
/// Schema mirrors `ClaudeHelperContract.swift` on the app side AND
/// the Python helper's `_write_claude_snapshot` shape — drift here
/// silently breaks the app's Claude quota panel.
///
/// Phase 4E Slice 2d. Writes to BOTH:
///   * `~/Library/Group Containers/group.yyh.CLI-Pulse/claude_snapshot.json`
///     — primary path the sandboxed app reads
///   * `~/.clipulse/claude_snapshot.json` — legacy compatibility for
///     older builds + CLI diagnostics
///
/// File permissions are forced to `0o600` after write (matches Python).
public struct ClaudeSnapshotWriter: Sendable {

    /// `_LAUNCH_TIER_NAMES` mirrors Python — additive named tiers
    /// for the macOS app's "Extra Tiers" section without breaking
    /// older apps that only know the 4 baseline `*_used` keys.
    static let launchTierNames: [String] = ["Designs", "Daily Routines"]

    public typealias FileWriteHook = @Sendable (URL, Data) throws -> Void

    private let groupContainerPath: URL
    private let legacyPath: URL
    private let fileWrite: FileWriteHook
    private let now: @Sendable () -> Date

    public init(
        groupContainerPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.yyh.CLI-Pulse/claude_snapshot.json"),
        legacyPath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clipulse/claude_snapshot.json"),
        fileWrite: @escaping FileWriteHook = ClaudeSnapshotWriter.liveWrite,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.groupContainerPath = groupContainerPath
        self.legacyPath = legacyPath
        self.fileWrite = fileWrite
        self.now = now
    }

    /// Convert a `ProviderQuotaSnapshot` to the JSON shape the macOS
    /// app expects, then write to both paths. Errors are swallowed —
    /// the helper daemon should never crash on a snapshot-write
    /// failure (matches Python's defensive try/except).
    public func write(snapshot: ProviderQuotaSnapshot, rateLimitTier: String?) {
        let dict = Self.buildDict(
            from: snapshot,
            rateLimitTier: rateLimitTier,
            source: Self.sourceLabel(from: snapshot.provenance),
            fetchedAt: SessionDetector.makeISOFormatter().string(from: now())
        )
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        for url in [groupContainerPath, legacyPath] {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileWrite(url, data)
        }
    }

    /// Build the snapshot dictionary. Pure function so unit tests
    /// pin the wire shape without touching disk.
    public static func buildDict(
        from snapshot: ProviderQuotaSnapshot,
        rateLimitTier: String?,
        source: String,
        fetchedAt: String
    ) -> [String: Any] {
        let tierMap = Dictionary(
            uniqueKeysWithValues: snapshot.tiers.map { ($0.name, $0) }
        )

        func used(_ name: String) -> Int? {
            guard let tier = tierMap[name] else { return nil }
            return max(0, tier.quota - tier.remaining)
        }

        var dict: [String: Any] = [
            "session_used": used("5h Window") as Any,
            "weekly_used": used("Weekly") as Any,
            "opus_used": used("Opus (Weekly)") as Any,
            "sonnet_used": used("Sonnet (Weekly)") as Any,
            "session_reset": tierMap["5h Window"]?.resetTime as Any,
            "weekly_reset": tierMap["Weekly"]?.resetTime as Any,
            "rate_limit_tier": rateLimitTier as Any,
            "account_email": NSNull(),
            "extra_usage": NSNull(),
            "extra_tiers": Self.buildExtraTiers(tierMap: tierMap),
            "fetched_at": fetchedAt,
            "source": source,
        ]

        // Extra Usage tier — translates to dollar credits.
        if let extra = tierMap["Extra Usage"] {
            let scale: Double = 100_000
            dict["extra_usage"] = [
                "is_enabled": true,
                "monthly_limit": Double(extra.quota) / scale,
                "used_credits": Double(max(0, extra.quota - extra.remaining)) / scale,
                "currency": "USD",
            ]
        }
        return dict
    }

    private static func buildExtraTiers(
        tierMap: [String: ProviderQuotaTier]
    ) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for name in launchTierNames {
            guard let tier = tierMap[name] else { continue }
            out.append([
                "name": name,
                "used": max(0, tier.quota - tier.remaining),
                "reset": tier.resetTime as Any,
            ])
        }
        return out
    }

    /// Map `QuotaProvenance` to the legacy "source" string the app
    /// expects (matches Python's source labels).
    static func sourceLabel(from provenance: QuotaProvenance) -> String {
        switch provenance {
        case .anthropicOAuth: return "oauth"
        case .anthropicWebCookie: return "web"
        case .anthropicCLILegacy: return "cli"
        case .openAIWham, .googleCloudCode:
            // These shouldn't reach this writer (different providers),
            // but if they do, fall through to a non-misleading label.
            return "unknown"
        case .unavailable: return "unavailable"
        }
    }

    /// Default file-write hook. Performs an atomic write + chmod 0o600.
    @Sendable
    public static func liveWrite(_ url: URL, _ data: Data) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }
}
