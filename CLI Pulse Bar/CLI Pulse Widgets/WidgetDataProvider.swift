import Foundation
import WidgetKit

// MARK: - Shared Data

struct WidgetData: Codable {
    let totalUsageToday: Int
    let totalCostToday: Double
    let activeSessions: Int
    let unresolvedAlerts: Int
    let providers: [WidgetProviderData]
    let lastUpdated: Date
    // v1.22 P0 S5 — at-a-glance swarm counts for the watch
    // complication / Android Glance parity. Optional so an OLD
    // persisted App-Group blob (no swarm keys) still decodes
    // (synthesized Codable uses decodeIfPresent for optionals);
    // read sites coalesce nil → 0.
    let swarmAgents: Int?
    let swarmBlocked: Int?
    /// v1.30 — iOS home-screen + lock-screen widgets are a Pro perk. The
    /// host app writes the resolved entitlement here; those widgets render a
    /// locked placeholder when this is `false`. Optional + fail-open: a
    /// legacy payload (nil) or a paid user shows content; only an explicit
    /// `false` locks. The watch complication ignores this (stays free).
    var isPro: Bool? = nil

    static let empty = WidgetData(
        totalUsageToday: 0,
        totalCostToday: 0,
        activeSessions: 0,
        unresolvedAlerts: 0,
        providers: [],
        lastUpdated: Date(),
        swarmAgents: 0,
        swarmBlocked: 0
    )

    static let preview = WidgetData(
        totalUsageToday: 245_000,
        totalCostToday: 3.45,
        activeSessions: 3,
        unresolvedAlerts: 1,
        providers: [
            WidgetProviderData(name: "Claude", usage: 120_000, quota: 500_000, costToday: 1.85, iconName: "brain.head.profile"),
            WidgetProviderData(name: "Codex", usage: 85_000, quota: 200_000, costToday: 1.20, iconName: "chevron.left.forwardslash.chevron.right"),
            WidgetProviderData(name: "Gemini", usage: 40_000, quota: 300_000, costToday: 0.40, iconName: "sparkles"),
        ],
        lastUpdated: Date(),
        swarmAgents: 5,
        swarmBlocked: 2
    )
}

struct WidgetProviderData: Codable, Identifiable {
    let name: String
    let usage: Int
    let quota: Int?
    let costToday: Double
    let iconName: String
    /// Correct, already-clamped usage fraction (0...1) computed by the host
    /// app from `ProviderUsage.usagePercent` = (quota − remaining) / quota.
    /// Optional so payloads written before this field still decode (→ nil →
    /// the clamped fallback below). The widget MUST prefer this over
    /// recomputing `usage / quota`: for window-capped providers (e.g. Claude)
    /// `quota` is a percentage cap (~100), NOT a token count, so `usage /
    /// quota` mixes units and explodes — that was the "88,475,787%" bug.
    var percent: Double? = nil

    var id: String { name }

    var usagePercent: Double {
        if let percent { return min(1, max(0, percent)) }
        // Legacy / missing percent: clamp the local estimate so a
        // token-count-over-percent-cap mismatch can never render as e.g.
        // 88,475,787% again.
        guard let quota = quota, quota > 0 else { return 0 }
        return min(1, max(0, Double(usage) / Double(quota)))
    }

    var formattedUsage: String {
        if usage >= 1_000_000 {
            return String(format: "%.1fM", Double(usage) / 1_000_000)
        } else if usage >= 1_000 {
            return String(format: "%.0fK", Double(usage) / 1_000)
        }
        return "\(usage)"
    }

    var formattedCost: String {
        if costToday < 0.01 { return "$0.00" }
        return String(format: "$%.2f", costToday)
    }
}

// MARK: - App Group Storage

enum WidgetStorage {
    static let suiteName = "group.yyh.CLI-Pulse"
    static let dataKey = "widgetData"

    static func save(_ data: WidgetData) {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        if let encoded = try? JSONEncoder().encode(data) {
            defaults.set(encoded, forKey: dataKey)
        }
    }

