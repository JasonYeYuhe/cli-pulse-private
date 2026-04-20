import AppIntents
import Foundation

@available(iOS 17.0, *)
struct GetStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Get CLI Pulse Status"
    static var description = IntentDescription(
        "Get today's total usage, cost, active sessions, and unresolved alerts across all providers.",
        categoryName: "Status"
    )

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let snapshot = CLIPulseIntentCache.load() else {
            let dialog = IntentDialog("No CLI Pulse data yet. Open the app once to sync from your Mac.")
            return .result(value: "No data", dialog: dialog)
        }

        let usage = formatUsage(snapshot.totalUsageToday)
        let cost = formatCost(snapshot.totalCostToday)
        let sessions = snapshot.activeSessions
        let alerts = snapshot.unresolvedAlerts

        var spoken = "Today: \(usage) tokens, \(cost) spent"
        if sessions > 0 {
            spoken += ", \(sessions) active \(sessions == 1 ? "session" : "sessions")"
        }
        if alerts > 0 {
            spoken += ", \(alerts) open \(alerts == 1 ? "alert" : "alerts")"
        } else {
            spoken += ", no open alerts"
        }
        spoken += "."

        let dialog = IntentDialog(stringLiteral: spoken)
        return .result(value: spoken, dialog: dialog)
    }

    private func formatUsage(_ usage: Int) -> String {
        if usage >= 1_000_000 {
            return String(format: "%.1fM", Double(usage) / 1_000_000)
        } else if usage >= 1_000 {
            return String(format: "%.0fK", Double(usage) / 1_000)
        }
        return "\(usage)"
    }

    private func formatCost(_ cost: Double) -> String {
        if cost < 0.01 { return "less than one cent" }
        return String(format: "$%.2f", cost)
    }
}
