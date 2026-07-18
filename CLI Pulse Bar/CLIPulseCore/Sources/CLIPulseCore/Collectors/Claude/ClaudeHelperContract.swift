#if os(macOS)
import Foundation

/// Defines the contract between the sandboxed app and the unsandboxed helper
/// for Claude data that cannot be collected inside the app sandbox.
///
/// ## Architecture
///
/// The app process is sandboxed and cannot:
/// - Read browser cookie SQLite databases (Safari/Chrome/Firefox)
/// - Run PTY-heavy processes reliably in all contexts
/// - Access cross-app Keychain items without user prompts
///
/// The helper (Python `cli_pulse_helper.py` or future bundled CLI) runs
/// outside the sandbox and performs:
/// 1. Browser cookie extraction → claude.ai web API calls
/// 2. PTY-based `claude /usage` probes
/// 3. Writing normalized results to the app group container or a legacy
///    `~/.clipulse/claude_snapshot.json` fallback when app-group access is unavailable.
///
/// The app reads this file via `ClaudeWebStrategy.readHelperSnapshot()`.
///
/// ## File Paths
///
/// | File | Writer | Reader | Purpose |
/// |------|--------|--------|---------|
/// | `~/Library/Group Containers/group.yyh.CLI-Pulse/claude_snapshot.json` | Helper | App (WebStrategy) | Complete pre-fetched usage data |
/// | `~/Library/Group Containers/group.yyh.CLI-Pulse/claude_session.json` | Helper | App (WebStrategy) | Session key for app-side API calls |
/// | `~/.clipulse/claude_snapshot.json` | Helper | Legacy fallback | Pre-app-group compatibility |
/// | `~/.clipulse/claude_session.json` | Helper | Legacy fallback | Pre-app-group compatibility |
/// | `$TMPDIR/clipulse_claude_resolver.log` | App | Debug | Strategy chain execution log |
/// | `$TMPDIR/clipulse_claude_fallback.log` | App | Debug | Fallback chain failure log |
/// | `$TMPDIR/clipulse_merge_diagnostic.json` | App | Debug | Cloud/local merge verification |
///
/// ## Snapshot JSON Schema
///
/// ```json
/// {
///   "session_used": 45,
///   "weekly_used": 60,
///   "opus_used": 75,
///   "sonnet_used": null,
///   "session_reset": "2026-04-02T22:00:00Z",
///   "weekly_reset": "2026-04-09T00:00:00Z",
///   "rate_limit_tier": "pro",
///   "account_email": "user@example.com",
///   "extra_usage": {
///     "is_enabled": true,
///     "monthly_limit": 50.0,
///     "used_credits": 12.34,
///     "currency": "USD"
///   },
///   "extra_tiers": [
///     { "name": "Designs",        "used": 25, "reset": "2026-05-05T12:00:00Z" },
///     { "name": "Daily Routines", "used": 5,  "reset": null }
///   ],
///   "fetched_at": "2026-04-02T14:30:00Z",
///   "source": "web"
/// }
/// ```
///
/// `extra_tiers` is additive: older app builds that don't know the key
/// continue to parse the legacy `*_used` / `*_reset` fields unchanged.
/// Helper writers should only include known launch-window names there
/// (currently `Designs` and `Daily Routines`); `Extra Usage` keeps its
/// dedicated `extra_usage` field above and is never duplicated here.
///
/// ## Freshness
///
/// Snapshots older than 10 minutes are rejected. The helper should write
/// a new snapshot at least every 5 minutes during active use.
public enum ClaudeHelperContract {
    public static let appGroupID = "group.yyh.CLI-Pulse"

    /// Legacy helper directory before the app-group migration.
    public static var legacyHelperDir: String {
        (ClaudeCredentials.realHomeDir as NSString).appendingPathComponent(".clipulse")
    }

