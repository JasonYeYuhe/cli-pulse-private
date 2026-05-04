import Foundation

/// Tier classification for the macOS / iOS Sessions tab Active vs
/// Recent split. Replaces the binary 300s "fresh or drop" decision
/// in `SessionFreshnessFilter.filterCurrent` with a richer
/// 4-state model so the UI can show:
///
///   * **Active** section — process-confirmed sessions whose helper
///     is still emitting them, plus JSONL-only sessions whose JSONL
///     mtime is within the last 5 min.
///   * **Recent** section — JSONL-only sessions whose JSONL mtime
///     is between 5 min and 30 min old.
///   * Hidden — anything older, plus helper / process-path
///     artifacts that should never appear in Sessions.
///
/// Evidence axis:
///   * `proc-{pid}` ids come from `helper/system_collector.py`'s
///     ps-based `collect_sessions()`. Their `last_active_at` is
///     refreshed every helper heartbeat (≤ 60 s by default), so
///     a stale `proc-` row is genuinely stale (helper offline or
///     the process just died).
///   * `jsonl-…` ids come from `CostUsageScanner.synthesizeSessions`
///     reading provider JSONL mtimes — no live-process check.
///   * Cloud-fetched rows from other devices may have neither prefix;
///     they fall through to the JSONL age tiers.
///
/// Process-confirmation gives us higher confidence than JSONL mtime
/// alone, so we keep `proc-` rows in Active for a longer freshness
/// window than JSONL-only rows. The window matches the helper
/// heartbeat cadence so a healthy helper always keeps its sessions
/// in Active; an unhealthy helper's sessions degrade to Recent (and
/// then hidden) on schedule.
public enum FreshnessTier: String, Sendable, Equatable, CaseIterable {
    case activeProcess
    case activeJsonl
    case recentJsonl
    case hidden

    /// True iff the tier should appear in either UI section.
    public var isVisible: Bool { self != .hidden }

    /// Section assignment for the UI split.
    public var section: Section {
        switch self {
        case .activeProcess, .activeJsonl: return .active
        case .recentJsonl: return .recent
        case .hidden: return .hidden
        }
    }

    public enum Section: String, Sendable, Equatable {
        case active
        case recent
        case hidden
    }

    /// Short user-visible label for the row badge. Kept short so it
    /// fits in a small `StatusBadge`-style chip.
    public var badge: String {
        switch self {
        case .activeProcess: return "running"
        case .activeJsonl:   return "recent activity"
        case .recentJsonl:   return "recent"
        case .hidden:        return ""
        }
    }
}

/// Pure tier classifier. Same input as `SessionFreshnessFilter.filterCurrent`,
/// richer output. The `.hidden` case is the union of (a) process-path
/// artifact rows, (b) sessions whose `last_active_at` exceeds the
/// recent-JSONL window — i.e. exactly the rows `filterCurrent` would
/// drop, so behavior remains backward-compatible at the filter contract.
public enum SessionFreshnessTierClassifier {
    /// Process-confirmed rows stay Active for this long after their
    /// last seen. The helper heartbeats every 60 s and refreshes
    /// `last_active_at = now()` on each cycle, so 180 s tolerates a
    /// missed cycle without flipping a healthy session to Recent.
    public static let processFreshnessWindow: TimeInterval = 180

    /// JSONL-only rows newer than this are Active. Matches the
    /// existing `SessionFreshnessFilter.freshnessWindow` (300 s) so
    /// the cloud-route filter contract is preserved.
    public static let jsonlActiveWindow: TimeInterval = 300

    /// JSONL-only rows newer than this are Recent (and visible).
    /// Above this they're hidden.
    public static let jsonlRecentWindow: TimeInterval = 1800

    /// Returns the tier the session should occupy.
    public static func classify(_ session: SessionRecord, now: Date) -> FreshnessTier {
        // Helper-emitted process-path artifacts are never visible.
        if SessionFreshnessFilter.isProcessPathArtifact(session) {
            return .hidden
        }
        guard let lastActive = session.lastActiveDate else { return .hidden }
        let age = now.timeIntervalSince(lastActive)
        if age < 0 { return .hidden }    // future timestamp = bad clock data, drop

        // Process-confirmed sessions: the `proc-` id prefix comes from
        // helper/system_collector.py:188 `session_id=f"proc-{pid}"`.
        if session.id.hasPrefix("proc-") {
            return age <= processFreshnessWindow ? .activeProcess : .hidden
        }

        // JSONL-synthesized sessions (`jsonl-…` ids from
        // CostUsageScanner) and cloud rows from other devices both
        // fall through to the age-tier rules.
        if age <= jsonlActiveWindow { return .activeJsonl }
        if age <= jsonlRecentWindow { return .recentJsonl }
        return .hidden
    }

    /// Bin a session list into the two visible sections, dropping
    /// hidden rows. Both buckets are sorted most-recently-active
    /// first so the UI doesn't need a second sort.
    public static func partition(
        _ sessions: [SessionRecord],
        now: Date
    ) -> (active: [SessionRecord], recent: [SessionRecord]) {
        var active: [SessionRecord] = []
        var recent: [SessionRecord] = []
        for s in sessions {
            switch classify(s, now: now).section {
            case .active: active.append(s)
            case .recent: recent.append(s)
            case .hidden: break
            }
        }
        let isoFormatter = ISO8601DateFormatter()
        let order: (SessionRecord, SessionRecord) -> Bool = { lhs, rhs in
            let l = isoFormatter.date(from: lhs.last_active_at) ?? .distantPast
            let r = isoFormatter.date(from: rhs.last_active_at) ?? .distantPast
            return l > r
        }
        return (active.sorted(by: order), recent.sorted(by: order))
    }
}
