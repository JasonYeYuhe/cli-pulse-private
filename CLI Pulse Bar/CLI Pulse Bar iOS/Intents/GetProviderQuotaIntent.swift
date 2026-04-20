import AppIntents
import Foundation

@available(iOS 17.0, *)
enum IntentProvider: String, AppEnum {
    case claude
    case codex
    case gemini
    case cursor
    case ollama
    case windsurf
    case opencode

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static var caseDisplayRepresentations: [IntentProvider: DisplayRepresentation] = [
        .claude: "Claude",
        .codex: "Codex",
        .gemini: "Gemini",
        .cursor: "Cursor",
        .ollama: "Ollama",
        .windsurf: "Windsurf",
        .opencode: "opencode",
    ]

    var canonicalName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        case .cursor: return "Cursor"
        case .ollama: return "Ollama"
        case .windsurf: return "Windsurf"
        case .opencode: return "opencode"
        }
    }
}

@available(iOS 17.0, *)
struct GetProviderQuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "Get Provider Quota"
    static var description = IntentDescription(
        "Check how much quota is remaining for a specific provider (Claude, Codex, Gemini, and more).",
        categoryName: "Status"
    )

    static var openAppWhenRun: Bool = false

    @Parameter(title: "Provider")
    var provider: IntentProvider

    static var parameterSummary: some ParameterSummary {
        Summary("Get \(\.$provider) quota")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        guard let snapshot = CLIPulseIntentCache.load() else {
            let dialog = IntentDialog("No CLI Pulse data yet. Open the app once to sync from your Mac.")
            return .result(value: "No data", dialog: dialog)
        }

        let target = provider.canonicalName
        guard let cached = snapshot.providers.first(where: { $0.name.caseInsensitiveCompare(target) == .orderedSame }) else {
            let msg = "\(target) is not configured in CLI Pulse."
            return .result(value: msg, dialog: IntentDialog(stringLiteral: msg))
        }

        let spoken: String
        if let remaining = cached.remaining, let quota = cached.quota, quota > 0 {
            let percent = Int((1.0 - cached.usagePercent) * 100)
            spoken = "\(target): \(formatUsage(remaining)) left, \(percent)% remaining."
        } else {
            spoken = "\(target): \(formatUsage(cached.usage)) used today, no quota set."
        }

        return .result(value: spoken, dialog: IntentDialog(stringLiteral: spoken))
    }

    private func formatUsage(_ usage: Int) -> String {
        if usage >= 1_000_000 {
            return String(format: "%.1fM", Double(usage) / 1_000_000)
        } else if usage >= 1_000 {
            return String(format: "%.0fK", Double(usage) / 1_000)
        }
        return "\(usage)"
    }
}