    /// App-group container directory when available to the running process.
    public static var appGroupHelperDir: String? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .path
    }

    /// Directory where helper writes Claude data files.
    ///
    /// Kept for callers that need a single directory. Prefer `snapshotPath`,
    /// which picks per-FILE by freshness — see below for why that matters.
    public static var helperDir: String {
        appGroupHelperDir ?? legacyHelperDir
    }

    /// Both directories a helper may have written to, in fallback order.
    public static var helperDirCandidates: [String] {
        var out: [String] = []
        if let g = appGroupHelperDir { out.append(g) }
        if !out.contains(legacyHelperDir) { out.append(legacyHelperDir) }
        return out
    }

    /// Path to the complete snapshot file — **the freshest one that exists.**
    ///
    /// Two helpers write this file to two different places, and which one is
    /// authoritative changed:
    ///   * the `.pkg` Python helper writes the app-group container;
    ///   * the bundled Swift helper now writes `~/.clipulse`, because writing
    ///     inside the container made every launchd start a TCC
    ///     `SystemPolicyAppData` consult — the recurring "CLI Pulse would like to
    ///     access data from other apps" prompt.
    ///
    /// A fixed preference is wrong in both directions: preferring the container
    /// (the old behaviour) makes a machine served only by the bundled helper read
    /// a frozen snapshot forever — and since snapshots older than 10 minutes are
    /// rejected, the Claude quota UI would just go silently empty. Preferring
    /// `~/.clipulse` breaks the `.pkg`-only machines the same way.
    ///
    /// Modification time answers it directly: whichever helper actually ran most
    /// recently wrote the newer file, so pick that. Falls back to `helperDir`'s
    /// path when neither exists, so callers still get a stable path to watch.
    public static var snapshotPath: String {
        return snapshotCandidatePaths.first
            ?? (helperDir as NSString).appendingPathComponent("claude_snapshot.json")
    }

    /// The most recently modified copy of `name` across the candidate dirs.
    static func freshestPath(named name: String) -> String {
        let fm = FileManager.default
        var best: (path: String, mtime: Date)?
        for dir in helperDirCandidates {
            let candidate = (dir as NSString).appendingPathComponent(name)
            guard let attrs = try? fm.attributesOfItem(atPath: candidate),
                  let mtime = attrs[.modificationDate] as? Date else { continue }
            if best == nil || mtime > best!.mtime {
                best = (candidate, mtime)
            }
        }
        return best?.path ?? (helperDir as NSString).appendingPathComponent(name)
    }

    /// Path to the session key file.
    public static var sessionKeyPath: String {
        (helperDir as NSString).appendingPathComponent("claude_session.json")
    }

    /// Path to the account-info file. Sibling to `snapshotPath` but
    /// intentionally kept separate so metadata (email, tier, weekly reset)
    /// can be cached even during quota-fetch failures without polluting
    /// the strict "quota only if all 4 percents present" contract that
    /// `snapshotPath` enforces downstream.
    public static var accountInfoPath: String {
        (helperDir as NSString).appendingPathComponent("claude_account.json")
    }

    /// Account-info file paths to probe in priority order.
    public static var accountInfoCandidatePaths: [String] {
        var paths: [String] = []
        if let appGroupHelperDir {
            paths.append((appGroupHelperDir as NSString).appendingPathComponent("claude_account.json"))
        }
        paths.append((legacyHelperDir as NSString).appendingPathComponent("claude_account.json"))
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }

    /// Snapshot paths to probe, **freshest first**.
    ///
    /// Ordering by modification time rather than a fixed container-first order is
    /// load-bearing (review: agy). Two helpers write this file to two places — the
    /// `.pkg` Python helper to the app-group container, the bundled Swift helper
    /// to `~/.clipulse` (it stopped writing the container because that touch
    /// generated the TCC "access data from other apps" prompt). Every consumer
    /// here iterates these candidates and takes the FIRST acceptable hit
    /// (`readSnapshot`) or the first that merely EXISTS (`diagnosticSummary`), so
    /// a fixed container-first order would let a stale container copy — possibly
    /// years old — permanently mask a fresh `~/.clipulse` snapshot on a machine
    /// served only by the bundled helper. Since snapshots older than the caller's
    /// `maxAge` are rejected, that presents to the user as the Claude quota UI
    /// simply going empty.
    ///
    /// Sorting here fixes every caller at once instead of patching each one.
    /// Paths that do not exist sort last but are still returned, so callers that
    /// want a path to watch/create still get one.
    public static var snapshotCandidatePaths: [String] {
        var paths: [String] = []
        if let appGroupHelperDir {
            paths.append((appGroupHelperDir as NSString).appendingPathComponent("claude_snapshot.json"))
        }
        paths.append((legacyHelperDir as NSString).appendingPathComponent("claude_snapshot.json"))
        let unique = Array(NSOrderedSet(array: paths)) as? [String] ?? paths
        return orderedByFreshness(unique)
    }

    /// Sort paths newest-first by mtime; non-existent paths keep their relative
    /// order at the end.
    static func orderedByFreshness(_ paths: [String]) -> [String] {
        let fm = FileManager.default
        func mtime(_ p: String) -> Date? {
            (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        }
        return paths.enumerated().sorted { a, b in
            switch (mtime(a.element), mtime(b.element)) {
            case let (x?, y?): return x > y            // both exist → newest first
            case (_?, nil):    return true             // existing beats missing
            case (nil, _?):    return false
            case (nil, nil):   return a.offset < b.offset   // stable
            }
        }.map(\.element)
    }

    /// Session key paths to probe in priority order.
    public static var sessionKeyCandidatePaths: [String] {
        var paths: [String] = []
        if let appGroupHelperDir {
            paths.append((appGroupHelperDir as NSString).appendingPathComponent("claude_session.json"))
        }
        paths.append((legacyHelperDir as NSString).appendingPathComponent("claude_session.json"))
        return Array(NSOrderedSet(array: paths)) as? [String] ?? paths
    }

    /// Maximum age (seconds) before a snapshot is considered stale.
    public static let maxSnapshotAge: TimeInterval = 600 // 10 minutes

    /// Extended age for last-known-good cache fallback.
    /// This is intentionally much longer than `maxSnapshotAge` so the app can
    /// keep showing the last successful bars during transient OAuth 429 windows.
    public static let cacheSnapshotAge: TimeInterval = 86_400 // 24 hours

    /// Ensure the helper directory exists.
    public static func ensureHelperDir() {
        try? FileManager.default.createDirectory(
            atPath: helperDir, withIntermediateDirectories: true)
    }

    /// Write a snapshot from the helper side.
    /// Called by helper/CLI tools running outside the sandbox.
    public static func writeSnapshot(_ snapshot: ClaudeSnapshot) throws {
        ensureHelperDir()
        var dict: [String: Any] = [
            "fetched_at": sharedISO8601Formatter.string(from: Date()),
            "source": snapshot.sourceLabel,
        ]
        if let v = snapshot.sessionUsed { dict["session_used"] = v }
        if let v = snapshot.weeklyUsed { dict["weekly_used"] = v }
        if let v = snapshot.opusUsed { dict["opus_used"] = v }
        if let v = snapshot.sonnetUsed { dict["sonnet_used"] = v }
        if let v = snapshot.sessionReset { dict["session_reset"] = v }
        if let v = snapshot.weeklyReset { dict["weekly_reset"] = v }
        if let v = snapshot.rateLimitTier { dict["rate_limit_tier"] = v }
        if let v = snapshot.accountEmail { dict["account_email"] = v }
        if let e = snapshot.extraUsage {
            var extra: [String: Any] = ["is_enabled": e.isEnabled]
            if let v = e.monthlyLimit { extra["monthly_limit"] = v }
            if let v = e.usedCredits { extra["used_credits"] = v }
            if let v = e.currency { extra["currency"] = v }
            dict["extra_usage"] = extra
        }

        // Additive launch-window passthrough — see `extra_tiers` schema note
        // above. Only emit known names so the contract stays deterministic
        // and old readers ignoring this field never see surprise rows.
        // Always emit `reset` as either a String or JSON null, never missing,
        // to match the Python helper's `json.dumps({...})` output exactly.
        func makeExtraTier(name: String, used: Int, reset: String?) -> [String: Any] {
            return [
                "name": name,
                "used": used,
                "reset": (reset as Any?) ?? NSNull(),
            ]
        }
        var extraTiers: [[String: Any]] = []
        if let used = snapshot.designsUsed {
            extraTiers.append(makeExtraTier(name: "Designs", used: used, reset: snapshot.designsReset))
        }
        if let used = snapshot.dailyRoutinesUsed {
            extraTiers.append(makeExtraTier(name: "Daily Routines", used: used, reset: snapshot.dailyRoutinesReset))
        }
        if !extraTiers.isEmpty {
            dict["extra_tiers"] = extraTiers
        }

        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
    }

    /// Write account-level metadata to its dedicated sibling file.
    ///
    /// Unlike `writeSnapshot` (which is strict about usage fields), this file
    /// is written whenever *any* metadata is known — even during a quota fetch
    /// failure — so we can still tell the user "Signed in as X" under the
    /// diagnostic copy path while the quota endpoint drifts.
    public static func writeAccountInfo(_ info: ClaudeAccountInfo) throws {
        ensureHelperDir()
        var dict: [String: Any] = [
            "fetched_at": sharedISO8601Formatter.string(from: Date()),
        ]
        if let v = info.accountEmail { dict["account_email"] = v }
        if let v = info.rateLimitTier { dict["rate_limit_tier"] = v }
        if let v = info.weeklyReset { dict["weekly_reset"] = v }
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: accountInfoPath), options: .atomic)
    }

    /// Read account-level metadata. Returns nil when the file is missing
    /// or malformed. No TTL — account metadata is long-lived and even a
    /// day-old email/tier is better than nothing for diagnostic copy.
    public static func readAccountInfo() -> ClaudeAccountInfo? {
        for path in accountInfoCandidatePaths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            return ClaudeAccountInfo(
                accountEmail: json["account_email"] as? String,
                rateLimitTier: json["rate_limit_tier"] as? String,
                weeklyReset: json["weekly_reset"] as? String
            )
        }
        return nil
    }

    /// Write a session key from the helper side.
    public static func writeSessionKey(_ sessionKey: String, source: String = "browser") throws {
        ensureHelperDir()
        let dict: [String: Any] = [
            "sessionKey": sessionKey,
            "source": source,
            "fetched_at": sharedISO8601Formatter.string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted])
        try data.write(to: URL(fileURLWithPath: sessionKeyPath), options: .atomic)
    }

    /// Check if a fresh helper snapshot exists.
    public static func hasFreshSnapshot() -> Bool {
        ClaudeWebStrategy.readHelperSnapshot() != nil
    }

    /// Read a helper snapshot with a caller-provided TTL.
    /// Returns nil when the file is missing, malformed, or older than `maxAge`.
    public static func readSnapshot(maxAge: TimeInterval, sourceLabel: String) -> ClaudeSnapshot? {
        for path in snapshotCandidatePaths {
            guard let data = FileManager.default.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            let fetchedDate = (json["fetched_at"] as? String).flatMap { sharedISO8601Formatter.date(from: $0) }
            if let date = fetchedDate,
               Date().timeIntervalSince(date) > maxAge {
                continue
            }

            var extra: ClaudeExtraUsage? = nil
            if let e = json["extra_usage"] as? [String: Any] {
                let isEnabled = e["is_enabled"] as? Bool ?? false
                if isEnabled {
                    extra = ClaudeExtraUsage(
                        isEnabled: true,
                        monthlyLimit: (e["monthly_limit"] as? NSNumber)?.doubleValue,
                        usedCredits: (e["used_credits"] as? NSNumber)?.doubleValue,
                        currency: e["currency"] as? String
                    )
                }
            }

            let normalizedSessionReset = normalizeSessionReset(
                json["session_reset"] as? String,
                reference: fetchedDate ?? Date()
            )
            let normalizedWeeklyReset = normalizeWeeklyReset(
                json["weekly_reset"] as? String,
                reference: fetchedDate ?? Date()
            )

            // Project optional `extra_tiers` array onto the launch-window
            // snapshot fields. Old snapshots (no key, or empty array) leave
            // the new fields nil — callers see exactly the same shape as
            // before this contract was extended.
            var designsUsed: Int? = nil
            var designsReset: String? = nil
            var dailyRoutinesUsed: Int? = nil
            var dailyRoutinesReset: String? = nil
            if let extraTiers = json["extra_tiers"] as? [[String: Any]] {
                for entry in extraTiers {
                    guard let name = entry["name"] as? String,
                          let used = entry["used"] as? Int else { continue }
                    let reset = entry["reset"] as? String
                    switch name {
                    case "Designs":
                        designsUsed = used
                        designsReset = reset
                    case "Daily Routines":
                        dailyRoutinesUsed = used
                        dailyRoutinesReset = reset
                    default:
                        // Unknown launch-window names are intentionally
                        // discarded — adding new ones is a coordinated
                        // helper+app change so a stray name from an older
                        // helper shouldn't surface a phantom row.
                        continue
                    }
                }
            }

            return ClaudeSnapshot(
                sessionUsed: json["session_used"] as? Int,
                weeklyUsed: json["weekly_used"] as? Int,
                opusUsed: json["opus_used"] as? Int,
                sonnetUsed: json["sonnet_used"] as? Int,
                designsUsed: designsUsed,
                dailyRoutinesUsed: dailyRoutinesUsed,
                sessionReset: normalizedSessionReset,
                weeklyReset: normalizedWeeklyReset,
                designsReset: designsReset,
                dailyRoutinesReset: dailyRoutinesReset,
                extraUsage: extra,
                rateLimitTier: json["rate_limit_tier"] as? String,
                accountEmail: json["account_email"] as? String,
                sourceLabel: sourceLabel
            )
        }
        return nil
    }

    /// Claude's weekly usage page currently resets on Friday 11:00 PM local time.
    /// Helper snapshots have occasionally persisted incorrect UTC-midnight placeholders;
    /// when that happens, prefer the canonical weekly reset instead of showing a bogus 6d+ countdown.
    static func normalizeWeeklyReset(_ raw: String?, reference: Date) -> String? {
        let canonical = canonicalWeeklyReset(after: reference)
        guard let canonical else { return raw }
        guard let raw,
              let parsed = parseISO8601(raw)
        else {
            return sharedISO8601Formatter.string(from: canonical)
        }

        let delta = abs(parsed.timeIntervalSince(canonical))
        if delta <= 6 * 3600 {
            return sharedISO8601Formatter.string(from: parsed)
        }
        return sharedISO8601Formatter.string(from: canonical)
    }

    /// Session resets are rolling; if a cached reset is already behind the snapshot fetch time,
    /// hide it rather than displaying `ago` or a stale future.
    static func normalizeSessionReset(_ raw: String?, reference: Date) -> String? {
        guard let raw,
              let parsed = parseISO8601(raw)
        else {
            return raw
        }
        guard parsed.timeIntervalSince(reference) > 60 else {
            return nil
        }
        return sharedISO8601Formatter.string(from: parsed)
    }

    static func canonicalWeeklyReset(after reference: Date, calendar: Calendar = claudeWeeklyResetCalendar) -> Date? {
        var components = DateComponents()
        components.weekday = 6 // Friday in Gregorian calendars where Sunday == 1
        components.hour = 23
        components.minute = 0
        components.second = 0
        return calendar.nextDate(
            after: reference,
            matching: components,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    /// Claude's weekly reset is anchored to Friday 11 PM Asia/Tokyo (the
    /// same absolute instant worldwide = 14:00 UTC, NOT per-user-local).
    /// Default `.current` here caused the reset to compute in the runner's
    /// local timezone — for US users this meant Fri 11 PM Eastern, which
    /// is a different absolute instant from what Claude actually uses.
    /// v1.10.2 fix: pin the default calendar to Asia/Tokyo so production
    /// behavior no longer depends on the user's device timezone.
    /// Caught when the CI (UTC) test started failing with 2026-04-03T23:00:00Z
    /// instead of the Tokyo-anchored 2026-04-03T14:00:00Z.
    static let claudeWeeklyResetCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return cal
    }()

    private static func parseISO8601(_ raw: String) -> Date? {
        // Try default format first via shared (immutable) formatter
        if let date = sharedISO8601Formatter.date(from: raw) {
            return date
        }
        // Fall back to fractional seconds with a local formatter — do NOT mutate the shared one
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    /// Diagnostic: summarize helper file state.
    public static func diagnosticSummary() -> String {
        let fm = FileManager.default
        var lines: [String] = []

        let diagnosticPath = snapshotCandidatePaths.first(where: { fm.fileExists(atPath: $0) })

        if let diagnosticPath {
            if let data = FileManager.default.contents(atPath: diagnosticPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let fetchedAt = json["fetched_at"] as? String,
               let fetched = sharedISO8601Formatter.date(from: fetchedAt) {
                let age = Int(Date().timeIntervalSince(fetched))
                let liveFresh = age < Int(maxSnapshotAge)
                let cacheFresh = age < Int(cacheSnapshotAge)
                lines.append("snapshot: exists, age=\(age)s, liveFresh=\(liveFresh), cacheFresh=\(cacheFresh), path=\(diagnosticPath)")
            } else if let attrs = try? fm.attributesOfItem(atPath: diagnosticPath),
                      let modified = attrs[.modificationDate] as? Date {
                let age = Int(Date().timeIntervalSince(modified))
                let liveFresh = age < Int(maxSnapshotAge)
                let cacheFresh = age < Int(cacheSnapshotAge)
                lines.append("snapshot: exists, age=\(age)s, liveFresh=\(liveFresh), cacheFresh=\(cacheFresh), source=fileDate, path=\(diagnosticPath)")
            } else {
                lines.append("snapshot: exists, age=unknown")
            }
        } else {
            lines.append("snapshot: missing")
        }

        if fm.fileExists(atPath: sessionKeyPath) {
            lines.append("session_key: exists")
        } else {
            lines.append("session_key: missing")
        }

        return lines.joined(separator: ", ")
    }
}
#endif
