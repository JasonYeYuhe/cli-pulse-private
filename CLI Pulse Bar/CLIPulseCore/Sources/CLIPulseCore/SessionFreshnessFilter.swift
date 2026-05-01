import Foundation

/// Pure filter shared between `refreshAll` (cloud route) and
/// `refreshLocal` (local-only route) so the macOS Sessions tab only
/// renders genuinely current AI sessions.
///
/// iter22 (2026-05-01): manual smoke surfaced 28-30 day-old "ended"
/// rows uploaded by the helper daemon (`device: CLI Pulse Helper`)
/// plus process-path artifacts ("/Applications/Claude.app/...",
/// "node --no-warnings ...") leaking into the Sessions tab via
/// `api.sessions()` cached history. The fix is twofold:
///   1. Drop sessions whose `last_active_at` is older than the
///      same `activeSessionFreshnessWindow` (300s) that
///      `CostUsageScanner.synthesizeSessions` already enforces.
///   2. Drop helper / process-path artifact rows entirely so they
///      never confuse the user's "what's running right now?"
///      mental model. These are stable patterns the helper emits
///      when it dumps `proc_listallpids` output verbatim.
public enum SessionFreshnessFilter {
    /// Same window used by `CostUsageScanner.synthesizeSessions` —
    /// keeps the cloud and local code paths consistent.
    public static let freshnessWindow: TimeInterval = 300

    /// Filter the merged session list before it lands in
    /// `AppState.sessions`. Returns only sessions that:
    ///   - have a parseable `last_active_at`,
    ///   - whose `last_active_at >= now - freshnessWindow`,
    ///   - and are not helper/process-path artifacts.
    public static func filterCurrent(
        _ sessions: [SessionRecord],
        now: Date
    ) -> [SessionRecord] {
        let cutoff = now.addingTimeInterval(-freshnessWindow)
        return sessions.filter { session in
            if isProcessPathArtifact(session) { return false }
            guard let lastActive = session.lastActiveDate else { return false }
            return lastActive >= cutoff
        }
    }

    /// Heuristic: process-enumeration artifacts have executable paths
    /// or shell-style flag strings as their `name`, not the JSONL
    /// session names that `CostUsageScanner.synthesizeSessions`
    /// produces ("<provider> · <project>"). Rejecting these patterns
    /// strips the helper-uploaded `device: "CLI Pulse Helper"` rows
    /// that survived in cloud cache without dropping legit synthesized
    /// sessions.
    public static func isProcessPathArtifact(_ session: SessionRecord) -> Bool {
        let name = session.name
        if name.hasPrefix("/") { return true }                    // /Applications/..., /usr/..., /opt/...
        if name.contains(".app/Contents/") { return true }        // Claude.app/Contents/Helper, Codex.app/...
        if name.hasPrefix("node ") || name.contains(" --no-warnings") { return true }
        return false
    }

    /// iter23 telemetry record for cloud-route session resolution.
    /// `candidates` is the **raw count from the cost scanner**, NOT
    /// the post-`scanResult?` count — the latter dropped the bug
    /// case (fresh Codex JSONL emits a candidate while
    /// `entries.isEmpty == true`, which made `scanResult` nil and
    /// silently swallowed the candidate). Surfacing both numbers in
    /// the log makes a future regression visible immediately.
    public struct CloudSessionResolution: Sendable, Equatable {
        public let merged: [SessionRecord]
        public let cloudRaw: Int
        public let cloudFresh: Int
        public let candidatesRaw: Int
        public let localSynth: Int

        public init(
            merged: [SessionRecord],
            cloudRaw: Int,
            cloudFresh: Int,
            candidatesRaw: Int,
            localSynth: Int
        ) {
            self.merged = merged
            self.cloudRaw = cloudRaw
            self.cloudFresh = cloudFresh
            self.candidatesRaw = candidatesRaw
            self.localSynth = localSynth
        }
    }

