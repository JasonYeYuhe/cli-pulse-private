import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 8: extracted from SettingsTab.swift (pre-extraction
/// `providerSettingsSection` + `providerSettingsRow`). Per-provider
/// source/credentials display with a "gear" button to open the
/// provider-config window.
struct ProviderSettingsSection: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var providerState: ProviderState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Provider Configuration", icon: "cpu")

            Text("Configure data source, credentials, and display for each provider.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            ForEach(providerState.providerConfigs) { config in
                providerRow(config: config)
            }
        }
    }

    private func providerRow(config: ProviderConfig) -> some View {
        HStack(spacing: 6) {
            Image(systemName: config.kind.iconName)
                .font(.system(size: 10))
                .foregroundStyle(PulseTheme.providerColor(config.kind.rawValue))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(config.kind.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("Source: \(config.sourceMode.rawValue)")
                        .font(.system(size: 8))
                        .foregroundStyle(.quaternary)
                    if config.hasCredentials {
                        Text("Key set")
                            .font(.system(size: 7, weight: .medium))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.green.opacity(0.1))
                            .clipShape(Capsule())
                    }
                    if let label = config.accountLabel, !label.isEmpty {
                        Text(label)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            Button {
                providerState.editingProviderKind = config.kind
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "provider-config")
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 10))
                    .foregroundStyle(PulseTheme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Configure \(config.kind.rawValue)")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(PulseTheme.cardBackground.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
