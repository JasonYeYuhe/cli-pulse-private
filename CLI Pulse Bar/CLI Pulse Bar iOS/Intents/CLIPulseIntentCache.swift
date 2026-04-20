import Foundation

/// Shared App Group cache reader for AppIntents.
///
/// Mirrors `WidgetStorage` / `WidgetData` from the Widgets target. Kept in the
/// iOS app target so AppIntent types do not need to link against the Widgets
/// extension (they can't — extensions cannot be imported as modules).
enum CLIPulseIntentCache {
    static let suiteName = "group.yyh.CLI-Pulse"
    static let dataKey = "widgetData"
    static let refreshRequestKey = "widgetRefreshRequestedAt"

    struct CachedProvider: Codable, Identifiable {
        let name: String
        let usage: Int
        let quota: Int?
        let costToday: Double
        let iconName: String

        var id: String { name }

        var remaining: Int? {
            guard let quota else { return nil }
            return max(0, quota - usage)
        }

        var usagePercent: Double {
            guard let quota, quota > 0 else { return 0 }
            return min(1.0, Double(usage) / Double(quota))
        }
    }

    struct Snapshot: Codable {
        let totalUsageToday: Int
        let totalCostToday: Double
        let activeSessions: Int
        let unresolvedAlerts: Int
        let providers: [CachedProvider]
        let lastUpdated: Date
    }

    static func load() -> Snapshot? {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: dataKey),
              let decoded = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Mark that an interactive widget refresh was requested. The iOS app, on
    /// next foreground, reads this timestamp and triggers `refreshAll()` if it
    /// is more recent than its own last refresh.
    static func requestRefresh() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: refreshRequestKey)
    }

    static func refreshRequestedAt() -> Date? {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return nil }
        let ts = defaults.double(forKey: refreshRequestKey)
        return ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }
}

enum CLIPulseProviderName: String, CaseIterable {
    case claude
    case codex
    case gemini
    case cursor
    case ollama
    case windsurf
    case openCode = "opencode"

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .ollama: return "Ollama"
        case .windsurf: return "Windsurf"
        case .openCode: return "opencode"
        }
    }

    func matches(_ cachedName: String) -> Bool {
        cachedName.caseInsensitiveCompare(displayName) == .orderedSame
    }
}