    /// Pure helper for `DataRefreshManager.refreshAll` cloud route:
    /// take the cloud-fetched session list + the raw cost scan
    /// `activeSessionCandidates`, run both through `filterCurrent`,
    /// synthesize local sessions, and merge. Extracted so the
    /// "fresh JSONL with empty cache" bug — where iter22's
    /// `scanResult?.activeSessionCandidates ?? []` swallowed
    /// candidates whenever `entries.isEmpty` was true — has a unit
    /// test seam.
    public static func resolveCloudSessions(
        cloudSessions: [SessionRecord],
        candidates: [CostUsageScanResult.ActiveSessionCandidate],
        deviceName: String,
        now: Date
    ) -> CloudSessionResolution {
        let cloudFresh = filterCurrent(cloudSessions, now: now)
        let localSynthRaw = CostUsageScanner.synthesizeSessions(
            candidates: candidates,
            now: now,
            deviceName: deviceName
        )
        let localFresh = filterCurrent(localSynthRaw, now: now)
        let merged = mergeCloudAndLocalSessions(
            cloudFresh: cloudFresh,
            localFresh: localFresh
        )
        return CloudSessionResolution(
            merged: merged,
            cloudRaw: cloudSessions.count,
            cloudFresh: cloudFresh.count,
            candidatesRaw: candidates.count,
            localSynth: localFresh.count
        )
    }

    /// iter23: merge cloud-fetched sessions (already-filtered through
    /// `filterCurrent`) with local JSONL-synthesized sessions on
    /// macOS so paired Mac users see fresh Codex/Claude activity in
    /// the Sessions tab even when `RefreshRouter` routes them to the
    /// `.cloud` branch (which previously ignored local synthesis
    /// entirely).
    ///
    /// De-dupe rule: keep at most one session per
    /// `(provider, sessionId)` — falling back to `(provider, project,
    /// device_name)` when the local synthesizer didn't recover a
    /// session id. **Local wins** on collision because the
    /// synthesized row reflects the most recent JSONL mtime, which is
    /// fresher than whatever Supabase last persisted from a helper
    /// upload tick.
    ///
    /// Cloud sessions from OTHER devices (different `device_name`)
    /// are preserved verbatim — they're already filterable evidence
    /// of remote activity that the local scanner can't see.
    public static func mergeCloudAndLocalSessions(
        cloudFresh: [SessionRecord],
        localFresh: [SessionRecord]
    ) -> [SessionRecord] {
        // Build the merge keyed by stable identity. We bucket by
        // `provider|sessionId` first because synthesized + cloud rows
        // for the same JSONL share that pair. Fall back to
        // `provider|project|device` when sessionId is missing — that's
        // unique enough for a single device's same-project rows.
        func key(_ s: SessionRecord) -> String {
            // SessionRecord doesn't expose a separate `sessionId`
            // field; the synthesized row encodes it as
            // `jsonl-<provider>-<sid>` in `id`. Use `id` directly so
            // local↔cloud collision needs the cloud helper to upload
            // a row with the same id (which it does for synthesized
            // rows — see `synthesizeSessions`). Otherwise fall back
            // to provider+project+device.
            if s.id.hasPrefix("jsonl-") { return s.id }
            return "\(s.provider)|\(s.project)|\(s.device_name)"
        }

        var merged: [String: SessionRecord] = [:]
        // Insert cloud first so local can overwrite on collision.
        for c in cloudFresh {
            merged[key(c)] = c
        }
        for l in localFresh {
            merged[key(l)] = l
        }
        // Stable order: most-recently-active first.
        let isoFormatter = ISO8601DateFormatter()
        return merged.values.sorted { lhs, rhs in
            let l = isoFormatter.date(from: lhs.last_active_at) ?? .distantPast
            let r = isoFormatter.date(from: rhs.last_active_at) ?? .distantPast
            return l > r
        }
    }
}
