import AppIntents

@available(iOS 17.0, *)
struct CLIPulseShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetStatusIntent(),
            phrases: [
                "Get \(.applicationName) status",
                "Check my \(.applicationName)",
                "How is my \(.applicationName) doing",
                "\(.applicationName) summary"
            ],
            shortTitle: "Get Status",
            systemImageName: "gauge.with.dots.needle.33percent"
        )

        AppShortcut(
            intent: GetProviderQuotaIntent(),
            phrases: [
                "Check \(.applicationName) quota",
                "\(.applicationName) quota remaining",
                "How much \(.applicationName) quota do I have"
            ],
            shortTitle: "Provider Quota",
            systemImageName: "cpu"
        )
    }
}