    static func load() -> WidgetData {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: dataKey),
              let decoded = try? JSONDecoder().decode(WidgetData.self, from: data) else {
            return .empty
        }
        return decoded
    }
}

// MARK: - Timeline Provider

struct CLIPulseTimelineProvider: TimelineProvider {
    typealias Entry = CLIPulseEntry

    func placeholder(in context: Context) -> CLIPulseEntry {
        CLIPulseEntry(date: Date(), data: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (CLIPulseEntry) -> Void) {
        if context.isPreview {
            completion(CLIPulseEntry(date: Date(), data: .preview))
        } else {
            completion(CLIPulseEntry(date: Date(), data: WidgetStorage.load()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CLIPulseEntry>) -> Void) {
        let data = WidgetStorage.load()
        let now = Date()
        // v1.21 D6: emit 3 timeline entries spanning the next 15 min instead
        // of one. WidgetKit will pick the most relevant one to render based
        // on the relevance score, and the staleness label rendered inside
        // the widget keeps reading sensibly as the entry timestamps advance.
        let entries: [CLIPulseEntry] = (0..<3).map { offset in
            let entryDate = Calendar.current.date(byAdding: .minute, value: offset * 5, to: now) ?? now.addingTimeInterval(TimeInterval(offset * 300))
            return CLIPulseEntry(date: entryDate, data: data)
        }
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: now) ?? now.addingTimeInterval(900)
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct CLIPulseEntry: TimelineEntry {
    let date: Date
    let data: WidgetData

    // v1.21 D6: relevance scoring for iOS 17+ Smart Stack. The widget rises
    // in the stack when (a) there are unresolved alerts, or (b) the highest-
    // usage provider is approaching its quota cap. Score scales linearly with
    // both signals; WidgetKit normalises across all widgets so absolute
    // magnitude matters less than direction.
    var relevance: TimelineEntryRelevance? {
        let alertWeight = Float(data.unresolvedAlerts) * 5.0
        let topUsageRatio: Float = {
            // Only consider providers with a positive quota (self-hosted /
            // Ollama-style providers carry `quota = nil` and shouldn't
            // contribute to the score).
            let ratios: [Float] = data.providers.compactMap { p in
                guard let q = p.quota, q > 0 else { return nil }
                return Float(p.usage) / Float(q)
            }
            return ratios.max() ?? 0
        }()
        let usageWeight = max(0, (topUsageRatio - 0.7)) * 30.0  // ramps once >70% of quota
        return TimelineEntryRelevance(score: alertWeight + usageWeight)
    }
}

// MARK: - Single Provider Timeline Provider

struct SingleProviderTimelineProvider: TimelineProvider {
    typealias Entry = SingleProviderEntry

    private static let fallbackProvider = WidgetProviderData(
        name: "Claude", usage: 0, quota: 100, costToday: 0, iconName: "brain.head.profile"
    )

    private static var previewProvider: WidgetProviderData {
        WidgetData.preview.providers.first ?? fallbackProvider
    }

    func placeholder(in context: Context) -> SingleProviderEntry {
        SingleProviderEntry(date: Date(), provider: Self.previewProvider)
    }

    func getSnapshot(in context: Context, completion: @escaping (SingleProviderEntry) -> Void) {
        if context.isPreview {
            completion(SingleProviderEntry(date: Date(), provider: Self.previewProvider))
        } else {
            let data = WidgetStorage.load()
            let provider = data.providers.first ?? Self.previewProvider
            completion(SingleProviderEntry(date: Date(), provider: provider, isPro: data.isPro))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SingleProviderEntry>) -> Void) {
        let data = WidgetStorage.load()
        let provider = data.providers.first ?? Self.previewProvider
        let entry = SingleProviderEntry(date: Date(), provider: provider, isPro: data.isPro)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

struct SingleProviderEntry: TimelineEntry {
    let date: Date
    let provider: WidgetProviderData
    /// See WidgetData.isPro. Fail-open: nil/true → content, false → locked.
    var isPro: Bool? = nil
}
